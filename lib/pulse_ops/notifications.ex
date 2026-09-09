defmodule PulseOps.Notifications do
  @moduledoc """
  Where organizations configure how they are told about incidents.

  A `Notifier` is a delivery channel — a webhook URL or, for email, the set of
  organization users it reaches. A notifier is optionally narrowed to one
  service; when narrowed, it only fires for that service's incidents. When an
  incident opens or resolves, `PulseOps.Incidents` calls
  `enqueue_incident_notifications/3`, which queues one Oban job per matching
  enabled notifier. Delivery happens off the monitor's path, so an unreachable
  receiver never slows down the probes that spotted the incident.

  Notifiers are administrative configuration, so every write goes through
  `Organizations.authorize(scope, :manage_organization)` like alert rules.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset

  alias PulseOps.Accounts.Scope
  alias PulseOps.Incidents.Incident
  alias PulseOps.Notifications.Notifier
  alias PulseOps.Notifications.NotifierAssignment
  alias PulseOps.Notifications.NotifyJob
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

  Called from `PulseOps.Incidents` after the incident transaction commits, with
  the event as `:opened` or `:resolved`. A receiver being slow never blocks the
  caller: the job is just a row in `oban_jobs`, and Oban retries it.
  """
  def enqueue_incident_notifications(organization_id, incident, event)
      when event in [:opened, :resolved] do
    jobs =
      organization_id
      |> matching_enabled_notifiers(incident)
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

  defp matching_enabled_notifiers(organization_id, %Incident{service_id: service_id}) do
    from(n in Notifier,
      where: n.organization_id == ^organization_id and n.enabled == true,
      where: is_nil(n.service_id) or n.service_id == ^service_id
    )
    |> preload(^@preloads)
    |> Repo.all()
  end

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
end
