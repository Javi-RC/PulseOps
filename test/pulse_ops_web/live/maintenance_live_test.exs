defmodule PulseOpsWeb.MaintenanceLiveTest do
  use PulseOpsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PulseOps.MonitoringFixtures

  alias PulseOps.Incidents
  alias PulseOps.Maintenance
  alias PulseOps.Monitoring.AlertRule
  alias PulseOps.Organizations.Membership
  alias PulseOps.Repo

  setup :register_and_log_in_user_with_org

  defp path(scope), do: ~p"/orgs/#{scope.organization.slug}/maintenance"

  defp at(minutes) do
    DateTime.utc_now(:second)
    |> DateTime.add(minutes * 60, :second)
    |> Calendar.strftime("%Y-%m-%dT%H:%M")
  end

  defp demote(scope, user, role) do
    Repo.get_by!(Membership, organization_id: scope.organization.id, user_id: user.id)
    |> Ecto.Changeset.change(role: role)
    |> Repo.update!()
  end

  test "says so when nothing is scheduled", %{conn: conn, scope: scope} do
    {:ok, _live, html} = live(conn, path(scope))

    assert html =~ "Nothing scheduled"
  end

  test "tells a viewer that incidents still open without a window",
       %{conn: conn, scope: scope, user: user} do
    demote(scope, user, :viewer)

    {:ok, live, _html} = live(conn, path(scope))

    assert has_element?(live, "#maintenance-empty", "Incidents open and notify as usual")
  end

  test "schedules a window and shows it as running", %{conn: conn, scope: scope} do
    {:ok, live, _html} = live(conn, path(scope))

    html =
      live
      |> form("#window-form",
        window: %{reason: "Deploying the new release", starts_at: at(-5), ends_at: at(60)}
      )
      |> render_submit()

    assert html =~ "Maintenance scheduled"
    assert html =~ "Deploying the new release"
    assert html =~ "Running"

    assert [window] = Maintenance.list_current_windows(scope)
    assert window.reason == "Deploying the new release"
    assert window.service_id == nil
  end

  test "a window that has not started yet is scheduled, not running", %{
    conn: conn,
    scope: scope
  } do
    {:ok, live, _html} = live(conn, path(scope))

    html =
      live
      |> form("#window-form", window: %{reason: "Tomorrow", starts_at: at(60), ends_at: at(120)})
      |> render_submit()

    assert html =~ "Scheduled"
    refute html =~ "Running"
  end

  test "scopes a window to one service", %{conn: conn, scope: scope} do
    service = service_fixture(scope, %{name: "Payments API"})

    {:ok, live, _html} = live(conn, path(scope))

    html =
      live
      |> form("#window-form",
        window: %{reason: "Migrating", starts_at: at(-5), ends_at: at(60), service_id: service.id}
      )
      |> render_submit()

    assert html =~ "Payments API"
    assert [window] = Maintenance.list_current_windows(scope)
    assert window.service_id == service.id
  end

  test "reports a window that ends before it starts", %{conn: conn, scope: scope} do
    {:ok, live, _html} = live(conn, path(scope))

    html =
      live
      |> form("#window-form", window: %{reason: "Backwards", starts_at: at(60), ends_at: at(30)})
      |> render_submit()

    assert html =~ "must be after the start"
    assert Maintenance.list_current_windows(scope) == []
  end

  test "cancelling a running window lets incidents open again", %{conn: conn, scope: scope} do
    service = service_fixture(scope)

    {:ok, window} =
      Maintenance.create_window(scope, %{
        reason: "Deploying",
        starts_at: DateTime.add(DateTime.utc_now(:second), -60, :second),
        ends_at: DateTime.add(DateTime.utc_now(:second), 3600, :second)
      })

    assert Incidents.open_incident(service, AlertRule.default(), "down") == {:ok, :suppressed}

    {:ok, live, _html} = live(conn, path(scope))
    html = live |> element(~s(button[phx-value-id="#{window.id}"])) |> render_click()

    assert html =~ "Cancelled: Deploying"
    assert {:ok, incident} = Incidents.open_incident(service, AlertRule.default(), "down")
    assert incident.service_id == service.id
  end

  test "a viewer sees the schedule but cannot change it", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    {:ok, window} =
      Maintenance.create_window(scope, %{
        reason: "Deploying",
        starts_at: DateTime.add(DateTime.utc_now(:second), -60, :second),
        ends_at: DateTime.add(DateTime.utc_now(:second), 3600, :second)
      })

    demote(scope, user, :viewer)

    {:ok, _live, html} = live(conn, path(scope))

    assert html =~ "Deploying"
    refute html =~ "window-form"
    refute html =~ ~s(phx-value-id="#{window.id}")
  end
end
