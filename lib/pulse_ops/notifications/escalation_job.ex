defmodule PulseOps.Notifications.EscalationJob do
  @moduledoc """
  Tells the escalation-only channels about a critical incident nobody picked up.

  Scheduled when a critical incident opens, to run after
  `escalation_after_seconds`. When it runs it re-reads the incident and does
  nothing unless it is *still* open and *still* unacknowledged — the whole point
  is that acknowledging or resolving in the meantime cancels it, and doing that
  by simply checking at the end is more robust than trying to find and delete a
  scheduled job.
  """

  use Oban.Worker, queue: :default, max_attempts: 5

  require Logger

  alias PulseOps.Incidents
  alias PulseOps.Incidents.Incident
  alias PulseOps.Notifications
  alias PulseOps.Repo

  @impl true
  def perform(%Oban.Job{args: %{"incident_id" => incident_id}}) do
    case Repo.get(Incident, incident_id) do
      nil ->
        :ok

      %Incident{} = incident ->
        if Incidents.unacknowledged?(incident) do
          escalate(incident)
        else
          # Somebody has it, or it is already over. Either way there is nothing
          # to escalate, and saying so in the log would be noise.
          :ok
        end
    end
  end

  defp escalate(%Incident{} = incident) do
    Logger.info("incident escalated",
      incident_id: incident.id,
      service_id: incident.service_id,
      organization_id: incident.organization_id
    )

    Incidents.record_escalation(incident)
    Notifications.enqueue_escalation(incident.organization_id, incident)
  end
end
