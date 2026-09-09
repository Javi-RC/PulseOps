# Drives the JSON API against the running application over real HTTP, with a
# real token, the way a script or a CI job would.
#
#   docker compose run --rm -e PHX_SERVER=true web mix run priv/scenarios/json_api.exs
#
# The point being demonstrated is that the API restates no authorization of its
# own: the same tenant filters and role checks the LiveViews go through apply
# here, because a token produces the same %Scope{} a session does.

Logger.configure(level: :warning)

alias PulseOps.Accounts
alias PulseOps.Api
alias PulseOps.Organizations
alias PulseOps.Organizations.Membership
alias PulseOps.Repo

defmodule Check do
  def step(text), do: IO.puts("\n== #{text}")
  def check(true, text), do: IO.puts("   PASS  #{text}")
  def check(false, text), do: IO.puts("   FAIL  #{text}")
end

suffix = System.os_time(:millisecond)
base = "http://localhost:4000/api/v1"

{:ok, user} = Accounts.register_user(%{email: "api-#{suffix}@pulseops.test"})
{:ok, organization} = Organizations.create_organization(user, %{name: "Api Demo #{suffix}"})

scope =
  user
  |> PulseOps.Accounts.Scope.for_user()
  |> PulseOps.Accounts.Scope.put_organization(organization, :owner)

{:ok, token, _record} = Api.create_token(scope, %{name: "Scenario"})

req = fn method, path, opts ->
  Req.request(
    [
      method: method,
      url: base <> path,
      headers: [{"authorization", "Bearer #{token}"}],
      retry: false
    ] ++ opts
  )
end

Check.step("A request with no token is refused")
{:ok, anonymous} = Req.get(base <> "/services", retry: false)
Check.check(anonymous.status == 401, "401 without a token")

Check.step("Creating a service over HTTP")

{:ok, created} =
  req.(:post, "/services", json: %{
    name: "Payments API",
    environment: "production",
    url: "https://api.example.com/health",
    check_interval_ms: 30_000,
    timeout_ms: 5_000
  })

Check.check(created.status == 201, "201 Created")
service_id = get_in(created.body, ["data", "id"])
Check.check(is_integer(service_id), "and it came back with an id")

Check.step("Reading it back")
{:ok, listed} = req.(:get, "/services", [])
names = Enum.map(listed.body["data"], & &1["name"])
Check.check("Payments API" in names, "the service is listed")

{:ok, shown} = req.(:get, "/services/#{service_id}", [])
Check.check(shown.body["data"]["name"] == "Payments API", "and readable on its own")

Check.step("The SSRF guard applies without the API restating it")
previous = Application.get_env(:pulse_ops, :allow_private_targets)
Application.put_env(:pulse_ops, :allow_private_targets, false)

{:ok, blocked} =
  req.(:post, "/services", json: %{
    name: "Metadata #{suffix}",
    environment: "production",
    url: "http://169.254.169.254/latest/",
    check_interval_ms: 30_000,
    timeout_ms: 5_000
  })

Application.put_env(:pulse_ops, :allow_private_targets, previous)

Check.check(blocked.status == 422, "422 for a private address")
Check.check(
  blocked.body["error"]["fields"]["url"] |> to_string() =~ "private",
  "with the guard's own message"
)

Check.step("Another organization's service is a 404, not a 403")
{:ok, other_user} = Accounts.register_user(%{email: "other-#{suffix}@pulseops.test"})
{:ok, other_org} = Organizations.create_organization(other_user, %{name: "Other Demo #{suffix}"})

other_scope =
  other_user
  |> PulseOps.Accounts.Scope.for_user()
  |> PulseOps.Accounts.Scope.put_organization(other_org, :owner)

{:ok, theirs} =
  PulseOps.Monitoring.create_service(other_scope, %{
    name: "Theirs",
    environment: :production,
    url: "https://theirs.example.com/health",
    check_interval_ms: 30_000,
    timeout_ms: 5_000
  })

{:ok, cross} = req.(:get, "/services/#{theirs.id}", [])
Check.check(cross.status == 404, "404 rather than 403, which would confirm the id exists")

Check.step("Incidents: open one, then resolve it through the API")

{:ok, service} = {:ok, PulseOps.Monitoring.get_service!(scope, service_id)}

{:ok, incident} =
  PulseOps.Incidents.open_incident(service, PulseOps.Monitoring.AlertRule.default(), "scenario")

{:ok, incidents} = req.(:get, "/incidents", [])
Check.check(length(incidents.body["data"]) == 1, "the incident is listed")

{:ok, resolved} = req.(:post, "/incidents/#{incident.id}/resolve", json: %{cause: "fixed it"})
Check.check(resolved.status == 200, "resolving answers 200")
Check.check(resolved.body["data"]["status"] == "resolved", "and the incident is resolved")

Check.check(
  resolved.body["data"]["resolved_by_id"] == user.id,
  "credited to the person the token acts as"
)

{:ok, again} = req.(:post, "/incidents/#{incident.id}/resolve", [])
Check.check(again.status == 409, "resolving twice is a conflict")

Check.step("A token can never outrank its owner")

Repo.get_by!(Membership, organization_id: organization.id, user_id: user.id)
|> Ecto.Changeset.change(role: :viewer)
|> Repo.update!()

{:ok, read} = req.(:get, "/services", [])
Check.check(read.status == 200, "a viewer's token still reads")

{:ok, write} = req.(:patch, "/services/#{service_id}", json: %{name: "Nope"})
Check.check(write.status == 403, "and is refused a write, with no code change on the API side")

Check.step("Revoking stops it immediately")
tokens = Api.list_tokens(%{scope | role: :owner})
{:ok, _revoked} = Api.revoke_token(%{scope | role: :owner}, hd(tokens).id)

{:ok, after_revoke} = req.(:get, "/services", [])
Check.check(after_revoke.status == 401, "401 once revoked")

Check.step("Clean up")
{:ok, _} = PulseOps.Monitoring.delete_service(%{scope | role: :owner}, service)
{:ok, _} = PulseOps.Monitoring.delete_service(other_scope, theirs)
IO.puts("   done")
