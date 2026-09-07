defmodule PulseOps.IncidentsFixtures do
  @moduledoc """
  Test fixtures for `PulseOps.Incidents`.
  """

  alias PulseOps.Incidents
  alias PulseOps.Monitoring.AlertRule

  @doc """
  Opens an incident for a service, the way a monitor would, using the hardcoded
  default rule.
  """
  def incident_fixture(service, reason \\ "connection refused") do
    {:ok, incident} = Incidents.open_incident(service, AlertRule.default(), reason)
    incident
  end

  @doc """
  Opens an incident and immediately resolves it automatically.
  """
  def resolved_incident_fixture(service) do
    incident_fixture(service)
    {:ok, incident} = Incidents.resolve_open_incident(service)
    incident
  end
end
