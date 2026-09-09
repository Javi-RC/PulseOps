defmodule PulseOps.MaintenanceTest do
  use PulseOps.DataCase, async: true

  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Incidents
  alias PulseOps.Maintenance
  alias PulseOps.Maintenance.Window
  alias PulseOps.Monitoring.AlertRule

  setup do
    scope = organization_scope_fixture()
    %{scope: scope, service: service_fixture(scope, %{name: "Payments API"})}
  end

  defp minutes(n), do: DateTime.add(DateTime.utc_now(:second), n * 60, :second)

  defp schedule(scope, attrs \\ %{}) do
    {:ok, window} =
      Maintenance.create_window(
        scope,
        Enum.into(attrs, %{
          reason: "Deploying the new release",
          starts_at: minutes(-5),
          ends_at: minutes(30)
        })
      )

    window
  end

  describe "create_window/2" do
    test "schedules one for the whole organization", %{scope: scope} do
      window = schedule(scope)

      assert window.service_id == nil
      assert window.organization_id == scope.organization.id
      assert window.created_by_id == scope.user.id
    end

    test "schedules one for a single service", %{scope: scope, service: service} do
      window = schedule(scope, %{service_id: service.id})

      assert window.service_id == service.id
    end

    test "refuses a window that ends before it starts", %{scope: scope} do
      assert {:error, changeset} =
               Maintenance.create_window(scope, %{
                 reason: "Backwards",
                 starts_at: minutes(60),
                 ends_at: minutes(30)
               })

      assert "must be after the start" in errors_on(changeset).ends_at
    end

    test "refuses a window longer than a month", %{scope: scope} do
      # Beyond this it is not maintenance, it is a service nobody wants to hear
      # about — and the way to say that is to disable the service.
      assert {:error, changeset} =
               Maintenance.create_window(scope, %{
                 reason: "Forever",
                 starts_at: minutes(0),
                 ends_at: DateTime.add(DateTime.utc_now(:second), Window.max_days() + 1, :day)
               })

      assert errors_on(changeset).ends_at != []
    end

    test "refuses a window aimed at another organization's service", %{scope: scope} do
      other = organization_scope_fixture()
      theirs = service_fixture(other)

      # Worse than the denial of service an unvalidated alert rule caused: this
      # would silence somebody else's alerts.
      assert {:error, changeset} =
               Maintenance.create_window(scope, %{
                 reason: "Not mine",
                 starts_at: minutes(0),
                 ends_at: minutes(30),
                 service_id: theirs.id
               })

      assert "must belong to the organization" in errors_on(changeset).service_id
    end

    test "a viewer cannot schedule one", %{scope: scope} do
      assert Maintenance.create_window(%{scope | role: :viewer}, %{
               reason: "Nope",
               starts_at: minutes(0),
               ends_at: minutes(30)
             }) == {:error, :unauthorized}
    end
  end

  describe "under_maintenance?/2" do
    test "an organization-wide window covers every service", %{scope: scope, service: service} do
      other_service = service_fixture(scope, %{name: "Search"})
      schedule(scope)

      assert Maintenance.under_maintenance?(service)
      assert Maintenance.under_maintenance?(other_service)
    end

    test "a per-service window covers only that one", %{scope: scope, service: service} do
      other_service = service_fixture(scope, %{name: "Search"})
      schedule(scope, %{service_id: service.id})

      assert Maintenance.under_maintenance?(service)
      refute Maintenance.under_maintenance?(other_service)
    end

    test "is false before it starts and after it ends", %{scope: scope, service: service} do
      schedule(scope, %{starts_at: minutes(10), ends_at: minutes(40)})

      refute Maintenance.under_maintenance?(service)
      assert Maintenance.under_maintenance?(service, minutes(20))
      refute Maintenance.under_maintenance?(service, minutes(50))
    end

    test "another organization's window covers nothing here", %{service: service} do
      other = organization_scope_fixture()
      schedule(other)

      refute Maintenance.under_maintenance?(service)
    end

    test "cancelling one ends the silence immediately", %{scope: scope, service: service} do
      window = schedule(scope)
      assert Maintenance.under_maintenance?(service)

      {:ok, _deleted} = Maintenance.delete_window(scope, window.id)

      refute Maintenance.under_maintenance?(service)
    end
  end

  describe "incident suppression" do
    test "no incident opens while a window is running", %{scope: scope, service: service} do
      schedule(scope)

      assert Incidents.open_incident(service, AlertRule.default(), "connection refused") ==
               {:ok, :suppressed}

      assert Incidents.list_active_incidents(scope) == []
    end

    test "reconciliation is suppressed too, not just the transition", %{
      scope: scope,
      service: service
    } do
      schedule(scope)

      # Both paths into an incident have to be covered, or a service that was
      # already down when the window started would get one on the next probe.
      assert Incidents.reconcile_incident(service, :down, AlertRule.default()) ==
               {:ok, :suppressed}

      assert Incidents.list_active_incidents(scope) == []
    end

    test "an incident opens normally once the window has ended", %{
      scope: scope,
      service: service
    } do
      schedule(scope, %{starts_at: minutes(-60), ends_at: minutes(-1)})

      assert {:ok, incident} = Incidents.open_incident(service, AlertRule.default(), "down")
      assert incident.service_id == service.id
    end

    test "a window on another service does not suppress this one", %{
      scope: scope,
      service: service
    } do
      other_service = service_fixture(scope, %{name: "Search"})
      schedule(scope, %{service_id: other_service.id})

      assert {:ok, incident} = Incidents.open_incident(service, AlertRule.default(), "down")
      assert incident.service_id == service.id
    end

    test "an incident already open is left alone and still resolves", %{
      scope: scope,
      service: service
    } do
      {:ok, incident} = Incidents.open_incident(service, AlertRule.default(), "down")
      schedule(scope)

      # The window says "expect trouble from now on", not "forget what was
      # already broken".
      assert [still_open] = Incidents.list_active_incidents(scope)
      assert still_open.id == incident.id

      assert {:ok, resolved} = Incidents.resolve_open_incident(service)
      assert resolved.id == incident.id
    end
  end

  describe "listing" do
    test "lists windows that have not finished, soonest first", %{scope: scope} do
      schedule(scope, %{reason: "Later", starts_at: minutes(60), ends_at: minutes(90)})
      schedule(scope, %{reason: "Now", starts_at: minutes(-5), ends_at: minutes(30)})
      schedule(scope, %{reason: "Done", starts_at: minutes(-90), ends_at: minutes(-60)})

      assert Enum.map(Maintenance.list_current_windows(scope), & &1.reason) == ["Now", "Later"]
    end

    test "does not list another organization's", %{scope: scope} do
      other = organization_scope_fixture()
      schedule(other, %{reason: "Theirs"})

      assert Maintenance.list_current_windows(scope) == []
    end
  end
end
