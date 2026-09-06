defmodule PulseOps.Monitoring.ServiceMonitorTest do
  # Not async: the monitor and its probe tasks are separate processes, so they
  # need the shared sandbox connection and Mox in global mode.
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
  setup :verify_on_exit!

  setup do
    scope = organization_scope_fixture()

    # A long interval keeps the scheduler out of the way: every probe in these
    # tests is triggered explicitly.
    service =
      service_fixture(scope, %{
        check_interval_ms: 3_600_000,
        timeout_ms: 5_000,
        url: "https://example.test/health"
      })

    %{scope: scope, service: service}
  end

  defp stub_result(fun) when is_function(fun, 0) do
    stub(HealthCheckMock, :check, fn _url, _opts -> fun.() end)
  end

  defp healthy(response_time_ms \\ 100) do
    {:ok, %Result{http_status: 200, response_time_ms: response_time_ms}}
  end

  defp down(error \\ "connection refused") do
    {:error, %Result{error: error}}
  end

  # Starts a monitor and waits out the initial probe it fires on boot, so each
  # test starts from a known position.
  defp start_monitor(service) do
    Monitoring.subscribe_checks(organization_scope_for(service), service)

    pid = start_supervised!({ServiceMonitor, service})
    assert_receive {:check_recorded, _check}, 2_000
    sync(service)

    pid
  end

  # The check is broadcast from inside the callback that also updates the status,
  # so receiving it does not mean the callback finished. A call does: it is
  # queued behind the in-flight callback and cannot be served until it returns.
  defp sync(service), do: ServiceMonitor.status(service.id)

  defp organization_scope_for(service) do
    %PulseOps.Accounts.Scope{organization: %{id: service.organization_id}}
  end

  # Triggers one probe and returns once its outcome has been fully processed.
  # The check is recorded inside the same callback that updates the status, so
  # a subsequent call is guaranteed to observe the new state.
  defp probe(service) do
    ServiceMonitor.check_now(service.id)
    assert_receive {:check_recorded, check}, 2_000
    sync(service)
    check
  end

  describe "status transitions" do
    test "stays up until failures are sustained", %{service: service} do
      stub_result(&down/0)
      start_monitor(service)

      # One failure has already happened on boot.
      assert ServiceMonitor.status(service.id).status != :down

      probe(service)
      assert ServiceMonitor.status(service.id).status != :down

      probe(service)
      assert ServiceMonitor.status(service.id).status == :down
    end

    test "reports healthy on a fast success", %{service: service} do
      stub_result(&healthy/0)
      start_monitor(service)

      assert ServiceMonitor.status(service.id).status == :healthy
    end

    test "reports degraded when the response is close to the timeout", %{service: service} do
      # timeout_ms is 5000, so anything at or beyond 2500ms is degraded.
      stub_result(fn -> healthy(4_000) end)
      start_monitor(service)

      assert ServiceMonitor.status(service.id).status == :degraded
    end

    test "recovers only after sustained success", %{service: service} do
      stub_result(&down/0)
      start_monitor(service)
      probe(service)
      probe(service)
      assert ServiceMonitor.status(service.id).status == :down

      stub_result(&healthy/0)

      probe(service)

      assert ServiceMonitor.status(service.id).status == :down,
             "one success must not clear a down"

      probe(service)
      assert ServiceMonitor.status(service.id).status == :healthy
    end

    test "resets the failure tally on a success", %{service: service} do
      stub_result(&down/0)
      start_monitor(service)
      probe(service)
      assert ServiceMonitor.status(service.id).consecutive_failures == 2

      stub_result(&healthy/0)
      probe(service)
      assert ServiceMonitor.status(service.id).consecutive_failures == 0
    end
  end

  describe "persistence and broadcasting" do
    test "records a row for every probe", %{scope: scope, service: service} do
      stub_result(&healthy/0)
      start_monitor(service)
      probe(service)
      probe(service)

      checks = Monitoring.list_recent_checks(scope, service)
      assert length(checks) == 3
      assert Enum.all?(checks, &(&1.status == :healthy))
      assert Enum.all?(checks, &(&1.http_status == 200))
    end

    test "records the failure reason", %{scope: scope, service: service} do
      stub_result(fn -> down("connection refused") end)
      start_monitor(service)

      assert [check] = Monitoring.list_recent_checks(scope, service)
      assert check.status == :down
      assert check.error == "connection refused"
    end

    test "announces a status change to the organization", %{service: service} do
      Phoenix.PubSub.subscribe(
        PulseOps.PubSub,
        "organization:#{service.organization_id}:services"
      )

      stub_result(&down/0)
      start_monitor(service)
      probe(service)
      probe(service)

      assert_receive {:updated, updated}
      assert updated.id == service.id
      assert updated.status == :down
      assert updated.last_checked_at
    end

    test "stays quiet while the status is unchanged", %{service: service} do
      stub_result(&healthy/0)
      start_monitor(service)

      # Drain the transition from :unknown to :healthy on the first probe.
      Phoenix.PubSub.subscribe(
        PulseOps.PubSub,
        "organization:#{service.organization_id}:services"
      )

      probe(service)
      probe(service)

      # Three healthy probes, one status change, no repeated announcements: this
      # is what keeps the dashboard from re-rendering on every tick (ADR-003).
      refute_receive {:updated, _service}, 200
    end
  end

  describe "the monitor does not block on the network" do
    test "answers calls while a probe is in flight", %{service: service} do
      stub_result(&healthy/0)
      start_monitor(service)

      test_pid = self()

      stub(HealthCheckMock, :check, fn _url, _opts ->
        send(test_pid, :probe_started)
        Process.sleep(500)
        healthy()
      end)

      ServiceMonitor.check_now(service.id)
      assert_receive :probe_started, 1_000

      # If the request ran inside the callback this call would block for the
      # whole 500ms and time out (ADR-002).
      assert %{checking?: true} = GenServer.call(ServiceMonitor.via(service.id), :status, 100)
    end

    test "survives a probe that crashes", %{scope: scope, service: service} do
      stub_result(&healthy/0)
      pid = start_monitor(service)

      stub(HealthCheckMock, :check, fn _url, _opts -> raise "boom" end)

      probe(service)

      assert Process.alive?(pid)
      assert [check | _rest] = Monitoring.list_recent_checks(scope, service)
      assert check.status == :down
      assert check.error =~ "crashed"
    end
  end

  describe "supervision" do
    setup do
      # These tests exercise the real supervisor path, which is switched off by
      # default in the test environment (ADR-005).
      Application.put_env(:pulse_ops, :start_monitors, true)
      on_exit(fn -> Application.put_env(:pulse_ops, :start_monitors, false) end)
    end

    test "creating a service starts its monitor", %{scope: scope} do
      stub_result(&healthy/0)
      service = service_fixture(scope, %{check_interval_ms: 3_600_000})
      on_exit(fn -> MonitorSupervisor.stop_monitor(service.id) end)

      assert is_pid(ServiceMonitor.whereis(service.id))
    end

    test "deleting a service stops its monitor", %{scope: scope} do
      stub_result(&healthy/0)
      service = service_fixture(scope, %{check_interval_ms: 3_600_000})
      assert is_pid(ServiceMonitor.whereis(service.id))

      {:ok, _service} = Monitoring.delete_service(scope, service)

      assert ServiceMonitor.whereis(service.id) == nil
    end

    test "a killed monitor is restarted and the others keep running", %{scope: scope} do
      stub_result(&healthy/0)

      one = service_fixture(scope, %{name: "One", check_interval_ms: 3_600_000})
      two = service_fixture(scope, %{name: "Two", check_interval_ms: 3_600_000})

      on_exit(fn ->
        MonitorSupervisor.stop_monitor(one.id)
        MonitorSupervisor.stop_monitor(two.id)
      end)

      original = ServiceMonitor.whereis(one.id)
      survivor = ServiceMonitor.whereis(two.id)
      assert is_pid(original) and is_pid(survivor)

      Process.exit(original, :kill)

      restarted = wait_for_new_pid(one.id, original)

      assert is_pid(restarted)
      assert restarted != original
      # Fault isolation: killing one monitor must not disturb any other.
      assert Process.alive?(survivor)
      assert ServiceMonitor.whereis(two.id) == survivor
    end

    test "stop_monitor removes the process", %{scope: scope} do
      stub_result(&healthy/0)
      service = service_fixture(scope, %{check_interval_ms: 3_600_000})
      assert is_pid(ServiceMonitor.whereis(service.id))

      :ok = MonitorSupervisor.stop_monitor(service.id)
      assert ServiceMonitor.whereis(service.id) == nil
    end

    test "a disabled service gets no monitor", %{scope: scope} do
      service = service_fixture(scope, %{enabled: false})

      assert MonitorSupervisor.start_monitor(service) == {:ok, :disabled}
      assert ServiceMonitor.whereis(service.id) == nil
    end
  end

  defp wait_for_new_pid(service_id, old_pid, attempts \\ 100) do
    case ServiceMonitor.whereis(service_id) do
      nil when attempts > 0 ->
        Process.sleep(20)
        wait_for_new_pid(service_id, old_pid, attempts - 1)

      ^old_pid when attempts > 0 ->
        Process.sleep(20)
        wait_for_new_pid(service_id, old_pid, attempts - 1)

      pid ->
        pid
    end
  end
end
