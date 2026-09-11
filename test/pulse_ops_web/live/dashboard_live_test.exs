defmodule PulseOpsWeb.DashboardLiveTest do
  use PulseOpsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PulseOps.IncidentsFixtures
  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Incidents
  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.AlertRule
  alias PulseOps.Organizations.Membership
  alias PulseOps.Repo

  setup :register_and_log_in_user_with_org

  defp demote(scope, user, role) do
    Repo.get_by!(Membership, organization_id: scope.organization.id, user_id: user.id)
    |> Ecto.Changeset.change(role: role)
    |> Repo.update!()
  end

  describe "rendering" do
    test "invites the user to add a service when there are none", %{conn: conn, scope: scope} do
      {:ok, live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}")

      assert html =~ "Nothing is being watched yet"
      assert has_element?(live, "#dashboard-services-empty a", "Add the first service")
      # The empty state carries the action; a second button above it would repeat it.
      refute has_element?(live, "#new-service")
    end

    test "tells a viewer with no services who adds them",
         %{conn: conn, scope: scope, user: user} do
      demote(scope, user, :viewer)

      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}")

      assert has_element?(live, "#dashboard-services-empty", "Once an owner or admin")
      refute has_element?(live, "#dashboard-services-empty a")
    end

    test "offers a new service from the dashboard once some exist", %{conn: conn, scope: scope} do
      service_fixture(scope)

      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}")

      assert has_element?(
               live,
               ~s(#new-service[href="/orgs/#{scope.organization.slug}/services/new"])
             )
    end

    test "does not offer a new service to a viewer", %{conn: conn, scope: scope, user: user} do
      service_fixture(scope)
      demote(scope, user, :viewer)

      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}")

      refute has_element?(live, "#new-service")
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
      # The default alert rule assigns :medium; no per-service rule exists.
      assert html =~ "Medium"
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

      {:ok, _incident} =
        Incidents.open_incident(service, AlertRule.default(), "connection refused")

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

      {:ok, _incident} = Incidents.open_incident(other_service, AlertRule.default())

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

  describe "reload debounce" do
    setup do
      # The suite reloads on the next message so tests can render straight after
      # a broadcast; this is the one place a real window is exercised.
      Application.put_env(:pulse_ops, :dashboard_debounce_ms, 50)
      on_exit(fn -> Application.put_env(:pulse_ops, :dashboard_debounce_ms, 0) end)
      :ok
    end

    test "a burst of broadcasts costs one reload, not one per message", %{
      conn: conn,
      scope: scope
    } do
      service = service_fixture(scope, %{name: "Payments API"})
      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}")

      one =
        count_queries(live.pid, fn ->
          broadcast_changes(scope, service, 1)
          settle(live)
        end)

      many =
        count_queries(live.pid, fn ->
          broadcast_changes(scope, service, 10)
          settle(live)
        end)

      assert one > 0, "a reload has to query something for this comparison to mean anything"

      assert many == one,
             "ten status changes must not cost ten reloads of a four-query summary"
    end

    test "the page still catches up with the final state", %{conn: conn, scope: scope} do
      service = service_fixture(scope, %{name: "Payments API"})
      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}")

      Monitoring.update_service_status(service, :healthy)
      Monitoring.update_service_status(service, :down)
      settle(live)

      # Coalescing drops intermediate reloads, never the last one: the summary is
      # re-read from the database rather than patched from a message payload.
      assert render(live) =~ "Down"
    end
  end

  # Counts the repo queries issued by the LiveView itself. The handler runs in
  # whichever process ran the query, so filtering on the pid keeps a concurrent
  # test's queries out of the count.
  defp count_queries(live_pid, fun) do
    test_pid = self()
    ref = make_ref()
    handler_id = {:dashboard_query_counter, ref}

    :telemetry.attach(
      handler_id,
      [:pulse_ops, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == live_pid, do: send(test_pid, {ref, :query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain(ref, 0)
  end

  defp drain(ref, count) do
    receive do
      {^ref, :query} -> drain(ref, count + 1)
    after
      0 -> count
    end
  end

  defp broadcast_changes(scope, service, times) do
    for _ <- 1..times do
      Phoenix.PubSub.broadcast(
        PulseOps.PubSub,
        "organization:#{scope.organization.id}:services",
        {:updated, service}
      )
    end
  end

  # Waits out the debounce window and then synchronises with the LiveView, so
  # the deferred reload is guaranteed to have been handled. Sleeping is what
  # waiting on a wall-clock timer looks like; there is no message to await.
  defp settle(live) do
    Process.sleep(150)
    render(live)
  end
end
