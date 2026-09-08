defmodule PulseOps.Notifications do
  @moduledoc """
  Where organizations configure how they are told about incidents.

  A `Notifier` is a delivery channel — a webhook URL or an email address. When an
  incident opens or resolves, `PulseOps.Incidents` calls
  `enqueue_incident_notifications/3`, which queues one Oban job per enabled
  notifier. Delivery happens off the monitor's path, so an unreachable receiver
  never slows down the probes that spotted the incident.

  Notifiers are administrative configuration, so every write goes through
  `Organizations.authorize(scope, :manage_organization)` like alert rules.
  """

  import Ecto.Query, warn: false

  alias PulseOps.Accounts.Scope
  alias PulseOps.Incidents.Incident
  alias PulseOps.Notifications.Notifier
  alias PulseOps.Notifications.NotifyJob
  alias PulseOps.Organizations
  alias PulseOps.Repo

  @doc """
  All notifiers in the scoped organization, newest last.
  """
  def list_notifiers(%Scope{} = scope) do
    from(n in Notifier, where: n.organization_id == ^scope.organization.id)
    |> order_by([n], asc: n.id)
    |> Repo.all()
  end

  @doc """
  Fetches a notifier belonging to the scoped organization, or nil.
  """
  def get_notifier(%Scope{} = scope, id) do
    Repo.get_by(Notifier, id: id, organization_id: scope.organization.id)
  end

  @doc """
  Creates a notifier for the scoped organization.
  """
  def create_notifier(%Scope{} = scope, attrs \\ %{}) do
    with :ok <- Organizations.authorize(scope, :manage_organization),
         {:ok, notifier = %Notifier{}} <-
           %Notifier{}
           |> Notifier.changeset(attrs, scope)
           |> Repo.insert() do
      {:ok, notifier}
    end
  end

  @doc """
  Updates a notifier belonging to the scoped organization.
  """
  def update_notifier(%Scope{} = scope, %Notifier{} = notifier, attrs) do
    true = notifier.organization_id == scope.organization.id

    with :ok <- Organizations.authorize(scope, :manage_organization),
         {:ok, notifier = %Notifier{}} <-
           notifier
           |> Notifier.changeset(attrs, scope)
           |> Repo.update() do
      {:ok, notifier}
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

    Notifier.changeset(notifier, attrs, scope)
  end

  ## Delivery

  @doc """
  Queues one delivery job per enabled notifier in the organization for an
  incident that just opened or resolved.

  Called from `PulseOps.Incidents` after the incident transaction commits, with
  the event as `:opened` or `:resolved`. A receiver being slow never blocks the
  caller: the job is just a row in `oban_jobs`, and Oban retries it.
  """
  def enqueue_incident_notifications(organization_id, incident, event)
      when event in [:opened, :resolved] do
    jobs =
      organization_id
      |> enabled_notifiers()
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
  end

  @doc """
  Loads an incident for delivery, with its service and organization, without a
  scope. Used by `NotifyJob`.
  """
  def incident_for_delivery(incident_id) do
    incident = Repo.get(Incident, incident_id)
    if incident, do: Repo.preload(incident, [:service, :organization]), else: nil
  end

  defp enabled_notifiers(organization_id) do
    from(n in Notifier, where: n.organization_id == ^organization_id and n.enabled == true)
    |> Repo.all()
  end

  defp event_string(:opened), do: "opened"
  defp event_string(:resolved), do: "resolved"
end
