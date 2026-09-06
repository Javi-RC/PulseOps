defmodule PulseOpsWeb.IncidentLiveTest do
  use PulseOpsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PulseOps.IncidentsFixtures
  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Incidents
  alias PulseOps.Organizations.Membership
  alias PulseOps.Repo

  setup :register_and_log_in_user_with_org

  setup %{scope: scope} do
    service = service_fixture(scope, %{name: "Payments API"})
    %{service: service}
  end

  describe "Index" do
    test "says when there is nothing to show", %{conn: conn, scope: scope} do
      {:ok, _live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}/incidents")

      assert html =~ "No incidents recorded yet"
    end

    test "lists incidents with their severity", %{conn: conn, scope: scope, service: service} do
      incident_fixture(service)

      {:ok, _live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}/incidents")

      assert html =~ "Payments API is unavailable"
      assert html =~ "Critical"
    end

    test "appears live when an incident opens", %{conn: conn, scope: scope, service: service} do
      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/incidents")

      {:ok, _incident} = Incidents.open_incident(service)

      assert render(live) =~ "Payments API is unavailable"
    end

    test "hides another organization's incidents", %{conn: conn, scope: scope} do
      other_scope = organization_scope_fixture()
      other_service = service_fixture(other_scope, %{name: "Theirs"})
      incident_fixture(other_service)

      {:ok, _live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}/incidents")

      refute html =~ "Theirs"
    end
  end

  describe "Show" do
    test "renders the timeline with the automatic detection", %{
      conn: conn,
      scope: scope,
      service: service
    } do
      incident = incident_fixture(service, "connection refused")

      {:ok, _live, html} =
        live(conn, ~p"/orgs/#{scope.organization.slug}/incidents/#{incident}")

      assert html =~ "Payments API is unavailable"
      assert html =~ "connection refused"
      # Written by the monitor, so it must not be attributed to a person.
      assert html =~ "Detected automatically"
    end

    test "moves the incident through the workflow", %{
      conn: conn,
      scope: scope,
      service: service
    } do
      incident = incident_fixture(service)

      {:ok, live, _html} =
        live(conn, ~p"/orgs/#{scope.organization.slug}/incidents/#{incident}")

      html =
        live
        |> element("button[phx-value-status=investigating]")
        |> render_click()

      assert html =~ "Status updated"
      assert Incidents.get_incident!(scope, incident.id).status == :investigating
    end

    test "records the root cause", %{conn: conn, scope: scope, service: service} do
      incident = incident_fixture(service)

      {:ok, live, _html} =
        live(conn, ~p"/orgs/#{scope.organization.slug}/incidents/#{incident}")

      live
      |> form("form[phx-submit=save_cause]", cause: "Connection pool exhausted")
      |> render_submit()

      assert Incidents.get_incident!(scope, incident.id).cause == "Connection pool exhausted"
    end

    test "adds a note attributed to the author", %{conn: conn, scope: scope, service: service} do
      incident = incident_fixture(service)

      {:ok, live, _html} =
        live(conn, ~p"/orgs/#{scope.organization.slug}/incidents/#{incident}")

      html =
        live
        |> form("form[phx-submit=add_note]", note: "Paging the on-call engineer")
        |> render_submit()

      assert html =~ "Paging the on-call engineer"
      assert html =~ scope.user.email
    end

    test "resolves the incident", %{conn: conn, scope: scope, service: service} do
      incident = incident_fixture(service)

      {:ok, live, _html} =
        live(conn, ~p"/orgs/#{scope.organization.slug}/incidents/#{incident}")

      html = live |> element("button[phx-click=resolve]") |> render_click()

      assert html =~ "Incident resolved"

      resolved = Incidents.get_incident!(scope, incident.id)
      assert resolved.status == :resolved
      assert resolved.resolved_by_id == scope.user.id
    end

    test "updates live when somebody else resolves it", %{
      conn: conn,
      scope: scope,
      service: service
    } do
      incident = incident_fixture(service)

      {:ok, live, html} =
        live(conn, ~p"/orgs/#{scope.organization.slug}/incidents/#{incident}")

      assert html =~ "Still open"

      {:ok, _resolved} = Incidents.resolve_open_incident(service)

      assert render(live) =~ "Recovered on its own"
    end

    test "a viewer sees the incident but gets no controls", %{
      conn: conn,
      scope: scope,
      user: user,
      service: service
    } do
      incident = incident_fixture(service)
      demote_to_viewer(scope, user)

      {:ok, _live, html} =
        live(conn, ~p"/orgs/#{scope.organization.slug}/incidents/#{incident}")

      assert html =~ "Payments API is unavailable"
      refute html =~ "phx-click=\"resolve\""
    end

    test "raises for an incident in another organization", %{conn: conn, scope: scope} do
      other_scope = organization_scope_fixture()
      other_service = service_fixture(other_scope)
      theirs = incident_fixture(other_service)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/orgs/#{scope.organization.slug}/incidents/#{theirs}")
      end
    end
  end

  defp demote_to_viewer(scope, user) do
    Repo.get_by!(Membership, organization_id: scope.organization.id, user_id: user.id)
    |> Ecto.Changeset.change(role: :viewer)
    |> Repo.update!()
  end
end
