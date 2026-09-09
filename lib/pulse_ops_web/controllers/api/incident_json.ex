defmodule PulseOpsWeb.Api.IncidentJSON do
  @moduledoc """
  How an incident looks over the API.

  Unlike the public status page, this one is read by a program holding a token
  for the organization, so the cause and the resolver are included: the caller
  is already inside the tenant.
  """

  alias PulseOps.Incidents.Incident

  def index(%{incidents: incidents}), do: %{data: for(incident <- incidents, do: data(incident))}
  def show(%{incident: incident}), do: %{data: data(incident)}

  def data(%Incident{} = incident) do
    %{
      id: incident.id,
      service_id: incident.service_id,
      title: incident.title,
      severity: incident.severity,
      status: incident.status,
      cause: incident.cause,
      started_at: incident.started_at,
      resolved_at: incident.resolved_at,
      resolved_by_id: incident.resolved_by_id,
      duration_seconds: Incident.duration_seconds(incident),
      open: Incident.open?(incident)
    }
  end
end
