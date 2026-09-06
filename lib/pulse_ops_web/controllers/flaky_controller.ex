defmodule PulseOpsWeb.FlakyController do
  @moduledoc """
  A monitoring target that can be broken on purpose. Development only.
  """

  use PulseOpsWeb, :controller

  alias PulseOpsWeb.Flaky

  def show(conn, _params) do
    %{status: status, latency_ms: latency_ms} = Flaky.state()

    if latency_ms > 0, do: Process.sleep(latency_ms)

    conn
    |> put_status(status)
    |> json(%{status: status, latency_ms: latency_ms})
  end

  def break(conn, _params) do
    Flaky.break()
    json(conn, Flaky.state())
  end

  def heal(conn, _params) do
    Flaky.heal()
    json(conn, Flaky.state())
  end
end
