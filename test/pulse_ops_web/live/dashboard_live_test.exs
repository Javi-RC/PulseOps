defmodule PulseOpsWeb.DashboardLiveTest do
  use PulseOpsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PulseOps.IncidentsFixtures
  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Incidents
  alias PulseOps.Monitoring

  setup :register_and_log_in_user_with_org

  describe "rendering" do
    test "invites the user to add a service when there are none", %{conn: conn, scope: scope} do
      {:ok, _live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}")

      assert html =~ "No services yet"
    end

    test "lists services with their status", %{conn: conn, scope: scope} do
      service = service_fixture(scope, %{name: "Payments API"})
      Monitoring.update_service_status(service, :healthy)

      {:ok, _live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}")

      assert html =~ "Payments API"
      assert html =~ "Healthy"
    end

    test "puts failing services above healthy ones", %{conn: conn, scope: scope} do
      healthy = service_fixture(scope, %{name: "AAA Healthy"})
      broken = service_fixture(scope, %{name: "ZZZ Broken"})

      Monitoring.update_service_status(healthy, :healthy)
      Monitoring.update_service_status(broken, :down)

      {:ok, _live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}")

      # Alphabetically the healthy one would come first; what is broken is the
      # reason to open this page.
      assert html =~ ~r/ZZZ Broken.*AAA Healthy/s
    end

    test "says so when nothing is wrong", %{conn: conn, scope: scope} do
      {:ok, _live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}")

      assert html =~ "Nothing is on fire"
    end

    test "shows active incidents", %{conn: conn, scope: scope} do
      service = service_fixture(scope, %{name: "Payments API"})
      incident_fixture(service)

      {:ok, _live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}")

      assert html =~ "Payments API is unavailable"
      assert html =~ "Critical"
      refute html =~ "Nothing is on fire"
    end

    test "does not show another organization's services", %{conn: conn, scope: scope} do
      other_scope = organization_scope_fixture()
      service_fixture(other_scope, %{name: "Not Mine"})

      {:ok, _live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}")

      refute html =~ "Not Mine"
    end
  end

  describe "live updates" do
    test "reflects a status change pushed from a monitor", %{conn: conn, scope: scope} do
      service = service_fixture(scope, %{name: "Payments API"})
      Monitoring.update_service_status(service, :healthy)

      {:ok, live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}")
      assert html =~ "Healthy"

      # Exactly what a monitor does when a service goes down. No polling, no
      # navigation: the update arrives over the socket.
      Monitoring.update_service_status(service, :down)

      assert render(live) =~ "Down"
    end

    test "shows an incident the moment it is opened", %{conn: conn, scope: scope} do
      service = service_fixture(scope, %{name: "Payments API"})

      {:ok, live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}")
      assert html =~ "Nothing is on fire"

      {:ok, _incident} = Incidents.open_incident(service, "connection refused")

      html = render(live)
      assert html =~ "Payments API is unavailable"
      refute html =~ "Nothing is on fire"
    end

    test "drops an incident when it resolves", %{conn: conn, scope: scope} do
      service = service_fixture(scope, %{name: "Payments API"})
      incident_fixture(service)

      {:ok, live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}")
      assert html =~ "Payments API is unavailable"

      {:ok, _resolved} = Incidents.resolve_open_incident(service)

      assert render(live) =~ "Nothing is on fire"
    end

    test "ignores activity in another organization", %{conn: conn, scope: scope} do
      service_fixture(scope, %{name: "Mine"})
      other_scope = organization_scope_fixture()
      other_service = service_fixture(other_scope, %{name: "Theirs"})

      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}")

      {:ok, _incident} = Incidents.open_incident(other_service)

      html = render(live)
      assert html =~ "Nothing is on fire"
      refute html =~ "Theirs"
    end
  end

  describe "tenancy" do
    test "redirects a user who is not a member", %{conn: conn} do
      outsider = organization_scope_fixture()

      assert {:error, {:redirect, %{to: "/"}}} =
               live(conn, ~p"/orgs/#{outsider.organization.slug}")
    end
  end
end
