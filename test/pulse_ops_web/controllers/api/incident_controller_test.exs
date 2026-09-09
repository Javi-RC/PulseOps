defmodule PulseOpsWeb.Api.IncidentControllerTest do
  use PulseOpsWeb.ConnCase, async: true

  import PulseOps.IncidentsFixtures
  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Api
  alias PulseOps.Organizations.Membership
  alias PulseOps.Repo

  setup %{conn: conn} do
    scope = organization_scope_fixture()
    {:ok, token, _record} = Api.create_token(scope, %{name: "CI"})
    service = service_fixture(scope, %{name: "Payments API"})

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn, scope: scope, service: service}
  end

  defp demote(scope, role) do
    Repo.get_by!(Membership, organization_id: scope.organization.id, user_id: scope.user.id)
    |> Ecto.Changeset.change(role: role)
    |> Repo.update!()
  end

  describe "index" do
    test "lists this organization's incidents", %{conn: conn, service: service} do
      incident_fixture(service)

      data = conn |> get(~p"/api/v1/incidents") |> json_response(200) |> Map.fetch!("data")

      assert [incident] = data
      assert incident["service_id"] == service.id
      assert incident["open"] == true
      assert incident["duration_seconds"] >= 0
    end

    test "does not list another organization's", %{conn: conn} do
      other = organization_scope_fixture()
      incident_fixture(service_fixture(other))

      assert conn |> get(~p"/api/v1/incidents") |> json_response(200) |> Map.fetch!("data") == []
    end

    test "honours a limit, and caps it", %{conn: conn, scope: scope} do
      for n <- 1..3 do
        scope |> service_fixture(%{name: "Service #{n}"}) |> incident_fixture()
      end

      data =
        conn |> get(~p"/api/v1/incidents?limit=2") |> json_response(200) |> Map.fetch!("data")

      assert length(data) == 2

      # Nonsense does not become a crash or an unbounded query.
      assert conn |> get(~p"/api/v1/incidents?limit=banana") |> json_response(200)
    end
  end

  describe "show" do
    test "shows one, cause included", %{conn: conn, scope: scope, service: service} do
      incident = incident_fixture(service)

      {:ok, _updated} =
        PulseOps.Incidents.update_incident(scope, incident, %{
          status: :identified,
          cause: "connection pool exhausted"
        })

      body = conn |> get(~p"/api/v1/incidents/#{incident.id}") |> json_response(200)

      # Unlike the public status page, a token holder is already inside the
      # tenant, so the cause is theirs to read.
      assert body["data"]["cause"] == "connection pool exhausted"
      assert body["data"]["status"] == "identified"
    end

    test "another organization's incident is a 404", %{conn: conn} do
      other = organization_scope_fixture()
      theirs = incident_fixture(service_fixture(other))

      assert conn |> get(~p"/api/v1/incidents/#{theirs.id}") |> json_response(404)
    end
  end

  describe "update" do
    test "moves an incident through the workflow", %{conn: conn, service: service} do
      incident = incident_fixture(service)

      body =
        conn
        |> patch(~p"/api/v1/incidents/#{incident.id}", %{
          status: "investigating",
          cause: "looking into it"
        })
        |> json_response(200)

      assert body["data"]["status"] == "investigating"
      assert body["data"]["cause"] == "looking into it"
    end

    test "cannot resolve through the workflow", %{conn: conn, service: service} do
      incident = incident_fixture(service)

      # Resolving stamps who did it and when, so it is its own operation — the
      # workflow changeset refuses, and the API inherits that refusal.
      body =
        conn
        |> patch(~p"/api/v1/incidents/#{incident.id}", %{status: "resolved"})
        |> json_response(422)

      assert body["error"]["fields"]["status"] != []
    end
  end

  describe "resolve" do
    test "resolves an incident and credits the token's owner", %{
      conn: conn,
      scope: scope,
      service: service
    } do
      incident = incident_fixture(service)

      body =
        conn
        |> post(~p"/api/v1/incidents/#{incident.id}/resolve", %{cause: "restarted the pool"})
        |> json_response(200)

      assert body["data"]["status"] == "resolved"
      assert body["data"]["resolved_at"]
      assert body["data"]["open"] == false
      # A token acts as the person who made it, so the resolution has an author.
      assert body["data"]["resolved_by_id"] == scope.user.id
    end

    test "resolving twice is a conflict, not a second resolution", %{
      conn: conn,
      service: service
    } do
      incident = incident_fixture(service)

      assert conn |> post(~p"/api/v1/incidents/#{incident.id}/resolve") |> json_response(200)

      body = conn |> post(~p"/api/v1/incidents/#{incident.id}/resolve") |> json_response(409)
      assert body["error"]["code"] == "already_resolved"
    end
  end

  describe "roles" do
    test "a viewer may read but not respond", %{conn: conn, scope: scope, service: service} do
      incident = incident_fixture(service)
      demote(scope, :viewer)

      assert conn |> get(~p"/api/v1/incidents") |> json_response(200)

      assert conn
             |> post(~p"/api/v1/incidents/#{incident.id}/resolve")
             |> json_response(403)
    end

    test "a member may respond, which is the point of the role", %{
      conn: conn,
      scope: scope,
      service: service
    } do
      incident = incident_fixture(service)
      demote(scope, :member)

      assert conn
             |> post(~p"/api/v1/incidents/#{incident.id}/resolve")
             |> json_response(200)
    end
  end
end
