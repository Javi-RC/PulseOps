defmodule PulseOps.MonitoringFixtures do
  @moduledoc """
  Test fixtures for the `PulseOps.Monitoring` context.
  """

  alias PulseOps.Monitoring

  @doc """
  Valid attributes for a service. Names are unique so that the
  `(organization_id, name)` index does not collide across fixtures.
  """
  def valid_service_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "Service #{System.unique_integer([:positive])}",
      description: "some description",
      environment: :production,
      url: "https://api.example.com/health",
      check_interval_ms: 30_000,
      timeout_ms: 5_000,
      enabled: true
    })
  end

  @doc """
  Generate a service.
  """
  def service_fixture(scope, attrs \\ %{}) do
    {:ok, service} = Monitoring.create_service(scope, valid_service_attributes(attrs))
    service
  end

  @doc """
  Valid attributes for an alert rule (the organization-wide default).
  """
  def valid_alert_rule_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      failure_threshold: 3,
      success_threshold: 2,
      degraded_ratio: 0.5,
      severity: :medium
    })
  end

  @doc """
  Generate an alert rule (organization default unless given a service_id).
  """
  def alert_rule_fixture(scope, attrs \\ %{}) do
    {:ok, rule} = Monitoring.create_alert_rule(scope, valid_alert_rule_attributes(attrs))
    rule
  end
end
