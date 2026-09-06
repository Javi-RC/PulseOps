defmodule PulseOpsWeb.ServiceLiveTest do
  use PulseOpsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PulseOps.IncidentsFixtures
  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.HealthCheck.Result
  alias PulseOps.Organizations.Membership
  alias PulseOps.Repo

  @create_attrs %{
    name: "Payments API",
    description: "Takes the money",
    url: "https://payments.example.com/health",
    environment: :production,
    check_interval_seconds: 30,
    timeout_seconds: 5,
    enabled: true
  }
  @update_attrs %{
    name: "Payments API v2",
    description: "Still takes the money",
    url: "https://payments.example.com/healthz",
    environment: :staging,
    check_interval_seconds: 60,
    timeout_seconds: 10,
    enabled: false
  }
  # environment is a select with no blank option, so the form cannot submit it
  # empty; leaving it out keeps these attrs to what a browser could actually send.
  @invalid_attrs %{name: nil, url: nil, check_interval_seconds: nil, timeout_seconds: nil}

  setup :register_and_log_in_user_with_org

  defp create_service(%{scope: scope}) do
    %{service: service_fixture(scope, %{name: "Payments API"})}
  end

  defp services_path(scope), do: ~p"/orgs/#{scope.organization.slug}/services"

  describe "Index" do
    setup [:create_service]

    test "lists services with their status", %{conn: conn, service: service, scope: scope} do
      Monitoring.update_service_status(service, :healthy)

      {:ok, _live, html} = live(conn, services_path(scope))

      assert html =~ "Services"
      assert html =~ service.name
      assert html =~ "Healthy"
    end

    test "shows the interval in a human unit, not milliseconds", %{conn: conn, scope: scope} do
      service_fixture(scope, %{name: "Every half minute", check_interval_ms: 30_000})

      {:ok, _live, html} = live(conn, services_path(scope))

      assert html =~ "every 30 s"
      refute html =~ "30000"
    end

    test "puts failing services above healthy ones", %{conn: conn, scope: scope} do
      healthy = service_fixture(scope, %{name: "AAA Healthy"})
      broken = service_fixture(scope, %{name: "ZZZ Broken"})
      Monitoring.update_service_status(healthy, :healthy)
      Monitoring.update_service_status(broken, :down)

      {:ok, _live, html} = live(conn, services_path(scope))

      assert html =~ ~r/ZZZ Broken.*AAA Healthy/s
    end

    test "filters by status", %{conn: conn, scope: scope, service: service} do
      Monitoring.update_service_status(service, :healthy)
      broken = service_fixture(scope, %{name: "Broken One"})
      Monitoring.update_service_status(broken, :down)

      {:ok, live, _html} = live(conn, services_path(scope))

      html =
        live
        |> element("button[phx-value-key=status][phx-value-value=down]")
        |> render_click()

      assert html =~ "Broken One"
      refute html =~ "Payments API"
    end

    test "filters by environment", %{conn: conn, scope: scope} do
      service_fixture(scope, %{name: "Staging Thing", environment: :staging})

      {:ok, live, _html} = live(conn, services_path(scope))

      html =
        live
        |> element("button[phx-value-key=environment][phx-value-value=staging]")
        |> render_click()

      assert html =~ "Staging Thing"
      refute html =~ "Payments API"
    end

    test "says so when the filters match nothing", %{conn: conn, scope: scope} do
      {:ok, live, _html} = live(conn, services_path(scope))

      html =
        live
        |> element("button[phx-value-key=status][phx-value-value=down]")
        |> render_click()

      assert html =~ "Nothing matches these filters"
    end

    test "invites the first service when there are none", %{
      conn: conn,
      scope: scope,
      service: service
    } do
      {:ok, _service} = Monitoring.delete_service(scope, service)

      {:ok, _live, html} = live(conn, services_path(scope))

      assert html =~ "No services yet"
    end

    test "deletes a service", %{conn: conn, service: service, scope: scope} do
      {:ok, live, _html} = live(conn, services_path(scope))

      html = live |> element(~s{button[phx-value-id="#{service.id}"]}) |> render_click()

      # The flash names the deleted service, so check the row is gone rather
      # than that the name is absent from the page.
      refute html =~ ~s(id="service-#{service.id}")
      assert Monitoring.list_services(scope) == []
    end

    test "a viewer sees no write actions", %{conn: conn, scope: scope, user: user} do
      demote_to_viewer(scope, user)

      {:ok, _live, html} = live(conn, services_path(scope))

      refute html =~ "New service"
      refute html =~ "phx-click=\"delete\""
    end
  end

  describe "Form" do
    test "creates a service, taking the interval in seconds", %{conn: conn, scope: scope} do
      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/services/new")

      assert live
             |> form("#service-form", service: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, _live, html} =
               live
               |> form("#service-form", service: @create_attrs)
               |> render_submit()
               |> follow_redirect(conn, services_path(scope))

      assert html =~ "Service created"
      assert html =~ "Payments API"

      service = Monitoring.list_services(scope) |> List.first()
      # Seconds in, milliseconds stored.
      assert service.check_interval_ms == 30_000
      assert service.timeout_ms == 5_000
    end

    test "reports a timeout that does not fit the interval", %{conn: conn, scope: scope} do
      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/services/new")

      html =
        live
        |> form("#service-form",
          service: %{@create_attrs | check_interval_seconds: 10, timeout_seconds: 10}
        )
        |> render_change()

      assert html =~ "must be shorter than the check interval"
    end

    test "edits a service", %{conn: conn, scope: scope} do
      service = service_fixture(scope)

      {:ok, live, _html} =
        live(conn, ~p"/orgs/#{scope.organization.slug}/services/#{service}/edit")

      assert {:ok, _live, html} =
               live
               |> form("#service-form", service: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, services_path(scope))

      assert html =~ "Service updated"
      assert html =~ "Payments API v2"
    end
  end

  describe "Show" do
    setup [:create_service]

    test "displays the service", %{conn: conn, service: service, scope: scope} do
      {:ok, _live, html} =
        live(conn, ~p"/orgs/#{scope.organization.slug}/services/#{service}")

      assert html =~ service.name
      assert html =~ service.url
    end

    test "renders the chart and the metrics once there are checks", %{
      conn: conn,
      service: service,
      scope: scope
    } do
      # The page previously only ever got exercised with an empty history, which
      # is why a crash in the plot geometry went unnoticed.
      for ms <- [120, 340, 95, 780] do
        Monitoring.record_check(service, :healthy, %Result{http_status: 200, response_time_ms: ms})
      end

      {:ok, _live, html} =
        live(conn, ~p"/orgs/#{scope.organization.slug}/services/#{service}")

      assert html =~ "<polyline"
      assert html =~ "780 ms"
      assert html =~ "Uptime (24h)"
      assert html =~ "100.00%"
      assert html =~ "p95"
    end

    test "shows an open incident with a link to it", %{conn: conn, service: service, scope: scope} do
      incident = incident_fixture(service)

      {:ok, _live, html} =
        live(conn, ~p"/orgs/#{scope.organization.slug}/services/#{service}")

      assert html =~ "Open incident since"
      assert html =~ "/incidents/#{incident.id}"
    end
  end

  describe "tenancy" do
    setup [:create_service]

    test "redirects a user who is not a member of the organization", %{conn: conn} do
      outsider_scope = organization_scope_fixture()

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => message}}}} =
               live(conn, services_path(outsider_scope))

      assert message == "Organization not found."
    end

    test "reports a missing organization the same way as a forbidden one", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: %{"error" => message}}}} =
               live(conn, ~p"/orgs/no-such-org/services")

      assert message == "Organization not found."
    end

    test "does not expose another organization's service by id", %{conn: conn, scope: scope} do
      other_scope = organization_scope_fixture()
      other_service = service_fixture(other_scope)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/orgs/#{scope.organization.slug}/services/#{other_service}")
      end
    end
  end

  defp demote_to_viewer(scope, user) do
    Repo.get_by!(Membership, organization_id: scope.organization.id, user_id: user.id)
    |> Ecto.Changeset.change(role: :viewer)
    |> Repo.update!()
  end
end
