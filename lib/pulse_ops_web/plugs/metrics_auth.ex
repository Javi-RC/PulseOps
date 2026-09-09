defmodule PulseOpsWeb.Plugs.MetricsAuth do
  @moduledoc """
  Guards the Prometheus scrape endpoint with a bearer token.

  With no `:metrics_token` configured the endpoint responds 404 rather than 401,
  so an installation that never set one does not advertise that it has metrics
  to be had. The comparison is constant-time: a token checked with `==` leaks
  its prefix to anyone willing to measure.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case Application.get_env(:pulse_ops, :metrics_token) do
      token when is_binary(token) and token != "" -> authorize(conn, token)
      _missing -> refuse(conn, 404, "not found\n")
    end
  end

  defp authorize(conn, token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> presented] ->
        if Plug.Crypto.secure_compare(presented, token),
          do: conn,
          else: refuse(conn, 401, "unauthorized\n")

      _otherwise ->
        refuse(conn, 401, "unauthorized\n")
    end
  end

  defp refuse(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
    |> halt()
  end
end
