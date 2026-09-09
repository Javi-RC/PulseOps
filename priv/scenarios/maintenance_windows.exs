# Drives maintenance windows against the running application: a real monitor,
# real probes against /dev/flaky, real timers.
#
#   docker compose run --rm -e PHX_SERVER=true web mix run priv/scenarios/maintenance_windows.exs
#
# The case that matters is the middle one. The endpoint is genuinely broken, the
# probes genuinely fail, the service is genuinely reported down — and no
# incident opens and nobody is paged, because somebody said this was expected.
# Then the window is cancelled and the very next probe opens one, without
# anything having been scheduled to undo the silence.

Logger.configure(level: :warning)

alias PulseOps.Accounts
alias PulseOps.Incidents
alias PulseOps.Maintenance
alias PulseOps.Monitoring
alias PulseOps.Monitoring.ServiceMonitor
alias PulseOps.Organizations
alias PulseOpsWeb.Flaky

defmodule Scenario do
  def step(text), do: IO.puts("\n== #{text}")
  def check(true, text), do: IO.puts("   PASS  #{text}")
  def check(false, text), do: IO.puts("   FAIL  #{text}")

  def until(label, timeout_ms, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(label, deadline, fun)
  end

  defp poll(label, deadline, fun) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(500)
          poll(label, deadline, fun)
        else
          IO.puts("   FAIL  timed out waiting for #{label}")
          nil
        end

      value ->
        value
    end
  end
end

suffix = System.os_time(:millisecond)
{:ok, user} = Accounts.register_user(%{email: "maint-#{suffix}@pulseops.test"})
{:ok, organization} = Organizations.create_organization(user, %{name: "Maint Demo #{suffix}"})

scope =
  user
  |> PulseOps.Accounts.Scope.for_user()
  |> PulseOps.Accounts.Scope.put_organization(organization, :owner)

{:ok, service} =
  Monitoring.create_service(scope, %{
    name: "Flaky Under Maintenance #{suffix}",
    environment: :production,
    url: "http://localhost:4000/dev/flaky",
    check_interval_ms: 10_000,
    timeout_ms: 5_000,
    enabled: true
  })

probe = fn ->
  ServiceMonitor.check_now(service.id)
  Process.sleep(1_500)
end

Scenario.step("A window is scheduled, then the endpoint really breaks")

{:ok, window} =
  Maintenance.create_window(scope, %{
    reason: "Deploying the new release",
    starts_at: DateTime.add(DateTime.utc_now(:second), -60, :second),
    ends_at: DateTime.add(DateTime.utc_now(:second), 3600, :second)
  })

Flaky.break()

# The default rule needs three consecutive failures.
for _ <- 1..4, do: probe.()

check = List.first(Monitoring.list_recent_checks(scope, service, 1))

Scenario.check(check && check.status == :down, "the probes really are failing")
Scenario.check(Monitoring.get_service!(scope, service.id).status == :down, "and the service reads down")

Scenario.check(
  Incidents.list_active_incidents(scope) == [],
  "no incident opened — nobody is paged for a deploy somebody scheduled"
)

Scenario.step("The status page says it is planned, not an outage")
{:ok, organization} = Organizations.update_organization(scope, organization, %{status_page_enabled: true})
scope = %{scope | organization: organization}

body = Req.get!("http://localhost:4000/status/#{organization.slug}", retry: false).body

Scenario.check(String.contains?(body, "Planned maintenance"), "the window is announced")
Scenario.check(String.contains?(body, "Deploying the new release"), "with its reason")

Scenario.check(
  String.contains?(body, "Down for planned maintenance"),
  "and the banner does not cry outage"
)

Scenario.step("Cancelling the window lets the next probe open an incident")
{:ok, _cancelled} = Maintenance.delete_window(scope, window.id)

probe.()

incident =
  Scenario.until("the incident", 30_000, fn ->
    List.first(Incidents.list_active_incidents(scope))
  end)

Scenario.check(incident != nil, "an incident opened on the very next probe")

# Nothing was scheduled to undo the silence: reconciliation noticed that a down
# service had no incident and opened one (ADR-009).
if incident do
  %{events: events} = Incidents.get_incident!(scope, incident.id)
  Scenario.check(List.first(events).type == :reopened, "opened by reconciliation, not a transition")
end

Scenario.step("Clean up")
Flaky.heal()
{:ok, _} = Monitoring.delete_service(scope, service)
IO.puts("   done")
