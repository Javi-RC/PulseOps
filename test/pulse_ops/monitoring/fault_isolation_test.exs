defmodule PulseOps.Monitoring.FaultIsolationTest do
  @moduledoc """
  The regression test for F10: one monitor crashing over and over used to take
  every other monitor down with it, because the restart budget belonged to the
  supervisor they all shared.
  """

  # Not async: real monitors run here, which is application-wide, and they are
  # separate processes that need the shared sandbox.
  use PulseOps.DataCase, async: false

  import Mox
  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.HealthCheck.Result
  alias PulseOps.Monitoring.HealthCheckMock
  alias PulseOps.Monitoring.MonitorContainer
  alias PulseOps.Monitoring.MonitorSupervisor
  alias PulseOps.Monitoring.ServiceMonitor

  setup :set_mox_global

  setup do
    Application.put_env(:pulse_ops, :start_monitors, true)
    on_exit(fn -> Application.put_env(:pulse_ops, :start_monitors, false) end)

    # The probe never answers in time. That keeps every monitor below from ever
    # writing a check, so each one is killed while it is idle — never while it
    # holds the shared sandbox connection, which would break that connection for
    # the rest of the test with an error that has nothing to do with monitors.
    stub(HealthCheckMock, :check, fn _url, _opts ->
      Process.sleep(40_000)
      {:error, %Result{error: "never reached"}}
    end)

    %{scope: organization_scope_fixture()}
  end

  # The longest the timeout may be, so the monitor's own backstop for a probe
  # that never reports back — which does write a check — fires long after the
  # test is over.
  defp watched_service(scope, name) do
    service_fixture(scope, %{name: name, check_interval_ms: 3_600_000, timeout_ms: 30_000})
  end

  # init and handle_continue both read the database. A call is queued behind
  # them, so once it answers, the monitor is idle and safe to kill.
  defp settle(service_id), do: _ = ServiceMonitor.status(service_id)

  # Waits for a fresh monitor to be registered in place of `previous`. Only looks
  # at the monitor's own name, so it means the same thing with or without
  # containers — which is what lets this test fail against the old supervisor.
  defp await_restart(service_id, previous, attempts \\ 300)
  defp await_restart(_service_id, _previous, 0), do: flunk("the monitor was never restarted")

  defp await_restart(service_id, previous, attempts) do
    case ServiceMonitor.whereis(service_id) do
      pid when is_pid(pid) and pid != previous ->
        pid

      _not_yet ->
        Process.sleep(10)
        await_restart(service_id, previous, attempts - 1)
    end
  end

  # Waits for nothing to be watching the service: no container and no monitor
  # other than the dead `previous`, whose registry entry is dropped
  # asynchronously and can outlive it for a moment.
  defp await_given_up(service_id, previous, attempts \\ 300)
  defp await_given_up(_service_id, _previous, 0), do: flunk("the service is still watched")

  defp await_given_up(service_id, previous, attempts) do
    monitor = ServiceMonitor.whereis(service_id)

    if MonitorContainer.whereis(service_id) == nil and monitor in [nil, previous] and
         (monitor == nil or not Process.alive?(monitor)) do
      :ok
    else
      Process.sleep(10)
      await_given_up(service_id, previous, attempts - 1)
    end
  end

  test "one monitor crashing over and over does not take any other down", %{scope: scope} do
    crashy = watched_service(scope, "Crashy")
    bystander = watched_service(scope, "Bystander")

    on_exit(fn ->
      MonitorSupervisor.stop_monitor(bystander.id)
      MonitorSupervisor.stop_monitor(crashy.id)
    end)

    settle(crashy.id)
    settle(bystander.id)

    bystander_pid = ServiceMonitor.whereis(bystander.id)
    shared_supervisor = Process.whereis(MonitorSupervisor)

    # Five crashes are inside the budget and are restarted.
    last =
      Enum.reduce(1..5, ServiceMonitor.whereis(crashy.id), fn _crash, monitor ->
        Process.exit(monitor, :kill)
        restarted = await_restart(crashy.id, monitor)
        settle(crashy.id)
        restarted
      end)

    # The sixth exceeds it. Before F10 was fixed, this crash terminated the
    # shared supervisor and every monitor under it.
    Process.exit(last, :kill)
    assert :ok = await_given_up(crashy.id, last)
    assert Monitoring.monitor_state(crashy) == :stopped

    # The bystander is not merely running again — it is the same process, never
    # touched, under the same supervisor that never restarted.
    assert ServiceMonitor.whereis(bystander.id) == bystander_pid
    assert Process.whereis(MonitorSupervisor) == shared_supervisor
    assert Monitoring.monitor_state(bystander) == :running
  end

  test "a crash inside the budget restarts the monitor and keeps the service watched", %{
    scope: scope
  } do
    service = watched_service(scope, "Wobbly")
    on_exit(fn -> MonitorSupervisor.stop_monitor(service.id) end)
    settle(service.id)

    original = ServiceMonitor.whereis(service.id)
    Process.exit(original, :kill)

    restarted = await_restart(service.id, original)

    assert restarted != original
    assert Monitoring.monitor_state(service) == :running
  end

  test "a monitor stopping normally takes its container with it", %{scope: scope} do
    service = watched_service(scope, "Retiring")
    settle(service.id)
    original = ServiceMonitor.whereis(service.id)

    # What a monitor does when its service row is gone. An empty container left
    # behind would keep the service's name taken in the registry.
    :ok = GenServer.stop(original, :normal)

    assert :ok = await_given_up(service.id, original)
    refute MonitorSupervisor.watching?(service.id)
  end

  test "a service can be stopped and watched again without a name collision", %{scope: scope} do
    service = watched_service(scope, "Restarted")
    on_exit(fn -> MonitorSupervisor.stop_monitor(service.id) end)
    settle(service.id)

    original = ServiceMonitor.whereis(service.id)

    assert {:ok, container} = MonitorSupervisor.restart_monitor(service)
    assert is_pid(container)

    settle(service.id)
    assert ServiceMonitor.whereis(service.id) != original
    assert MonitorSupervisor.watching?(service.id)
  end
end
