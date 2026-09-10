defmodule PulseOpsWeb.UxLiveTest do
  # Not async: the monitor-health tests switch real monitors on.
  use PulseOpsWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import PulseOps.IncidentsFixtures
  import PulseOps.MonitoringFixtures

  alias PulseOps.Incidents
  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.AlertRule
  alias PulseOps.Monitoring.HealthCheck.Result
  alias PulseOps.Monitoring.HealthCheckMock
  alias PulseOps.Monitoring.MonitorSupervisor
  alias PulseOps.Monitoring.ServiceMonitor

  setup :register_and_log_in_user_with_org
  setup :set_mox_global

  setup do
    stub(HealthCheckMock, :check, fn _url, _opts ->
      {:ok, %Result{http_status: 200, response_time_ms: 5}}
    end)

    :ok
  end

  defp service_path(scope, service), do: ~p"/orgs/#{scope.organization.slug}/services/#{service}"
  defp incidents_path(scope), do: ~p"/orgs/#{scope.organization.slug}/incidents"

  describe "the time window on a service" do
    test "reads the last 24 hours unless told otherwise", %{conn: conn, scope: scope} do
      service = service_fixture(scope)

      {:ok, _live, html} = live(conn, service_path(scope, service))

      assert html =~ "Uptime (24h)"
    end

    test "switching the window changes the figures and the URL", %{conn: conn, scope: scope} do
      service = service_fixture(scope)
      {:ok, live, _html} = live(conn, service_path(scope, service))

      html = live |> element("#window-selector a", "30d") |> render_click()

      assert html =~ "Uptime (30d)"
      assert_patch(live, service_path(scope, service) <> "?window=30d")
    end

    test "a window in the URL is honoured on arrival", %{conn: conn, scope: scope} do
      service = service_fixture(scope)

      {:ok, _live, html} = live(conn, service_path(scope, service) <> "?window=7d")

      assert html =~ "Uptime (7d)"
    end

    test "an unknown window falls back rather than failing", %{conn: conn, scope: scope} do
      service = service_fixture(scope)

      {:ok, _live, html} = live(conn, service_path(scope, service) <> "?window=forever")

      assert html =~ "Uptime (24h)"
    end
  end

  describe "whether anything is watching a service" do
    setup do
      Application.put_env(:pulse_ops, :start_monitors, true)
      on_exit(fn -> Application.put_env(:pulse_ops, :start_monitors, false) end)
    end

    # Creates the service without a monitor, then starts one and waits until its
    # boot probe has been fully handled. Stopping a monitor while that probe is
    # still inside its database call disconnects the shared sandbox connection,
    # and every query for the rest of the test fails with an ownership error
    # that looks nothing like the cause.
    defp service_with_settled_monitor(scope) do
      Application.put_env(:pulse_ops, :start_monitors, false)
      service = service_fixture(scope, %{check_interval_ms: 3_600_000})
      Application.put_env(:pulse_ops, :start_monitors, true)

      Monitoring.subscribe_checks(scope, service)
      {:ok, _pid} = MonitorSupervisor.start_monitor(service)
      assert_receive {:check_recorded, _check}, 3_000

      # The check is broadcast from inside the callback that records it, so a
      # call is what proves that callback has returned.
      _ = ServiceMonitor.status(service.id)
      service
    end

    test "says nothing while its monitor is running", %{conn: conn, scope: scope} do
      service = service_with_settled_monitor(scope)
      on_exit(fn -> MonitorSupervisor.stop_monitor(service.id) end)

      {:ok, live, _html} = live(conn, service_path(scope, service))

      refute has_element?(live, "#monitor-stopped")
    end

    test "says so plainly when nothing is", %{conn: conn, scope: scope} do
      service = service_with_settled_monitor(scope)
      :ok = MonitorSupervisor.stop_monitor(service.id)

      {:ok, live, html} = live(conn, service_path(scope, service))

      # The invisible failure: an enabled service still showing its last status
      # as though it were current.
      assert has_element?(live, "#monitor-stopped")
      assert html =~ "Nothing is watching this service"
    end

    test "a paused service is described as paused, not as broken", %{conn: conn, scope: scope} do
      service = service_fixture(scope, %{enabled: false})

      {:ok, live, _html} = live(conn, service_path(scope, service))

      assert has_element?(live, "#monitor-disabled")
      refute has_element?(live, "#monitor-stopped")
    end
  end

  describe "incident pagination" do
    setup %{scope: scope} do
      %{service: service_fixture(scope, %{name: "Payments API"})}
    end

    defp resolved(service, count), do: for(_ <- 1..count, do: resolved_incident_fixture(service))

    test "shows no pagination when everything fits", %{conn: conn, scope: scope, service: service} do
      resolved(service, 3)

      {:ok, live, _html} = live(conn, incidents_path(scope))

      refute has_element?(live, "#incident-pagination")
    end

    test "pages through older incidents", %{conn: conn, scope: scope, service: service} do
      resolved(service, 27)

      {:ok, live, _html} = live(conn, incidents_path(scope))

      assert has_element?(live, "#incident-pagination a[rel=next]")
      refute has_element?(live, "#incident-pagination a[rel=prev]")

      live |> element("#incident-pagination a[rel=next]") |> render_click()

      assert_patch(live, incidents_path(scope) <> "?filter=all&page=2")
      assert has_element?(live, "#incident-pagination a[rel=prev]")
      refute has_element?(live, "#incident-pagination a[rel=next]")
    end

    test "filters to what is open", %{conn: conn, scope: scope, service: service} do
      resolved(service, 2)
      other = service_fixture(scope, %{name: "Search"})
      incident_fixture(other)

      {:ok, live, _html} = live(conn, incidents_path(scope) <> "?filter=open")

      html = render(live)
      assert html =~ "Search is unavailable"
      refute html =~ "Payments API is unavailable"
    end

    test "nonsense in the URL is the first page of everything", %{
      conn: conn,
      scope: scope,
      service: service
    } do
      resolved(service, 1)

      {:ok, _live, html} = live(conn, incidents_path(scope) <> "?page=banana&filter=nope")

      assert html =~ "Payments API is unavailable"
    end

    test "a live update keeps the reader on the page they are on", %{
      conn: conn,
      scope: scope,
      service: service
    } do
      resolved(service, 27)

      {:ok, live, _html} = live(conn, incidents_path(scope) <> "?filter=all&page=2")

      {:ok, _incident} =
        Incidents.open_incident(service_fixture(scope, %{name: "Search"}), AlertRule.default())

      # Still on page two, not bounced back to the first page underneath them.
      assert has_element?(live, "#incident-pagination span", "Page 2")
    end
  end

  describe "deleting a service" do
    test "asks first, and says what goes with it", %{conn: conn, scope: scope} do
      service = service_fixture(scope, %{name: "Payments API"})

      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/services")

      # Deleting cascades away every check and incident. The confirmation is the
      # only thing between a stray click and that, so it is pinned by a test.
      assert has_element?(
               live,
               ~s([phx-click="delete"][phx-value-id="#{service.id}"][data-confirm*="checks and incidents"])
             )
    end
  end
end
