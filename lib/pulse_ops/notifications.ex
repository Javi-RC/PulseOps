defmodule PulseOps.Notifications do
  @moduledoc """
  Where organizations configure how they are told about incidents.

  A `Notifier` is a delivery channel — a webhook URL or, for email, the set of
  organization users it reaches. A notifier is optionally narrowed to one
  service; when narrowed, it only fires for that service's incidents. When an
  incident opens or resolves, `PulseOps.Incidents` queues an
  `Incidents.EventJob` in the same transaction; when that job runs it calls
  `enqueue_incident_notifications/3`, which queues one Oban job per matching
  enabled notifier. None of it happens on the monitor's path, so neither a slow
  receiver nor the fan-out itself slows the probes that spotted the incident
  (ADR-020).

  Notifiers are administrative configuration, so every write goes through
  `Organizations.authorize(scope, :manage_organization)` like alert rules.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset

  alias PulseOps.Accounts.Scope
  alias PulseOps.Incidents
  alias PulseOps.Incidents.Incident
  alias PulseOps.Monitoring.Service
  alias PulseOps.Notifications.DigestJob
  alias PulseOps.Notifications.EscalationJob
  alias PulseOps.Notifications.Notifier
  alias PulseOps.Notifications.NotifierAssignment
  alias PulseOps.Notifications.NotifyJob
  alias PulseOps.Notifications.TlsWarningJob
  alias PulseOps.Organizations
  alias PulseOps.Repo

  @preloads [:assigned_users, :service]

  @doc """
  All notifiers in the scoped organization, newest last.
  """
  def list_notifiers(%Scope{} = scope) do
    from(n in Notifier, where: n.organization_id == ^scope.organization.id)
    |> order_by([n], asc: n.id)
    |> preload(^@preloads)
    |> Repo.all()
  end

  @doc """
  Fetches a notifier belonging to the scoped organization, or nil.
  """
  def get_notifier(%Scope{} = scope, id) do
    Notifier
    |> Repo.get_by(id: id, organization_id: scope.organization.id)
    |> Repo.preload(@preloads)
  end

  @doc """
  Creates a notifier for the scoped organization, with its assigned users.
  """
  def create_notifier(%Scope{} = scope, attrs \\ %{}) do
    with :ok <- Organizations.authorize(scope, :manage_organization),
         {:ok, notifier = %Notifier{}} <-
           %Notifier{}
           |> Notifier.changeset(attrs, scope)
           |> put_assignees(attrs)
           |> Repo.insert() do
      {:ok, Repo.preload(notifier, @preloads)}
    end
  end

  @doc """
  Updates a notifier belonging to the scoped organization, with its assigned
  users.
  """
  def update_notifier(%Scope{} = scope, %Notifier{} = notifier, attrs) do
    true = notifier.organization_id == scope.organization.id

    with :ok <- Organizations.authorize(scope, :manage_organization),
         {:ok, notifier = %Notifier{}} <-
           notifier
           |> Notifier.changeset(attrs, scope)
           |> put_assignees(attrs)
           |> Repo.update() do
      {:ok, Repo.preload(notifier, @preloads)}
    end
  end

  @doc """
  Deletes a notifier belonging to the scoped organization.
  """
  def delete_notifier(%Scope{} = scope, %Notifier{} = notifier) do
    true = notifier.organization_id == scope.organization.id

    with :ok <- Organizations.authorize(scope, :manage_organization),
         {:ok, notifier = %Notifier{}} <- Repo.delete(notifier) do
      {:ok, notifier}
    end
  end

  @doc """
  Changeset for notifier forms.
  """
  def change_notifier(%Scope{} = scope, %Notifier{} = notifier, attrs \\ %{}) do
    true = notifier.organization_id == scope.organization.id

    notifier = Repo.preload(notifier, @preloads)

    selected =
      case assignee_ids(attrs) do
        nil -> Enum.map(notifier.assigned_users, & &1.id)
        ids -> ids
      end

    notifier
    |> Notifier.changeset(attrs, scope)
    |> put_change(:assignee_ids, selected)
  end

  ## Delivery

  @doc """
  Queues one delivery job per matching enabled notifier for an incident that
  just opened or resolved.

  A notifier matches when it is enabled, belongs to the incident's organization,
  and either is not narrowed to a service or is narrowed to the incident's
  service.

  Called by `PulseOps.Incidents.EventJob`, with the event as `:opened` or
  `:resolved` — never on the path that opened or resolved the incident. Each
  delivery is its own row in `oban_jobs`, so a slow receiver only delays itself.
  """
  def enqueue_incident_notifications(organization_id, incident, event)
      when event in [:opened, :resolved] do
    service = Repo.get(Service, incident.service_id)

    # A service crossing its threshold over and over would otherwise send a
    # message per crossing. One digest says the same thing without the storm.
    if service && Incidents.flapping?(service) do
      enqueue_digest(organization_id, service)
    else
      result = enqueue_direct(organization_id, incident, event)
      maybe_schedule_escalation(incident, event)
      result
    end
  end

  defp enqueue_direct(organization_id, incident, event, audience \\ :normal) do
    jobs =
      organization_id
      |> matching_enabled_notifiers(incident, audience)
      |> Enum.map(fn notifier ->
        NotifyJob.new(%{
          "notifier_id" => notifier.id,
          "incident_id" => incident.id,
          "event" => event_string(event)
        })
      end)

    if jobs == [] do
      :ok
    else
      jobs
      |> Oban.insert_all()
      |> Enum.any?(& &1.discarded_at)
      |> case do
        false -> :ok
        true -> :error
      end
    end
  end

  @doc """
  Sends the notifications an escalation calls for: everybody, including the
  channels that stay quiet for ordinary incidents.
  """
  @spec enqueue_escalation(integer(), Incident.t()) :: :ok | :error
  def enqueue_escalation(organization_id, %Incident{} = incident) do
    enqueue_direct(organization_id, incident, :escalated, :escalation)
  end

  # One digest job per service, whatever arrives while it waits. Oban's
  # uniqueness is what makes that true: the second, third and tenth transition
  # inside the window all try to insert the same job and are collapsed into the
  # one already scheduled, so the storm becomes a message.
  defp enqueue_digest(organization_id, %Service{} = service) do
    %{"organization_id" => organization_id, "service_id" => service.id}
    |> DigestJob.new(
      schedule_in: digest_delay_seconds(),
      unique: [period: :infinity, states: [:available, :scheduled], keys: [:service_id]]
    )
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, _reason} -> :error
    end
  end

  # Only when an incident opens, only when it is critical, and only if
  # escalation is switched on. Unique per incident, so reopening the same
  # question twice does not produce two escalations.
  defp maybe_schedule_escalation(%Incident{severity: :critical, id: id}, :opened) do
    case escalation_after_seconds() do
      nil ->
        :ok

      seconds ->
        %{"incident_id" => id}
        |> EscalationJob.new(
          schedule_in: seconds,
          unique: [period: :infinity, states: [:available, :scheduled], keys: [:incident_id]]
        )
        |> Oban.insert()

        :ok
    end
  end

  defp maybe_schedule_escalation(_incident, _event), do: :ok

  ## Tuning

  @doc """
  How many incidents inside the flap window make a service a flapper.
  """
  @spec flap_threshold() :: pos_integer()
  def flap_threshold, do: setting(:flap_threshold, 3)

  @doc """
  How far back flap detection looks, in seconds.
  """
  @spec flap_window_seconds() :: pos_integer()
  def flap_window_seconds, do: setting(:flap_window_seconds, 600)

  @doc """
  How long a digest waits before it is sent, in seconds. The delay is what makes
  a digest a digest: everything that happens inside it is collapsed into the one
  message.
  """
  @spec digest_delay_seconds() :: non_neg_integer()
  def digest_delay_seconds, do: setting(:digest_delay_seconds, 300)

  @doc """
  How long a critical incident may sit unacknowledged before the
  escalation-only channels are told. Nil switches escalation off.
  """
  @spec escalation_after_seconds() :: pos_integer() | nil
  def escalation_after_seconds, do: setting(:escalation_after_seconds, 900)

  defp setting(key, default) do
    :pulse_ops
    |> Application.get_env(:notifications, [])
    |> Keyword.get(key, default)
  end

  @doc """
  Tells the ordinary channels that a certificate is running out.

  Not an incident: the service is up, and opening one would conflate "broken"
  with "will break". It is a warning with a date on it, which is a different
  thing to receive.
  """
  @spec enqueue_tls_warning(Service.t(), integer()) :: :ok | :error
  def enqueue_tls_warning(%Service{} = service, days_left) do
    jobs =
      service.organization_id
      |> notifiers_for_digest(service)
      |> Enum.map(fn notifier ->
        TlsWarningJob.new(%{
          "notifier_id" => notifier.id,
          "service_id" => service.id,
          "days_left" => days_left
        })
      end)

    if jobs == [] do
      :ok
    else
      jobs
      |> Oban.insert_all()
      |> Enum.any?(& &1.discarded_at)
      |> case do
        false -> :ok
        true -> :error
      end
    end
  end

  @doc """
  The channels a flapping service's digest goes to. Used by `DigestJob`.
  """
  @spec notifiers_for_digest(integer(), Service.t()) :: [Notifier.t()]
  def notifiers_for_digest(organization_id, %Service{id: service_id}) do
    from(n in Notifier,
      where: n.organization_id == ^organization_id and n.enabled == true,
      where: n.escalation_only == false,
      where: is_nil(n.service_id) or n.service_id == ^service_id
    )
    |> preload(^@preloads)
    |> Repo.all()
  end

  @doc """
  Loads a notifier for delivery, without a scope. Used by `NotifyJob`.
  """
  def notifier_for_delivery(notifier_id) do
    Repo.get(Notifier, notifier_id)
    |> Repo.preload([:assigned_users, :organization])
  end

  @doc """
  Loads an incident for delivery, with its service and organization, without a
  scope. Used by `NotifyJob`.
  """
  def incident_for_delivery(incident_id) do
    incident = Repo.get(Incident, incident_id)
    if incident, do: Repo.preload(incident, [:service, :organization]), else: nil
  end

  @doc """
  Loads the organization members that may be assigned to a notifier, as
  `{name, id}` options for a select. Regular members and up are included.
  """
  def assignee_options(%Scope{} = scope) do
    Organizations.list_members(scope)
    |> Enum.map(fn membership -> {membership.user.email, membership.user.id} end)
    |> Enum.uniq_by(&elem(&1, 1))
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp matching_enabled_notifiers(
         organization_id,
         %Incident{service_id: service_id},
         audience
       ) do
    from(n in Notifier,
      where: n.organization_id == ^organization_id and n.enabled == true,
      where: is_nil(n.service_id) or n.service_id == ^service_id
    )
    |> filter_audience(audience)
    |> preload(^@preloads)
    |> Repo.all()
  end

  # A normal notification skips the escalation-only channels — the whole point
  # of a second line is that it is not paged for everything. An escalation goes
  # to everybody, including the people already told: nobody picked this up, so
  # more noise is the intent.
  defp filter_audience(query, :normal), do: where(query, [n], n.escalation_only == false)
  defp filter_audience(query, :escalation), do: query

  # Replaces the notifier's users with the ones named in `assignee_ids`. The
  # cast for `service_id` lets an empty string stay nil so the field reads as
  # "not narrowed".
  defp put_assignees(changeset, attrs) do
    changeset
    |> put_assoc(
      :assignments,
      Enum.map(assignee_ids(attrs) || [], fn user_id ->
        %NotifierAssignment{user_id: user_id}
      end)
    )
  end

  defp assignee_ids(%{"assignee_ids" => ids}) when is_list(ids),
    do: Enum.map(ids, &String.to_integer(&1))

  defp assignee_ids(%{assignee_ids: ids}) when is_list(ids), do: ids
  defp assignee_ids(_), do: nil

  defp event_string(:opened), do: "opened"
  defp event_string(:resolved), do: "resolved"
  defp event_string(:escalated), do: "escalated"
end
