defmodule PulseOps.Monitoring.HealthCheck do
  @moduledoc """
  The seam between the monitors and the network.

  Monitors never talk to an HTTP library directly: they call the module returned
  by `client/0`, which tests replace with a mock. That is what makes it possible
  to drive a service from healthy to down and back without a network.
  """

  alias PulseOps.Monitoring.HealthCheck.Result

  @doc """
  Probes `url` and reports what happened.

  Implementations must not raise: a failed probe is an ordinary outcome, and is
  reported as `{:error, reason}`.
  """
  @callback check(url :: String.t(), opts :: keyword()) ::
              {:ok, Result.t()} | {:error, Result.t()}

  @doc """
  The configured implementation.

  Resolved at call time rather than compile time so the test suite can swap it
  per-process with Mox.
  """
  def client do
    Application.get_env(:pulse_ops, :health_check_client, __MODULE__.Req)
  end
end
