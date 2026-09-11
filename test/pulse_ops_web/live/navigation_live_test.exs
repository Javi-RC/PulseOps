defmodule PulseOpsWeb.NavigationLiveTest do
  use PulseOpsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PulseOps.IncidentsFixtures
  import PulseOps.MonitoringFixtures

  alias PulseOps.Incidents
  alias PulseOps.Organizations.Membership
  alias PulseOps.Repo

  setup :register_and_log_in_user_with_org

  defp demote(scope, user, role) do
    Repo.get_by!(Membership, organization_id: scope.organization.id, user_id: user.id)
    |> Ecto.Changeset.change(role: role)
    |> Repo.update!()
  end

  defp active_link(live, label), do: has_element?(live, ~s(nav a[aria-current="page"]), label)

  describe "sections" do
    test "groups what shapes the paging under Operations", %{conn: conn, scope: scope} do
      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}")

      assert has_element?(live, "#nav-operations", "Operations")
      assert has_element?(live, "#nav-organization", "Organization")

      assert has_element?(
               live,
               ~s(nav a[href="/orgs/#{scope.organization.slug}/settings/alert-rules"]),
               "Alert rules"
             )
    end

    test "marks alert rules, not Settings, while looking at them", %{conn: conn, scope: scope} do
      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/settings/alert-rules")

      assert active_link(live, "Alert rules")
      refute active_link(live, "Settings")
    end

    test "still marks Settings on the settings pages", %{conn: conn, scope: scope} do
      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/settings/api-tokens")

      assert active_link(live, "Settings")
      refute active_link(live, "Alert rules")
    end

    test "a viewer can reach alert rules but not Settings", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      demote(scope, user, :viewer)

      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}")

      assert has_element?(live, "nav a", "Alert rules")
      refute has_element?(live, "nav a", "Settings")
    end
  end

  describe "the open incident count" do
    test "is absent while nothing is open", %{conn: conn, scope: scope} do
      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/members")

      refute has_element?(live, "#nav-count-incidents")
    end

    test "shows how many are open, from any page", %{conn: conn, scope: scope} do
      incident_fixture(service_fixture(scope, %{name: "Payments API"}))
      incident_fixture(service_fixture(scope, %{name: "Search API"}))

      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/members")

      assert has_element?(live, "#nav-count-incidents", "2")
      assert has_element?(live, "#nav-count-incidents .sr-only", "open")
    end

    test "follows incidents opening and resolving without a reload", %{
      conn: conn,
      scope: scope
    } do
      service = service_fixture(scope)
      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/members")

      incident_fixture(service)
      assert has_element?(live, "#nav-count-incidents", "1")

      {:ok, _resolved} = Incidents.resolve_open_incident(service)
      refute has_element?(live, "#nav-count-incidents")
    end

    test "does not hand the pages that follow incidents each message twice", %{
      conn: conn,
      scope: scope
    } do
      service = service_fixture(scope, %{name: "Payments API"})
      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/incidents")

      incident_fixture(service)

      html = render(live)
      assert length(Regex.scan(~r/Payments API is unavailable/, html)) == 1
      assert has_element?(live, "#nav-count-incidents", "1")
    end
  end
end
