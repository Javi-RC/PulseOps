defmodule PulseOps.Monitoring.MonitorSupervisor do
  @moduledoc """
  Owns the per-service monitor processes.

  Monitors are `:transient`, so one that keeps crashing is restarted a bounded
  number of times and then given up on, without disturbing any other monitor.
  """

  use DynamicSupervisor

  alias PulseOps.Monitoring.Service
  alias PulseOps.Monitoring.ServiceMonitor

  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      # A monitor whose service is unreachable in a way that crashes it should be
      # abandoned rather than restarted for ever.
      max_restarts: 5,
      max_seconds: 60
    )
  end

  @doc """
  Starts a monitor for the service, unless one is already running or monitors
  are disabled for this environment.
  """
  def start_monitor(%Service{} = service) do
    cond do
      not enabled?() -> {:ok, :disabled}
      not service.enabled -> {:ok, :disabled}
      true -> DynamicSupervisor.start_child(__MODULE__, {ServiceMonitor, service})
    end
  end

  @doc """
  Stops the monitor for a service, if there is one.

  Returns once the registry has released the name. `terminate_child/2` waits for
  the process to exit, but the registry only drops its entry when it processes
  the resulting `:DOWN`, so returning any earlier would let a following
  `start_monitor/1` collide with the name of a process that is already dead.
  """
  def stop_monitor(service_id) do
    case ServiceMonitor.whereis(service_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        result = DynamicSupervisor.terminate_child(__MODULE__, pid)
        await_down(pid, ref)
        await_unregistered(service_id)
        result
    end
  end

  @down_timeout_ms 5_000
  @unregister_attempts 20

  # The process dying is an event, so wait for the event. This used to be part
  # of a loop that slept in 10 ms steps for up to half a second.
  defp await_down(pid, ref) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @down_timeout_ms -> Process.demonitor(ref, [:flush])
    end
  end

  # The registry's cleanup is not our event to wait for: it drops its entry when
  # *it* handles the `:DOWN`, in its own process, and there is no message to
  # subscribe to for that. Once `await_down/2` has returned the registry has
  # almost always handled it too, so this normally reads the table once and
  # returns. The yield is `Process.sleep(0)` — give up the rest of this slice
  # rather than idle for a fixed period.
  defp await_unregistered(service_id, attempts \\ @unregister_attempts)
  defp await_unregistered(_service_id, 0), do: :ok

  defp await_unregistered(service_id, attempts) do
    case ServiceMonitor.whereis(service_id) do
      nil ->
        :ok

      _pid ->
        Process.sleep(0)
        await_unregistered(service_id, attempts - 1)
    end
  end

  @doc """
  Restarts a monitor so it picks up a changed url, interval or timeout.
  """
  def restart_monitor(%Service{} = service) do
    stop_monitor(service.id)
    start_monitor(service)
  end

  @doc """
  How many monitors are currently running.
  """
  def count_monitors do
    %{active: active} = DynamicSupervisor.count_children(__MODULE__)
    active
  end

  @doc """
  Whether monitors run in this environment. False in tests, where they would do
  real network calls and check out connections outside the Ecto sandbox.
  """
  def enabled?, do: Application.get_env(:pulse_ops, :start_monitors, true)
end
