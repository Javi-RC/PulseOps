defmodule PulseOpsWeb.MetricsController do
  @moduledoc """
  Prometheus scrape endpoint.

  Not public. Metrics describe how this installation is behaving — request
  rates, job failures, probe volumes — which is operational detail about the
  people using it, so the endpoint is behind a bearer token and simply does not
  exist unless one is configured.
  """

  use PulseOpsWeb, :controller

  alias PulseOpsWeb.Telemetry

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, Telemetry.scrape())
  end
end
