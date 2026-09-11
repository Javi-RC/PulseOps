defmodule PulseOps.IncidentsTest do
  use PulseOps.DataCase, async: true

  import PulseOps.IncidentsFixtures
  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Incidents
  alias PulseOps.Incidents.Incident
  alias PulseOps.Monitoring.AlertRule
  alias PulseOps.Repo

  setup do
    scope = organization_scope_fixture()
    service = service_fixture(scope)

    %{scope: scope, service: service}
  end

  describe "open_incident/3" do
    test "opens an incident carrying the service's organization", %{
      scope: scope,
      service: service
    } do
      assert {:ok, %Incident{} = incident} =
               Incidents.open_incident(service, AlertRule.default(), "connection refused")

      assert incident.service_id == service.id
      assert incident.organization_id == scope.organization.id
      assert incident.status == :open
      assert incident.resolved_at == nil
      assert incident.title =~ service.name
      assert incident.started_at
    end

    test "records the detection on the timeline, with no author", %{
      scope: scope,
      service: service
    } do
      {:ok, incident} =
        Incidents.open_incident(service, AlertRule.default(), "connection refused")

      assert %{events: [event]} = Incidents.get_incident!(scope, incident.id)
      assert event.type == :detected
      assert event.description =~ "connection refused"
      # The system detected this, not a person.
      assert event.user_id == nil
    end

    test "assigns the severity from the alert rule, not the environment", %{scope: scope} do
      service = service_fixture(scope, %{name: "Prod", environment: :production})

      rule = %{AlertRule.default() | severity: :critical}

      assert {:ok, %{severity: :critical}} = Incidents.open_incident(service, rule)
    end

    test "returns the existing incident instead of opening a second one", %{service: service} do
      rule = AlertRule.default()
      {:ok, first} = Incidents.open_incident(service, rule)
      {:ok, second} = Incidents.open_incident(service, rule)

      assert second.id == first.id
      assert Repo.aggregate(Incident, :count) == 1
    end

    test "the database refuses a second open incident for the same service", %{service: service} do
      incident_fixture(service)

      # Bypassing the context to prove the guarantee is in the schema, not just
      # in the application logic (ADR-004).
      assert {:error, changeset} =
               %Incident{}
               |> Incident.open_changeset(%{
                 service_id: service.id,
                 organization_id: service.organization_id,
                 title: "duplicate",
                 severity: :high,
                 started_at: DateTime.utc_now(:second)
               })
               |> Repo.insert()

      assert "already has an open incident" in errors_on(changeset).service_id
    end

    test "allows a new incident once the previous one is resolved", %{service: service} do
      resolved_incident_fixture(service)

      assert {:ok, %Incident{}} = Incidents.open_incident(service, AlertRule.default())
      assert Repo.aggregate(Incident, :count) == 2
    end

    test "announces the incident to the organization", %{scope: scope, service: service} do
      Incidents.subscribe_incidents(scope)

      {:ok, incident} = Incidents.open_incident(service, AlertRule.default())

      assert_receive {:incident_opened, %Incident{id: id}}
      assert id == incident.id
    end
  end

  describe "resolve_open_incident/1" do
    test "closes the incident and stamps the time", %{service: service} do
      incident_fixture(service)

      assert {:ok, %Incident{} = incident} = Incidents.resolve_open_incident(service)
      assert incident.status == :resolved
      assert incident.resolved_at
      # Closed by the monitor, so nobody resolved it.
      assert incident.resolved_by_id == nil
    end

    test "adds a recovery event", %{scope: scope, service: service} do
      incident_fixture(service)
      {:ok, incident} = Incidents.resolve_open_incident(service)

      assert %{events: events} = Incidents.get_incident!(scope, incident.id)
      assert Enum.any?(events, &(&1.type == :recovered))
    end

    test "does nothing when there is no open incident", %{service: service} do
      assert Incidents.resolve_open_incident(service) == {:ok, nil}
    end

    test "announces the resolution", %{scope: scope, service: service} do
      incident_fixture(service)
      Incidents.subscribe_incidents(scope)

      {:ok, _incident} = Incidents.resolve_open_incident(service)

      assert_receive {:incident_resolved, %Incident{}}
    end
  end

  describe "listing" do
    test "returns only the scoped organization's incidents", %{scope: scope, service: service} do
      mine = incident_fixture(service)

      other_scope = organization_scope_fixture()
      other_service = service_fixture(other_scope)
      theirs = incident_fixture(other_service)

      ids = Enum.map(Incidents.list_incidents(scope), & &1.id)
      assert mine.id in ids
      refute theirs.id in ids
    end

    test "list_active_incidents excludes resolved ones", %{scope: scope, service: service} do
      other = service_fixture(scope, %{name: "Other"})
      open = incident_fixture(service)
      resolved = resolved_incident_fixture(other)

      ids = Enum.map(Incidents.list_active_incidents(scope), & &1.id)
      assert ids == [open.id]
      refute resolved.id in ids
    end

    test "count_active_incidents counts only open ones", %{scope: scope, service: service} do
      assert Incidents.count_active_incidents(scope) == 0

      incident_fixture(service)
      assert Incidents.count_active_incidents(scope) == 1

      Incidents.resolve_open_incident(service)
      assert Incidents.count_active_incidents(scope) == 0
    end

    test "get_incident!/2 hides another organization's incident", %{scope: scope} do
      other_scope = organization_scope_fixture()
      other_service = service_fixture(other_scope)
      theirs = incident_fixture(other_service)

      assert_raise Ecto.NoResultsError, fn -> Incidents.get_incident!(scope, theirs.id) end
    end
  end

  describe "update_incident/3" do
    test "moves the incident through the workflow and logs who did it", %{
      scope: scope,
      service: service
    } do
      incident = incident_fixture(service)

      assert {:ok, updated} =
               Incidents.update_incident(scope, incident, %{status: :investigating})

      assert updated.status == :investigating

      assert %{events: events} = Incidents.get_incident!(scope, incident.id)
      event = Enum.find(events, &(&1.type == :status_changed))
      assert event.user_id == scope.user.id
    end

    test "records the cause", %{scope: scope, service: service} do
      incident = incident_fixture(service)

      assert {:ok, updated} =
               Incidents.update_incident(scope, incident, %{
                 status: :identified,
                 cause: "Database connection pool exhausted"
               })

      assert updated.cause == "Database connection pool exhausted"
    end

    test "saving the cause without moving the status logs no status change", %{
      scope: scope,
      service: service
    } do
      incident = incident_fixture(service)
      {:ok, investigating} = Incidents.update_incident(scope, incident, %{status: :investigating})

      assert {:ok, _updated} =
               Incidents.update_incident(scope, investigating, %{
                 status: :investigating,
                 cause: "Database connection pool exhausted"
               })

      %{events: events} = Incidents.get_incident!(scope, incident.id)
      # One for the move to investigating; none for saving the cause.
      assert Enum.count(events, &(&1.type == :status_changed)) == 1
    end

    test "refuses to set resolved through the workflow", %{scope: scope, service: service} do
      incident = incident_fixture(service)

      assert {:error, changeset} =
               Incidents.update_incident(scope, incident, %{status: :resolved})

      assert errors_on(changeset)[:status]
    end

    test "refuses to touch an already resolved incident", %{scope: scope, service: service} do
      incident = incident_fixture(service)
      {:ok, resolved} = Incidents.resolve_incident(scope, incident)

      assert Incidents.update_incident(scope, resolved, %{status: :investigating}) ==
               {:error, :already_resolved}
    end

    test "a viewer may not touch incidents", %{scope: scope, service: service} do
      incident = incident_fixture(service)
      viewer_scope = %{scope | role: :viewer}

      assert Incidents.update_incident(viewer_scope, incident, %{status: :investigating}) ==
               {:error, :unauthorized}
    end

    test "a member may touch incidents", %{scope: scope, service: service} do
      incident = incident_fixture(service)
      member_scope = %{scope | role: :member}

      assert {:ok, _updated} =
               Incidents.update_incident(member_scope, incident, %{status: :investigating})
    end

    test "raises for an incident in another organization", %{service: service} do
      incident = incident_fixture(service)
      other_scope = organization_scope_fixture()

      assert_raise MatchError, fn ->
        Incidents.update_incident(other_scope, incident, %{status: :investigating})
      end
    end
  end

  describe "resolve_incident/3" do
    test "records who resolved it and why", %{scope: scope, service: service} do
      incident = incident_fixture(service)

      assert {:ok, resolved} =
               Incidents.resolve_incident(scope, incident, %{cause: "Bad deploy rolled back"})

      assert resolved.status == :resolved
      assert resolved.resolved_at
      assert resolved.resolved_by_id == scope.user.id
      assert resolved.cause == "Bad deploy rolled back"
    end

    test "frees the service to have a new incident", %{scope: scope, service: service} do
      incident = incident_fixture(service)
      {:ok, _resolved} = Incidents.resolve_incident(scope, incident)

      assert {:ok, %Incident{}} = Incidents.open_incident(service, AlertRule.default())
    end

    test "a viewer may not resolve", %{scope: scope, service: service} do
      incident = incident_fixture(service)

      assert Incidents.resolve_incident(%{scope | role: :viewer}, incident) ==
               {:error, :unauthorized}
    end
  end

  describe "add_note/3" do
    test "appends a note authored by the caller", %{scope: scope, service: service} do
      incident = incident_fixture(service)

      assert {:ok, event} = Incidents.add_note(scope, incident, "Paging the on-call engineer")
      assert event.type == :note
      assert event.user_id == scope.user.id
    end

    test "a viewer may not add notes", %{scope: scope, service: service} do
      incident = incident_fixture(service)

      assert Incidents.add_note(%{scope | role: :viewer}, incident, "nope") ==
               {:error, :unauthorized}
    end
  end

  describe "duration_seconds/1" do
    test "measures a resolved incident from start to resolution", _context do
      started = DateTime.add(DateTime.utc_now(:second), -600)

      incident = %Incident{started_at: started, resolved_at: DateTime.utc_now(:second)}

      assert Incident.duration_seconds(incident) == 600
    end

    test "measures an open incident up to now", _context do
      incident = %Incident{started_at: DateTime.add(DateTime.utc_now(:second), -30)}

      assert Incident.duration_seconds(incident) >= 30
      assert Incident.open?(incident)
    end
  end
end
