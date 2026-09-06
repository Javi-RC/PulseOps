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
end
