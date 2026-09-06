defmodule PulseOps.MonitoringTest do
  use PulseOps.DataCase, async: true

  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Monitoring
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

  describe "change_service/3" do
    test "returns a changeset" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert %Ecto.Changeset{} = Monitoring.change_service(scope, service)
    end
  end
end
