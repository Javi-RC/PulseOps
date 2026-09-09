defmodule PulseOpsWeb.StatusPageLiveTest do
  use PulseOpsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PulseOps.IncidentsFixtures
  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Incidents
  alias PulseOps.Monitoring
  alias PulseOps.Organizations

  defp publish(scope, attrs \\ %{}) do
    {:ok, organization} =
      Organizations.update_organization(
        scope,
        scope.organization,
        Enum.into(attrs, %{status_page_enabled: true})
      )

    %{scope | organization: organization}
  end

  describe "who can see it" do
    test "a stranger reads a published page with no account", %{conn: conn} do
      scope = publish(organization_scope_fixture(), %{status_page_headline: "We watch things"})
      service_fixture(scope, %{name: "Payments API"})

      # No login of any kind on this conn.
      {:ok, _live, html} = live(conn, ~p"/status/#{scope.organization.slug}")

      assert html =~ scope.organization.name
      assert html =~ "We watch things"
      assert html =~ "Payments API"
    end

    test "an unpublished organization 404s exactly like one that never existed", %{conn: conn} do
      scope = organization_scope_fixture()

      assert_raise PulseOpsWeb.StatusPageLive.NotFound, fn ->
        live(conn, ~p"/status/#{scope.organization.slug}")
      end

      assert_raise PulseOpsWeb.StatusPageLive.NotFound, fn ->
        live(conn, ~p"/status/never-existed")
      end
    end

    test "turning the page off takes it down again", %{conn: conn} do
      scope = publish(organization_scope_fixture())
      assert {:ok, _live, _html} = live(conn, ~p"/status/#{scope.organization.slug}")

      _off = publish(scope, %{status_page_enabled: false})

      assert_raise PulseOpsWeb.StatusPageLive.NotFound, fn ->
        live(conn, ~p"/status/#{scope.organization.slug}")
      end
    end
  end

  describe "what reaches the browser" do
    test "the service URL never appears in the rendered page", %{conn: conn} do
      scope = publish(organization_scope_fixture())

      service =
        service_fixture(scope, %{
          name: "Payments API",
          url: "https://internal-payments.corp.example/health"
        })

      {:ok, _live, html} = live(conn, ~p"/status/#{scope.organization.slug}")

      assert html =~ "Payments API"
      refute html =~ service.url
      refute html =~ "internal-payments"
    end

    test "an incident's cause never appears", %{conn: conn} do
      scope = publish(organization_scope_fixture())
      service = service_fixture(scope, %{name: "Payments API"})
      incident = incident_fixture(service)

      {:ok, _updated} =
        Incidents.update_incident(scope, incident, %{
          status: :identified,
          cause: "credentials for db-primary-3 had expired"
        })

      {:ok, _live, html} = live(conn, ~p"/status/#{scope.organization.slug}")

      assert html =~ "Payments API is unavailable"
      refute html =~ "db-primary-3"
      refute html =~ "credentials"
    end

    test "a service marked not public is absent", %{conn: conn} do
      scope = publish(organization_scope_fixture())
      service_fixture(scope, %{name: "Public API"})
      service_fixture(scope, %{name: "Internal Admin", public: false})

      {:ok, _live, html} = live(conn, ~p"/status/#{scope.organization.slug}")

      assert html =~ "Public API"
      refute html =~ "Internal Admin"
    end
  end

  describe "what it says" do
    setup %{conn: conn} do
      scope = publish(organization_scope_fixture())
      %{conn: conn, scope: scope}
    end

    test "says all is well when everything is healthy", %{conn: conn, scope: scope} do
      service_fixture(scope, %{name: "Payments API"})
      |> Monitoring.update_service_status(:healthy)

      {:ok, _live, html} = live(conn, ~p"/status/#{scope.organization.slug}")

      assert html =~ "All systems operational"
    end

    test "announces an outage and the open incident", %{conn: conn, scope: scope} do
      service = service_fixture(scope, %{name: "Payments API"})
      Monitoring.update_service_status(service, :down)
      incident_fixture(service)

      {:ok, _live, html} = live(conn, ~p"/status/#{scope.organization.slug}")

      assert html =~ "We are having an outage"
      assert html =~ "Open incidents"
      assert html =~ "Payments API is unavailable"
    end

    test "lists resolved incidents as history, not as open", %{conn: conn, scope: scope} do
      service = service_fixture(scope, %{name: "Payments API"})
      resolved_incident_fixture(service)

      {:ok, _live, html} = live(conn, ~p"/status/#{scope.organization.slug}")

      assert html =~ "Recent history"
      refute html =~ "Open incidents"
    end

    test "invites nothing when no service is published", %{conn: conn, scope: scope} do
      {:ok, _live, html} = live(conn, ~p"/status/#{scope.organization.slug}")

      assert html =~ "Nothing is published here yet"
    end
  end

  describe "live updates" do
    test "an incident opening reaches an already-open page", %{conn: conn} do
      scope = publish(organization_scope_fixture())
      service = service_fixture(scope, %{name: "Payments API"})

      {:ok, live, html} = live(conn, ~p"/status/#{scope.organization.slug}")
      refute html =~ "Open incidents"

      # Exactly what a monitor does when a service goes down.
      Monitoring.update_service_status(service, :down)
      incident_fixture(service)

      html = render(live)
      assert html =~ "Open incidents"
      assert html =~ "Payments API is unavailable"
    end

    test "a recovery reaches it too", %{conn: conn} do
      scope = publish(organization_scope_fixture())
      service = service_fixture(scope, %{name: "Payments API"})
      Monitoring.update_service_status(service, :down)
      incident_fixture(service)

      {:ok, live, html} = live(conn, ~p"/status/#{scope.organization.slug}")
      assert html =~ "Open incidents"

      Monitoring.update_service_status(service, :healthy)
      {:ok, _resolved} = Incidents.resolve_open_incident(service)

      html = render(live)
      refute html =~ "Open incidents"
      assert html =~ "All systems operational"
    end

    test "another organization's activity does not reach it", %{conn: conn} do
      scope = publish(organization_scope_fixture())
      service_fixture(scope, %{name: "Mine"})

      other = organization_scope_fixture()
      their_service = service_fixture(other, %{name: "Theirs"})

      {:ok, live, _html} = live(conn, ~p"/status/#{scope.organization.slug}")

      Monitoring.update_service_status(their_service, :down)
      incident_fixture(their_service)

      html = render(live)
      refute html =~ "Theirs"
      refute html =~ "Open incidents"
    end
  end
end
