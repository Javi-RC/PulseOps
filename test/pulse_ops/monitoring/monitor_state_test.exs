defmodule PulseOps.Monitoring.MonitorStateTest do
  # Not async: some tests switch real monitors on, which is application-wide,
  # and the monitors are separate processes that need the shared sandbox.
  use PulseOps.DataCase, async: false

  import Mox
  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.HealthCheck.Result
  alias PulseOps.Monitoring.HealthCheckMock
  alias PulseOps.Monitoring.MonitorSupervisor
  alias PulseOps.Monitoring.ServiceMonitor

  setup :set_mox_global

  setup do
    stub(HealthCheckMock, :check, fn _url, _opts ->
      {:ok, %Result{http_status: 200, response_time_ms: 5}}
    end)

    %{scope: organization_scope_fixture()}
  end

  test "a disabled service is disabled, in any environment", %{scope: scope} do
    service = service_fixture(scope, %{enabled: false})

    assert Monitoring.monitor_state(service) == :disabled
  end

  test "where monitors never run, their absence says nothing", %{scope: scope} do
    # The suite runs with start_monitors off (ADR-005). Reporting every service
    # as "nothing is watching this" here would be true and useless.
    service = service_fixture(scope, %{check_interval_ms: 3_600_000})

    assert Monitoring.monitor_state(service) == :not_applicable
  end

  describe "where monitors run" do
    setup do
      Application.put_env(:pulse_ops, :start_monitors, true)
      on_exit(fn -> Application.put_env(:pulse_ops, :start_monitors, false) end)
    end

    # Creates the service without a monitor, then starts one and waits until its
    # boot probe has been fully handled. Stopping a monitor while that probe is
    # inside its database call disconnects the shared sandbox connection for the
    # rest of the test.
    defp service_with_settled_monitor(scope) do
      Application.put_env(:pulse_ops, :start_monitors, false)
      service = service_fixture(scope, %{check_interval_ms: 3_600_000})
      Application.put_env(:pulse_ops, :start_monitors, true)

      Monitoring.subscribe_checks(scope, service)
      {:ok, _pid} = MonitorSupervisor.start_monitor(service)
      assert_receive {:check_recorded, _check}, 3_000
      _ = ServiceMonitor.status(service.id)
      service
    end

    test "a service with a live monitor is running", %{scope: scope} do
      service = service_with_settled_monitor(scope)
      on_exit(fn -> MonitorSupervisor.stop_monitor(service.id) end)

      assert Monitoring.monitor_state(service) == :running
    end

    test "an enabled service with no monitor is stopped", %{scope: scope} do
      service = service_with_settled_monitor(scope)

      # Stands in for a monitor its supervisor gave up on: from the outside the
      # two are indistinguishable, which is exactly what this state is for.
      :ok = MonitorSupervisor.stop_monitor(service.id)

      assert Monitoring.monitor_state(service) == :stopped
    end
  end
end
