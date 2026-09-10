defmodule PulseOps.Monitoring.BootstrapperTest do
  # Not async: the second half starts real monitors, which is application-wide
  # and needs the shared sandbox.
  use PulseOps.DataCase, async: false

  import Mox
  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.Bootstrapper
  alias PulseOps.Monitoring.HealthCheck.Result
  alias PulseOps.Monitoring.HealthCheckMock
  alias PulseOps.Monitoring.MonitorSupervisor
  alias PulseOps.Monitoring.ServiceMonitor

  setup :set_mox_global

  setup do
    # The probe never answers in time, so no monitor started here writes a check
    # while the test is running.
    stub(HealthCheckMock, :check, fn _url, _opts ->
      Process.sleep(40_000)
      {:error, %Result{error: "never reached"}}
    end)

    %{scope: organization_scope_fixture()}
  end

  describe "listing enabled services a page at a time" do
    test "walks every enabled service in id order and skips disabled ones", %{scope: scope} do
      [first, second, third] = for n <- 1..3, do: service_fixture(scope, %{name: "Enabled #{n}"})
      _disabled = service_fixture(scope, %{name: "Disabled", enabled: false})

      ids = fn services -> Enum.map(services, & &1.id) end

      assert ids.(Monitoring.list_enabled_services(after: 0, limit: 2)) == [first.id, second.id]
      assert ids.(Monitoring.list_enabled_services(after: second.id, limit: 2)) == [third.id]
      assert Monitoring.list_enabled_services(after: third.id, limit: 2) == []
    end
  end

  describe "starting monitors at boot" do
    test "starts one monitor per enabled service, across several pages", %{scope: scope} do
      services =
        for n <- 1..5 do
          service_fixture(scope, %{
            name: "Boot #{n}",
            check_interval_ms: 3_600_000,
            timeout_ms: 30_000
          })
        end

      disabled = service_fixture(scope, %{name: "Off", enabled: false})

      Application.put_env(:pulse_ops, :start_monitors, true)

      on_exit(fn ->
        Enum.each(services, &MonitorSupervisor.stop_monitor(&1.id))
        Application.put_env(:pulse_ops, :start_monitors, false)
      end)

      # Five services in pages of two is three queries, none of them holding
      # every row at once.
      assert Bootstrapper.start_monitors(page_size: 2) == 5

      for service <- services do
        assert is_pid(ServiceMonitor.whereis(service.id))
        # A call is queued behind init and the boot reconciliation, both of which
        # read the database; once it answers, the monitor is idle and safe to
        # stop when the test ends.
        _ = ServiceMonitor.status(service.id)
      end

      assert ServiceMonitor.whereis(disabled.id) == nil
    end

    test "starts nothing where monitors are switched off", %{scope: scope} do
      service_fixture(scope)

      assert Bootstrapper.start_monitors(page_size: 2) == 0
    end
  end
end
