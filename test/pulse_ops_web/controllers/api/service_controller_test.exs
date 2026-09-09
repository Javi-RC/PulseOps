defmodule PulseOpsWeb.Api.ServiceControllerTest do
  # Not async: one test flips :allow_private_targets, which is application-wide,
  # and would fail the fixtures of any module running beside it.
  use PulseOpsWeb.ConnCase, async: false

  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Api
  alias PulseOps.Monitoring
  alias PulseOps.Organizations.Membership
  alias PulseOps.Repo

  setup %{conn: conn} do
    scope = organization_scope_fixture()
    {:ok, token, _record} = Api.create_token(scope, %{name: "CI"})

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn, scope: scope, token: token}
  end

  defp demote(scope, role) do
    Repo.get_by!(Membership, organization_id: scope.organization.id, user_id: scope.user.id)
    |> Ecto.Changeset.change(role: role)
    |> Repo.update!()
  end

  describe "authentication" do
    test "refuses a request with no token", %{conn: conn} do
      conn = conn |> delete_req_header("authorization") |> get(~p"/api/v1/services")

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "refuses an unknown token the same way it refuses a missing one", %{conn: conn} do
      unknown =
        conn
        |> put_req_header("authorization", "Bearer pops_nonsense")
        |> get(~p"/api/v1/services")

      # Same status and same body: telling them apart would say whether a token
      # had ever existed.
      assert json_response(unknown, 401) ==
               conn
               |> delete_req_header("authorization")
               |> get(~p"/api/v1/services")
               |> json_response(401)
    end

    test "refuses a revoked token", %{conn: conn, scope: scope} do
      {:ok, token, record} = Api.create_token(scope, %{name: "Doomed"})
      conn = put_req_header(conn, "authorization", "Bearer #{token}")

      assert conn |> get(~p"/api/v1/services") |> json_response(200)

      {:ok, _revoked} = Api.revoke_token(scope, record.id)

      assert conn |> get(~p"/api/v1/services") |> json_response(401)
    end
  end

  describe "index and show" do
    test "lists only this organization's services", %{conn: conn, scope: scope} do
      service_fixture(scope, %{name: "Mine"})
      other = organization_scope_fixture()
      service_fixture(other, %{name: "Theirs"})

      data = conn |> get(~p"/api/v1/services") |> json_response(200) |> Map.fetch!("data")

      assert Enum.map(data, & &1["name"]) == ["Mine"]
    end

    test "shows one", %{conn: conn, scope: scope} do
      service = service_fixture(scope, %{name: "Payments API"})

      body = conn |> get(~p"/api/v1/services/#{service.id}") |> json_response(200)

      assert body["data"]["name"] == "Payments API"
      assert body["data"]["id"] == service.id
    end

    test "another organization's service is a 404, not a 403", %{conn: conn} do
      other = organization_scope_fixture()
      theirs = service_fixture(other)

      # A 403 would confirm the id exists somewhere.
      body = conn |> get(~p"/api/v1/services/#{theirs.id}") |> json_response(404)
      assert body["error"]["code"] == "not_found"
    end

    test "an id that is not a number is a 404, not a crash", %{conn: conn} do
      assert conn |> get(~p"/api/v1/services/banana") |> json_response(404)
    end
  end

  describe "create" do
    test "creates a service", %{conn: conn, scope: scope} do
      body =
        conn
        |> post(~p"/api/v1/services", %{
          name: "Payments API",
          environment: "production",
          url: "https://api.example.com/health",
          check_interval_ms: 30_000,
          timeout_ms: 5_000
        })
        |> json_response(201)

      assert body["data"]["name"] == "Payments API"
      assert [%{name: "Payments API"}] = Monitoring.list_services(scope)
    end

    test "reports validation errors per field", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/v1/services", %{name: "x", url: "not-a-url"})
        |> json_response(422)

      assert body["error"]["code"] == "invalid"
      assert body["error"]["fields"]["url"] != []
    end

    test "cannot be aimed at a private address", %{conn: conn} do
      # The SSRF guard lives in the changeset, so it applies here without the
      # API restating it.
      Application.put_env(:pulse_ops, :allow_private_targets, false)
      on_exit(fn -> Application.put_env(:pulse_ops, :allow_private_targets, true) end)

      body =
        conn
        |> post(~p"/api/v1/services", %{
          name: "Metadata",
          environment: "production",
          url: "http://169.254.169.254/latest/",
          check_interval_ms: 30_000,
          timeout_ms: 5_000
        })
        |> json_response(422)

      assert Enum.any?(body["error"]["fields"]["url"], &(&1 =~ "private"))
    end
  end

  describe "update and delete" do
    test "updates a service", %{conn: conn, scope: scope} do
      service = service_fixture(scope, %{name: "Old"})

      body =
        conn |> patch(~p"/api/v1/services/#{service.id}", %{name: "New"}) |> json_response(200)

      assert body["data"]["name"] == "New"
    end

    test "cannot change which organization a service belongs to", %{conn: conn, scope: scope} do
      service = service_fixture(scope)
      other = organization_scope_fixture()

      conn
      |> patch(~p"/api/v1/services/#{service.id}", %{organization_id: other.organization.id})
      |> json_response(200)

      assert Repo.reload!(service).organization_id == scope.organization.id
    end

    test "deletes a service", %{conn: conn, scope: scope} do
      service = service_fixture(scope)

      assert conn |> delete(~p"/api/v1/services/#{service.id}") |> response(204)
      assert Monitoring.list_services(scope) == []
    end
  end

  describe "the token carries its owner's role" do
    test "a viewer may read but not write", %{conn: conn, scope: scope} do
      service = service_fixture(scope)
      demote(scope, :viewer)

      assert conn |> get(~p"/api/v1/services") |> json_response(200)

      body =
        conn |> patch(~p"/api/v1/services/#{service.id}", %{name: "Nope"}) |> json_response(403)

      assert body["error"]["code"] == "forbidden"
      assert Repo.reload!(service).name == service.name
    end

    test "a member may not manage services either", %{conn: conn, scope: scope} do
      demote(scope, :member)

      assert conn
             |> post(~p"/api/v1/services", %{name: "Nope", url: "https://example.com/health"})
             |> json_response(403)
    end
  end
end
