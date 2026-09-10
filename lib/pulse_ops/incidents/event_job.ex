defmodule PulseOps.Incidents.EventJob do
  @moduledoc """
  Announces that an incident opened or resolved (ADR-020).

  Inserted inside the transaction that opens or resolves the incident, so the
  announcement commits with the incident or not at all. Everything the
  announcement leads to — which notifiers match, whether the service is flapping
  and gets a digest instead, whether an escalation is scheduled — is decided when
  this job runs, off the path that caused it. That path is usually a
  `ServiceMonitor`, which should be probing, not fanning out notifications.

  Quiet when the incident is gone by the time it runs.
  """

  use Oban.Worker, queue: :default, max_attempts: 5

  alias PulseOps.Incidents.Incident
  alias PulseOps.Notifications
  alias PulseOps.Repo

  @events %{"opened" => :opened, "resolved" => :resolved}

  @doc """
  The job announcing `event` for `incident`, for inserting in the same
  transaction as the change it announces.
  """
  @spec new_for(Incident.t(), :opened | :resolved) :: Ecto.Changeset.t()
  def new_for(%Incident{id: id}, event) when event in [:opened, :resolved] do
    new(%{"incident_id" => id, "event" => Atom.to_string(event)})
  end

  @impl true
  def perform(%Oban.Job{args: %{"incident_id" => incident_id, "event" => event}}) do
    with {:ok, event} <- Map.fetch(@events, event),
         %Incident{} = incident <- Repo.get(Incident, incident_id) do
      case Notifications.enqueue_incident_notifications(incident.organization_id, incident, event) do
        :ok -> :ok
        :error -> {:error, :deliveries_not_queued}
      end
    else
      # Gone before the job ran, or an event this version does not announce.
      _nothing_to_announce -> :ok
    end
  end
end
