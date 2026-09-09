defmodule PulseOps.StatusPageTest do
  use PulseOps.DataCase, async: true

  import PulseOps.IncidentsFixtures
  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Monitoring
  alias PulseOps.Organizations
  alias PulseOps.StatusPage

  defp published(scope, attrs \\ %{}) do
    {:ok, organization} =
      Organizations.update_organization(
        scope,
        scope.organization,
        Enum.into(attrs, %{status_page_enabled: true})
      )

    %{scope | organization: organization}
  end

  describe "get_organization/1" do
    test "returns the organization once its page is published" do
      scope = published(organization_scope_fixture())

      assert %{slug: slug} = StatusPage.get_organization(scope.organization.slug)
      assert slug == scope.organization.slug
    end

    test "an organization that has not published is indistinguishable from one that does not exist" do
      scope = organization_scope_fixture()

      # Both nil: the page cannot be used to find out who has an account here.
      assert StatusPage.get_organization(scope.organization.slug) == nil
      assert StatusPage.get_organization("no-such-organization") == nil
    end

    test "tolerates a slug that is not a string" do
      assert StatusPage.get_organization(nil) == nil
    end
  end

  describe "what overview/1 refuses to publish" do
    setup do
      scope = published(organization_scope_fixture())
      service = service_fixture(scope, %{name: "Payments API"})
      %{scope: scope, service: service, organization: scope.organization}
    end

    test "never returns a service URL", %{organization: organization, service: service} do
      %{services: [published_service]} = StatusPage.overview(organization)

      # The URL is an internal hostname often enough that an SSRF guard exists
      # for it. It is not merely unrendered — it is never fetched, so no
      # template change can start leaking it.
      refute Map.has_key?(published_service, :url)
      refute published_service |> Map.values() |> Enum.member?(service.url)
    end

    test "never returns check intervals or timeouts", %{organization: organization} do
      %{services: [service]} = StatusPage.overview(organization)

      refute Map.has_key?(service, :check_interval_ms)
      refute Map.has_key?(service, :timeout_ms)
    end

    test "never returns an incident's cause, resolver or timeline", %{
      organization: organization,
      service: service
    } do
      incident_fixture(service, "database connection pool exhausted on db-primary-3")

      %{active_incidents: [incident]} = StatusPage.overview(organization)

      refute Map.has_key?(incident, :cause)
      refute Map.has_key?(incident, :resolved_by_id)
      refute Map.has_key?(incident, :events)
    end
  end

  describe "overview/1 selection" do
    setup do
      scope = published(organization_scope_fixture())
      %{scope: scope, organization: scope.organization}
    end

    test "leaves out a service marked not public", %{scope: scope, organization: organization} do
      service_fixture(scope, %{name: "Public API"})
      service_fixture(scope, %{name: "Internal Admin", public: false})

      %{services: services} = StatusPage.overview(organization)

      assert Enum.map(services, & &1.name) == ["Public API"]
    end

    test "leaves out a disabled service", %{scope: scope, organization: organization} do
      service_fixture(scope, %{name: "Watched"})
      service_fixture(scope, %{name: "Paused", enabled: false})

      %{services: services} = StatusPage.overview(organization)

      assert Enum.map(services, & &1.name) == ["Watched"]
    end

    test "leaves out another organization's services and incidents", %{
      scope: scope,
      organization: organization
    } do
      service_fixture(scope, %{name: "Mine"})
      other = organization_scope_fixture()
      their_service = service_fixture(other, %{name: "Theirs"})
      incident_fixture(their_service)

      overview = StatusPage.overview(organization)

      assert Enum.map(overview.services, & &1.name) == ["Mine"]
      assert overview.active_incidents == []
      assert overview.past_incidents == []
    end

    test "an incident on a non-public service is not published either", %{
      scope: scope,
      organization: organization
    } do
      hidden = service_fixture(scope, %{name: "Internal Admin", public: false})
      incident_fixture(hidden)

      overview = StatusPage.overview(organization)

      assert overview.services == []
      assert overview.active_incidents == []
    end

    test "separates open incidents from resolved ones", %{
      scope: scope,
      organization: organization
    } do
      broken = service_fixture(scope, %{name: "Broken"})
      recovered = service_fixture(scope, %{name: "Recovered"})

      incident_fixture(broken)
      resolved_incident_fixture(recovered)

      overview = StatusPage.overview(organization)

      assert [%{service_id: id}] = overview.active_incidents
      assert id == broken.id
      assert [%{service_id: past_id}] = overview.past_incidents
      assert past_id == recovered.id
    end
  end

  describe "overall status" do
    setup do
      scope = published(organization_scope_fixture())
      %{scope: scope, organization: scope.organization}
    end

    test "is unknown with nothing published", %{organization: organization} do
      assert StatusPage.overview(organization).overall == :unknown
    end

    test "anything down makes the whole page down", %{
      scope: scope,
      organization: organization
    } do
      service_fixture(scope, %{name: "Alpha"}) |> Monitoring.update_service_status(:healthy)
      service_fixture(scope, %{name: "Bravo"}) |> Monitoring.update_service_status(:down)

      assert StatusPage.overview(organization).overall == :down
    end

    test "degraded outranks healthy", %{scope: scope, organization: organization} do
      service_fixture(scope, %{name: "Alpha"}) |> Monitoring.update_service_status(:healthy)
      service_fixture(scope, %{name: "Bravo"}) |> Monitoring.update_service_status(:degraded)

      assert StatusPage.overview(organization).overall == :degraded
    end
  end
end
