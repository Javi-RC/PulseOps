defmodule PulseOps.IncidentsPaginationTest do
  use PulseOps.DataCase, async: true

  import PulseOps.IncidentsFixtures
  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Incidents

  setup do
    scope = organization_scope_fixture()
    %{scope: scope, service: service_fixture(scope, %{name: "Payments API"})}
  end

  defp ids(%{entries: entries}), do: Enum.map(entries, & &1.id)

  defp resolved(service, count) do
    for _ <- 1..count, do: resolved_incident_fixture(service)
  end

  describe "page_incidents/2" do
    test "a page holds per_page incidents and says whether another follows", %{
      scope: scope,
      service: service
    } do
      resolved(service, 5)

      first = Incidents.page_incidents(scope, page: 1, per_page: 3)
      assert length(first.entries) == 3
      assert first.has_more?

      last = Incidents.page_incidents(scope, page: 2, per_page: 3)
      assert length(last.entries) == 2
      refute last.has_more?
    end

    test "incidents opened in the same second are neither repeated nor skipped", %{
      scope: scope,
      service: service
    } do
      # All seven land inside one second, so started_at alone gives them no
      # order. Without a tiebreaker, offset pagination over them shows some
      # twice and others never.
      resolved(service, 7)

      seen =
        for page <- 1..3 do
          scope |> Incidents.page_incidents(page: page, per_page: 3) |> ids()
        end
        |> List.flatten()

      everything = scope |> Incidents.list_incidents(limit: 100) |> Enum.map(& &1.id)

      assert length(seen) == 7
      assert Enum.uniq(seen) == seen
      assert Enum.sort(seen) == Enum.sort(everything)
    end

    test "narrows to open or to resolved incidents", %{scope: scope, service: service} do
      resolved(service, 2)
      open = incident_fixture(service_fixture(scope, %{name: "Search"}))

      assert scope |> Incidents.page_incidents(status: :open) |> ids() == [open.id]
      assert scope |> Incidents.page_incidents(status: :resolved) |> ids() |> length() == 2
      assert scope |> Incidents.page_incidents(status: :all) |> ids() |> length() == 3
    end

    test "a page past the end is empty and has nothing after it", %{
      scope: scope,
      service: service
    } do
      resolved(service, 2)

      assert %{entries: [], has_more?: false} =
               Incidents.page_incidents(scope, page: 9, per_page: 25)
    end

    test "a page number below one is the first page", %{scope: scope, service: service} do
      resolved(service, 2)

      assert ids(Incidents.page_incidents(scope, page: 0)) ==
               ids(Incidents.page_incidents(scope, page: 1))

      assert ids(Incidents.page_incidents(scope, page: -4)) ==
               ids(Incidents.page_incidents(scope, page: 1))
    end

    test "never includes another organization's incidents", %{scope: scope} do
      other = organization_scope_fixture()
      incident_fixture(service_fixture(other))

      assert %{entries: [], has_more?: false} = Incidents.page_incidents(scope)
    end
  end
end
