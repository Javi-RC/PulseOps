# Checks the public status page against the running application: that a stranger
# with no session can read a published page, that an unpublished organization is
# indistinguishable from one that does not exist, and that nothing the page must
# not disclose reaches the HTML.
#
#   docker compose run --rm -e PHX_SERVER=true web mix run priv/scenarios/status_page.exs
#
# PHX_SERVER matters: under plain `mix run` the endpoint starts but never
# listens, so every request here would fail to connect.

Logger.configure(level: :warning)

alias PulseOps.Accounts
alias PulseOps.Incidents
alias PulseOps.Monitoring
alias PulseOps.Monitoring.AlertRule
alias PulseOps.Organizations

defmodule Check do
  def step(text), do: IO.puts("\n== #{text}")
  def ok(text), do: IO.puts("   PASS  #{text}")
  def fail(text), do: IO.puts("   FAIL  #{text}")
  def check(true, text), do: ok(text)
  def check(false, text), do: fail(text)
end

suffix = System.unique_integer([:positive])

{:ok, user} = Accounts.register_user(%{email: "status-#{suffix}@pulseops.test"})
{:ok, organization} = Organizations.create_organization(user, %{name: "Status Demo #{suffix}"})

scope =
  user
  |> PulseOps.Accounts.Scope.for_user()
  |> PulseOps.Accounts.Scope.put_organization(organization, :owner)

slug = organization.slug
url = "http://localhost:4000/status/#{slug}"

Check.step("An unpublished organization is not reachable")
Check.check(Req.get!(url, retry: false).status == 404, "404 before publishing")

Check.check(
  Req.get!("http://localhost:4000/status/never-existed-#{suffix}", retry: false).status == 404,
  "and a slug that never existed answers identically"
)

Check.step("Publish it, with one public service and one held back")

{:ok, organization} =
  Organizations.update_organization(scope, organization, %{
    status_page_enabled: true,
    status_page_headline: "Live status of our services"
  })

scope = %{scope | organization: organization}

{:ok, public_service} =
  Monitoring.create_service(scope, %{
    name: "Payments API",
    environment: :production,
    url: "http://internal-payments.corp.invalid/health",
    check_interval_ms: 3_600_000,
    timeout_ms: 5_000,
    enabled: true
  })

{:ok, _private_service} =
  Monitoring.create_service(scope, %{
    name: "Internal Admin",
    environment: :production,
    url: "http://internal-admin.corp.invalid/health",
    check_interval_ms: 3_600_000,
    timeout_ms: 5_000,
    enabled: true,
    public: false
  })

body = Req.get!(url, retry: false).body

Check.check(String.contains?(body, "Payments API"), "the public service is listed")
Check.check(not String.contains?(body, "Internal Admin"), "the private one is not")
Check.check(String.contains?(body, "Live status of our services"), "the headline is shown")

Check.step("Nothing the page must not disclose is in the HTML")
Check.check(not String.contains?(body, public_service.url), "no service URL")
Check.check(not String.contains?(body, "internal-payments"), "not even its hostname")
Check.check(not String.contains?(body, user.email), "no member email addresses")

Check.step("An outage shows up, with no internal detail")
Monitoring.update_service_status(public_service, :down)
{:ok, incident} = Incidents.open_incident(public_service, AlertRule.default(), "connection refused")

{:ok, _updated} =
  Incidents.update_incident(scope, incident, %{
    status: :identified,
    cause: "credentials for db-primary-3 had expired"
  })

body = Req.get!(url, retry: false).body

Check.check(String.contains?(body, "We are having an outage"), "the outage is announced")
Check.check(String.contains?(body, "Payments API is unavailable"), "the incident is named")
Check.check(not String.contains?(body, "db-primary-3"), "the cause is withheld")
Check.check(not String.contains?(body, "credentials"), "and so is the wording staff used")

Check.step("Taking the page down makes it unreachable again")

{:ok, _organization} =
  Organizations.update_organization(scope, scope.organization, %{status_page_enabled: false})

Check.check(Req.get!(url, retry: false).status == 404, "404 once unpublished")

Check.step("Clean up")
{:ok, _} = Monitoring.delete_service(scope, public_service)
IO.puts("   done")
