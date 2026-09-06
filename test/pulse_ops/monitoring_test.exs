defmodule PulseOps.MonitoringTest do
  use PulseOps.DataCase, async: true

  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.HealthCheck.Result
  alias PulseOps.Monitoring.Service

  @invalid_attrs %{
    name: nil,
    url: nil,
    environment: nil,
    check_interval_ms: nil,
    timeout_ms: nil
  }

  describe "list_services/1" do
    test "returns only the services of the scoped organization" do
      scope = organization_scope_fixture()
      other_scope = organization_scope_fixture()

      service = service_fixture(scope)
      other_service = service_fixture(other_scope)

      assert Monitoring.list_services(scope) == [service]
      assert Monitoring.list_services(other_scope) == [other_service]
    end
  end

  describe "get_service!/2" do
    test "returns the service with the given id" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert Monitoring.get_service!(scope, service.id) == service
    end

    test "hides a service belonging to another organization" do
      scope = organization_scope_fixture()
      other_scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert_raise Ecto.NoResultsError, fn ->
        Monitoring.get_service!(other_scope, service.id)
      end
    end
  end

  describe "create_service/2" do
    test "creates a service owned by the scoped organization" do
      scope = organization_scope_fixture()

      attrs =
        valid_service_attributes(%{
          name: "Payments API",
          environment: :staging,
          url: "https://payments.example.com/health",
          check_interval_ms: 30_000,
          timeout_ms: 5_000
        })

      assert {:ok, %Service{} = service} = Monitoring.create_service(scope, attrs)
      assert service.name == "Payments API"
      assert service.environment == :staging
      assert service.url == "https://payments.example.com/health"
      assert service.check_interval_ms == 30_000
      assert service.timeout_ms == 5_000
      assert service.organization_id == scope.organization.id
    end

    test "starts out unknown and unchecked" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      # Status belongs to the monitor, not to the form.
      assert service.status == :unknown
      assert service.last_checked_at == nil
    end

    test "ignores a status supplied through the form" do
      scope = organization_scope_fixture()
      service = service_fixture(scope, %{status: :healthy})

      assert service.status == :unknown
    end

    test "returns an error changeset for invalid data" do
      scope = organization_scope_fixture()

      assert {:error, %Ecto.Changeset{}} = Monitoring.create_service(scope, @invalid_attrs)
    end

    test "rejects a url that is not http or https" do
      scope = organization_scope_fixture()

      for url <- ["not a url", "ftp://example.com", "example.com", "https://"] do
        assert {:error, changeset} =
                 Monitoring.create_service(scope, valid_service_attributes(%{url: url}))

        assert "must be a valid http or https URL" in errors_on(changeset).url
      end
    end

    test "rejects a timeout that does not fit inside the interval" do
      scope = organization_scope_fixture()

      assert {:error, changeset} =
               Monitoring.create_service(
                 scope,
                 valid_service_attributes(%{check_interval_ms: 10_000, timeout_ms: 10_000})
               )

      assert "must be shorter than the check interval" in errors_on(changeset).timeout_ms
    end

    test "rejects intervals outside the supported range" do
      scope = organization_scope_fixture()

      assert {:error, changeset} =
               Monitoring.create_service(
                 scope,
                 valid_service_attributes(%{check_interval_ms: 500})
               )

      assert errors_on(changeset)[:check_interval_ms]
    end

    test "rejects a duplicate name within the same organization" do
      scope = organization_scope_fixture()
      service_fixture(scope, %{name: "Payments API"})

      assert {:error, changeset} =
               Monitoring.create_service(scope, valid_service_attributes(%{name: "Payments API"}))

      assert "a service with this name already exists" in errors_on(changeset).name
    end

    test "allows the same name in a different organization" do
      scope = organization_scope_fixture()
      other_scope = organization_scope_fixture()

      service_fixture(scope, %{name: "Payments API"})

      assert {:ok, %Service{}} =
               Monitoring.create_service(
                 other_scope,
                 valid_service_attributes(%{name: "Payments API"})
               )
    end
  end

  describe "update_service/3" do
    test "updates the service" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert {:ok, %Service{} = service} =
               Monitoring.update_service(scope, service, %{
                 name: "Renamed",
                 enabled: false,
                 check_interval_ms: 120_000
               })

      assert service.name == "Renamed"
      assert service.enabled == false
      assert service.check_interval_ms == 120_000
    end

    test "returns an error changeset for invalid data and leaves the record alone" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert {:error, %Ecto.Changeset{}} =
               Monitoring.update_service(scope, service, @invalid_attrs)

      assert service == Monitoring.get_service!(scope, service.id)
    end

    test "raises when the scope does not own the service" do
      scope = organization_scope_fixture()
      other_scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert_raise MatchError, fn ->
        Monitoring.update_service(other_scope, service, %{})
      end
    end
  end

  describe "delete_service/2" do
    test "deletes the service" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert {:ok, %Service{}} = Monitoring.delete_service(scope, service)
      assert_raise Ecto.NoResultsError, fn -> Monitoring.get_service!(scope, service.id) end
    end

    test "raises when the scope does not own the service" do
      scope = organization_scope_fixture()
      other_scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert_raise MatchError, fn -> Monitoring.delete_service(other_scope, service) end
    end
  end

  describe "authorization" do
    test "a viewer may not create a service" do
      scope = organization_scope_fixture(:viewer)

      assert Monitoring.create_service(scope, valid_service_attributes()) ==
               {:error, :unauthorized}
    end

    test "a viewer may not update or delete a service" do
      owner_scope = organization_scope_fixture()
      service = service_fixture(owner_scope)

      viewer_scope = %{owner_scope | role: :viewer}

      assert Monitoring.update_service(viewer_scope, service, %{name: "Nope"}) ==
               {:error, :unauthorized}

      assert Monitoring.delete_service(viewer_scope, service) == {:error, :unauthorized}
      assert Monitoring.get_service!(owner_scope, service.id).name == service.name
    end

    test "a member may not manage services either" do
      scope = organization_scope_fixture(:member)

      assert Monitoring.create_service(scope, valid_service_attributes()) ==
               {:error, :unauthorized}
    end

    test "an admin may manage services" do
      scope = organization_scope_fixture(:admin)

      assert {:ok, %Service{}} = Monitoring.create_service(scope, valid_service_attributes())
    end
  end

  describe "subscribe_services/1" do
    test "delivers create, update and delete messages for the organization" do
      scope = organization_scope_fixture()
      Monitoring.subscribe_services(scope)

      service = service_fixture(scope)
      assert_receive {:created, %Service{id: id}} when id == service.id

      {:ok, updated} = Monitoring.update_service(scope, service, %{name: "Renamed"})
      assert_receive {:updated, %Service{name: "Renamed"}}

      {:ok, _deleted} = Monitoring.delete_service(scope, updated)
      assert_receive {:deleted, %Service{}}
    end

    test "does not deliver messages from another organization" do
      scope = organization_scope_fixture()
      other_scope = organization_scope_fixture()

      Monitoring.subscribe_services(scope)
      service_fixture(other_scope)

      refute_receive {:created, _service}
    end
  end

  describe "service_metrics/3" do
    test "reports nothing for a service with no checks" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert %{total: 0, uptime_percent: nil, p50: nil, p95: nil, p99: nil} =
               Monitoring.service_metrics(scope, service)
    end

    test "computes uptime from the recorded checks" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      record(service, :healthy, 100)
      record(service, :healthy, 100)
      record(service, :degraded, 100)
      record(service, :down, nil)

      metrics = Monitoring.service_metrics(scope, service)

      assert metrics.total == 4
      # Degraded still counts as up: the service answered.
      assert metrics.up == 3
      assert metrics.down == 1
      assert_in_delta metrics.uptime_percent, 75.0, 0.001
    end

    test "computes percentiles in the database" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      for ms <- 1..100, do: record(service, :healthy, ms)

      metrics = Monitoring.service_metrics(scope, service)

      assert_in_delta metrics.p50, 50, 2
      assert_in_delta metrics.p95, 95, 2
      assert_in_delta metrics.p99, 99, 2
    end

    test "ignores checks outside the window" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      record(service, :healthy, 100)

      assert Monitoring.service_metrics(scope, service, since: minutes_from_now(5)).total == 0
    end

    test "raises for a service in another organization" do
      scope = organization_scope_fixture()
      other_scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert_raise MatchError, fn -> Monitoring.service_metrics(other_scope, service) end
    end
  end

  describe "uptime_by_service/2" do
    test "returns one entry per service, scoped to the organization" do
      scope = organization_scope_fixture()
      good = service_fixture(scope, %{name: "Good"})
      bad = service_fixture(scope, %{name: "Bad"})

      other_scope = organization_scope_fixture()
      theirs = service_fixture(other_scope)
      record(theirs, :healthy, 10)

      record(good, :healthy, 10)
      record(good, :healthy, 10)
      record(bad, :healthy, 10)
      record(bad, :down, nil)

      uptime = Monitoring.uptime_by_service(scope)

      assert_in_delta uptime[good.id], 100.0, 0.001
      assert_in_delta uptime[bad.id], 50.0, 0.001
      refute Map.has_key?(uptime, theirs.id)
    end
  end

  describe "list_checks_for_chart/3" do
    test "returns checks oldest first, so a plot reads left to right" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      record(service, :healthy, 10)
      record(service, :healthy, 20)
      record(service, :healthy, 30)

      assert [10, 20, 30] =
               scope
               |> Monitoring.list_checks_for_chart(service)
               |> Enum.map(& &1.response_time_ms)
    end
  end

  defp record(service, status, response_time_ms) do
    Monitoring.record_check(service, status, %Result{
      http_status: if(status == :down, do: nil, else: 200),
      response_time_ms: response_time_ms,
      error: if(status == :down, do: "connection refused")
    })
  end

  defp minutes_from_now(minutes), do: DateTime.add(DateTime.utc_now(), minutes * 60, :second)

  describe "change_service/3" do
    test "returns a changeset" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert %Ecto.Changeset{} = Monitoring.change_service(scope, service)
    end
  end
end
