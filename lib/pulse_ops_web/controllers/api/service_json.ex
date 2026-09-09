defmodule PulseOpsWeb.Api.ServiceJSON do
  @moduledoc """
  How a service looks over the API.

  Fields are named explicitly rather than dumping the schema, so adding a column
  is never accidentally a change to a public contract — and so a column that
  should not be public, when one arrives, is not published by default.
  """

  alias PulseOps.Monitoring.Service

  def index(%{services: services}), do: %{data: for(service <- services, do: data(service))}
  def show(%{service: service}), do: %{data: data(service)}

  def data(%Service{} = service) do
    %{
      id: service.id,
      name: service.name,
      description: service.description,
      environment: service.environment,
      url: service.url,
      enabled: service.enabled,
      public: service.public,
      status: service.status,
      last_checked_at: service.last_checked_at,
      check_interval_ms: service.check_interval_ms,
      timeout_ms: service.timeout_ms,
      http_method: service.http_method,
      expected_status: service.expected_status,
      body_assertion: service.body_assertion,
      inserted_at: service.inserted_at,
      updated_at: service.updated_at
    }
  end
end
