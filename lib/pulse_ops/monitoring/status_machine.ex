defmodule PulseOps.Monitoring.StatusMachine do
  @moduledoc """
  Decides what a service's status is, given what its probes have reported.

  Pure: no processes, no database, no clock. `ServiceMonitor` owns the I/O and
  the scheduling and asks this module what the status should be. That split is
  what makes the rules testable exhaustively — the interesting behaviour here is
  *hysteresis*, and hysteresis bugs only show up over sequences, which is
  expensive to explore through a GenServer and cheap to explore through a
  function.

  ## The rules

  A single failing probe does not take a service down: `failure_threshold`
  consecutive failures do. A single success does not bring it back: recovery
  needs `success_threshold` consecutive successes. That asymmetry is the point —
  it is what stops a blip becoming an incident and a flap becoming a stream of
  them.

  A `:degraded` reading is reported immediately, because it is not a failure
  waiting to be confirmed; it is a successful response that took too long.

  Both thresholds come from the service's alert rule, so they can change under a
  running monitor — see `reapply/3`.
  """

  alias PulseOps.Monitoring.AlertRule

  @statuses [:unknown, :healthy, :degraded, :down]
  @check_statuses [:healthy, :degraded, :down]

  defstruct status: :unknown, consecutive_failures: 0, consecutive_successes: 0

  @type status :: :unknown | :healthy | :degraded | :down
  @type check_status :: :healthy | :degraded | :down

  @type t :: %__MODULE__{
          status: status(),
          consecutive_failures: non_neg_integer(),
          consecutive_successes: non_neg_integer()
        }

  @doc "Every status a service can hold."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Every verdict a single probe can produce."
  @spec check_statuses() :: [check_status()]
  def check_statuses, do: @check_statuses

  @doc """
  A machine starting from a known status, with nothing counted yet.
  """
  @spec new(status()) :: t()
  def new(status \\ :unknown) when status in @statuses, do: %__MODULE__{status: status}

  @doc """
  What one probe says on its own, before any hysteresis is applied.

  A response slower than `degraded_ratio` of the service's timeout is reported
  degraded: it answered, but close enough to the timeout to be worth saying so.
  """
  @spec classify(boolean(), integer() | nil, pos_integer(), AlertRule.t()) :: check_status()
  def classify(healthy?, response_time_ms, timeout_ms, rule)

  def classify(false, _response_time_ms, _timeout_ms, %AlertRule{}), do: :down

  def classify(true, elapsed, timeout_ms, %AlertRule{degraded_ratio: ratio})
      when is_integer(elapsed) and elapsed >= timeout_ms * ratio,
      do: :degraded

  def classify(true, _response_time_ms, _timeout_ms, %AlertRule{}), do: :healthy

  @doc """
  Folds one probe verdict in, returning the machine that follows.
  """
  @spec advance(t(), check_status(), AlertRule.t()) :: t()
  def advance(%__MODULE__{} = machine, check_status, %AlertRule{} = rule)
      when check_status in @check_statuses do
    machine = tally(machine, check_status)
    %{machine | status: next_status(machine, check_status, rule)}
  end

  @doc """
  Re-judges the last verdict under a rule that has just changed, without
  counting a new probe.

  A monitor used to be restarted to pick up a new rule, which threw away
  everything it had counted, so a threshold lowered to 1 still needed a fresh
  probe to bite. Applying the new thresholds to the observations already taken
  makes the change take effect at once. `nil` means nothing has been observed
  yet, and there is nothing to re-judge.
  """
  @spec reapply(t(), check_status() | nil, AlertRule.t()) :: t()
  def reapply(machine, check_status, rule)

  def reapply(%__MODULE__{} = machine, nil, %AlertRule{}), do: machine

  def reapply(%__MODULE__{} = machine, check_status, %AlertRule{} = rule)
      when check_status in @check_statuses do
    %{machine | status: next_status(machine, check_status, rule)}
  end

  # A failure resets the success run and vice versa: both thresholds are about
  # *consecutive* observations, so one contrary reading starts the count again.
  defp tally(machine, :down) do
    %{machine | consecutive_failures: machine.consecutive_failures + 1, consecutive_successes: 0}
  end

  defp tally(machine, _healthy_or_degraded) do
    %{machine | consecutive_successes: machine.consecutive_successes + 1, consecutive_failures: 0}
  end

  defp next_status(machine, :down, %AlertRule{failure_threshold: threshold})
       when machine.consecutive_failures >= threshold,
       do: :down

  # Failing, but not for long enough yet: hold whatever the status already was.
  defp next_status(machine, :down, %AlertRule{}), do: machine.status

  defp next_status(machine, healthy_or_degraded, %AlertRule{success_threshold: threshold}) do
    if machine.status == :down and machine.consecutive_successes < threshold do
      machine.status
    else
      healthy_or_degraded
    end
  end
end
