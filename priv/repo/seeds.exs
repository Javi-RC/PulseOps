# Demo data for local development.
#
#     docker compose run --rm web mix run priv/repo/seeds.exs
#
# Creates a user with three services covering the states worth demonstrating:
# one healthy, one that can be broken on demand, and one that is permanently
# unreachable.

alias PulseOps.Accounts
alias PulseOps.Accounts.Scope
alias PulseOps.Monitoring
alias PulseOps.Organizations

email = "demo@pulseops.test"

user =
  case Accounts.get_user_by_email(email) do
    nil ->
      {:ok, user} = Accounts.register_user(%{email: email})
      user

    user ->
      user
  end

[organization | _rest] = Organizations.list_organizations_for_user(user)
{:ok, _org, role} = Organizations.fetch_for_user(organization.slug, user)

scope =
  user
  |> Scope.for_user()
  |> Scope.put_organization(organization, role)

services = [
  %{
    name: "API Gateway",
    description:
      "Public entry point. Backed by the local flaky endpoint so it can be broken on demand.",
    environment: :production,
    url: "http://localhost:4000/dev/flaky",
    check_interval_ms: 10_000,
    timeout_ms: 5_000
  },
  %{
    name: "Auth Service",
    description:
      "Points at a real public endpoint, so the demo has something genuinely external.",
    environment: :production,
    url: "https://httpbin.org/status/200",
    check_interval_ms: 30_000,
    timeout_ms: 5_000
  },
  %{
    name: "Legacy Payments",
    description:
      "Host does not exist. Always down, which is what makes the incident view worth looking at.",
    environment: :staging,
    url: "https://payments.invalid/health",
    check_interval_ms: 15_000,
    timeout_ms: 3_000
  }
]

for attrs <- services do
  case Monitoring.create_service(scope, attrs) do
    {:ok, service} ->
      IO.puts("created service #{service.name}")

    {:error, %Ecto.Changeset{errors: errors}} ->
      if Keyword.has_key?(errors, :name) do
        IO.puts("service #{attrs.name} already exists")
      else
        IO.puts("could not create #{attrs.name}: #{inspect(errors)}")
      end
  end
end

IO.puts("""

Seeded organization "#{organization.name}" (/orgs/#{organization.slug}/services)
Log in as #{email} — the login link is printed to the console and shown at /dev/mailbox.
Break the gateway with: curl -X POST http://localhost:4000/dev/flaky/break
""")
