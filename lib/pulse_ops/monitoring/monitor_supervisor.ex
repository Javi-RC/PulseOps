defmodule PulseOps.Monitoring.MonitorSupervisor do
  @moduledoc """
  Owns one `MonitorContainer` per watched service.

  It does not supervise monitors directly any more, and that is the point. Its
  restart intensity used to be the only restart budget there was, shared by every
  monitor, so one service crashing six times in a minute took every other
  service's monitor down with it (F10). Each container now carries its own budget
  for its own monitor, and containers are temporary: a container that gives up
  exits and is not restarted, so nothing a single service does is ever counted
  against this supervisor.
  """

  use DynamicSupervisor

  alias PulseOps.Monitoring.MonitorContainer
  alias PulseOps.Monitoring.Service
  alias PulseOps.Monitoring.ServiceMonitor

  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # No max_restarts here on purpose. The children are temporary and are never
    # restarted, so this supervisor's intensity has nothing to count; the budget
    # that decides when to give up on a monitor lives in its container.
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts watching a service, unless it is already watched or monitors are
  disabled for this environment.
  """
  def start_monitor(%Service{} = service) do
    cond do
      not enabled?() -> {:ok, :disabled}
      not service.enabled -> {:ok, :disabled}
      true -> DynamicSupervisor.start_child(__MODULE__, {MonitorContainer, service})
    end
  end

  @doc """
  Stops watching a service, if it is watched.

  Returns once the registry has released both names. `terminate_child/2` waits
  for the container to exit, but the registry drops each entry only when it
  processes the resulting `:DOWN`, so returning any earlier would let a following
  `start_monitor/1` collide with the name of a process that is already dead.
  """
  def stop_monitor(service_id) do
    case MonitorContainer.whereis(service_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        result = DynamicSupervisor.terminate_child(__MODULE__, pid)
        await_down(pid, ref)
        await_unregistered(service_id)
        normalize(result)
    end
  end

  # A container can exit on its own between being looked up and being
  # terminated — it gave up on its monitor, or the monitor stopped because its
  # service was deleted. Either way the service is no longer watched, which is
  # what the caller asked for.
  defp normalize({:error, :not_found}), do: :ok
  defp normalize(result), do: result

  @down_timeout_ms 5_000
  @unregister_attempts 100

  # The process dying is an event, so wait for the event.
  defp await_down(pid, ref) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @down_timeout_ms -> Process.demonitor(ref, [:flush])
    end
  end

  # The registry's cleanup is not our event to wait for: it drops an entry when
  # *it* handles the `:DOWN`, in its own process, and there is no message to
  # subscribe to for that. So this half stays a bounded poll — it almost always
  # reads the table once and returns, because `await_down/2` has already waited
  # out the part that takes time.
  #
  # `Process.sleep(0)` was tried here and is not enough: yielding the scheduler
  # slice does not guarantee the registry has run.
  defp await_unregistered(service_id, attempts \\ @unregister_attempts)
  defp await_unregistered(_service_id, 0), do: :ok

  defp await_unregistered(service_id, attempts) do
    if ServiceMonitor.whereis(service_id) || MonitorContainer.whereis(service_id) do
      Process.sleep(1)
      await_unregistered(service_id, attempts - 1)
    else
      :ok
    end
  end

  @doc """
  Restarts watching a service so it picks up a changed url, interval or timeout.
  """
  def restart_monitor(%Service{} = service) do
    stop_monitor(service.id)
    start_monitor(service)
  end

  @doc """
  Whether a service is being watched.

  Asks about the container rather than the monitor. A monitor that has just
  crashed is briefly not registered while its container restarts it, and that
  service is still being watched; it stops being watched only when the container
  gives up and exits.
  """
  def watching?(service_id), do: MonitorContainer.whereis(service_id) != nil

  @doc """
  How many services are currently being watched.
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
