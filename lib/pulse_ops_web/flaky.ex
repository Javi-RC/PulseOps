defmodule PulseOpsWeb.Flaky do
  @moduledoc """
  Holds the behaviour of the `/dev/flaky` endpoint.

  Lets a service be broken and healed on demand, which is how an incident gets
  demonstrated end to end without waiting for something real to fail. Only
  started when dev routes are enabled.
  """

  use Agent

  @default %{status: 200, latency_ms: 50}

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> @default end, name: __MODULE__)
  end

  def state, do: Agent.get(__MODULE__, & &1)

  @doc """
  Makes the endpoint fail. After enough consecutive failures the monitor opens
  an incident.
  """
  def break(status \\ 503), do: Agent.update(__MODULE__, &%{&1 | status: status})

  @doc """
  Returns the endpoint to normal; the monitor resolves the incident on its own.
  """
  def heal, do: Agent.update(__MODULE__, &%{&1 | status: 200})

  @doc """
  Makes responses slow enough to be reported as degraded.
  """
  def set_latency(ms) when is_integer(ms) and ms >= 0 do
    Agent.update(__MODULE__, &%{&1 | latency_ms: ms})
  end

  def healthy?, do: state().status in 200..299
end
