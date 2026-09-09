# Drives the F1 scenario against the running application: real ServiceMonitor
# processes, real HTTP probes against the app's own /dev/flaky endpoint, real
# timers. Nothing here is mocked.
#
# Takes about two minutes: the probe cycle is 10 s and going down needs three
# consecutive failures. Leaves its scenario user and organization behind in the
# development database; the service it creates is deleted at the end.
#
#   docker compose run --rm -e PHX_SERVER=true web mix run priv/scenarios/f1_reconciliation.exs
#
# PHX_SERVER matters: under plain `mix run` the endpoint starts but does not
# listen, so the probe gets "connection refused" instead of the flaky endpoint.

# Ecto logs every statement at :debug, which buries the scenario output.
Logger.configure(level: :info)

alias PulseOps.Accounts
alias PulseOps.Incidents
alias PulseOps.Monitoring
alias PulseOps.Organizations
alias PulseOpsWeb.Flaky

defmodule Scenario do
  def step(n, text), do: IO.puts("\n== #{n}. #{text}")
  def ok(text), do: IO.puts("   PASS  #{text}")

  def fail(text) do
    IO.puts("   FAIL  #{text}")
    System.at_exit(fn _ -> exit({:shutdown, 1}) end)
  end

  def check(true, text), do: ok(text)
  def check(false, text), do: fail(text)

  # Polls until fun returns something truthy, or gives up. Probing is on a real
  # 10 s cycle here, so this waits in wall-clock time on purpose.
  def until(label, timeout_ms, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(label, deadline, fun)
  end

  defp poll(label, deadline, fun) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1_000)
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

suffix = System.unique_integer([:positive])

{:ok, user} = Accounts.register_user(%{email: "f1-#{suffix}@pulseops.test"})
{:ok, organization} = Organizations.create_organization(user, %{name: "F1 Scenario #{suffix}"})

scope =
  user
  |> PulseOps.Accounts.Scope.for_user()
  |> PulseOps.Accounts.Scope.put_organization(organization, :owner)

Scenario.step(1, "Register a service pointing at the app's own flaky endpoint")

{:ok, service} =
  Monitoring.create_service(scope, %{
    name: "Flaky Demo",
    environment: :production,
    url: "http://localhost:4000/dev/flaky",
    check_interval_ms: 10_000,
    timeout_ms: 5_000,
    enabled: true
  })

Scenario.check(is_pid(PulseOps.Monitoring.ServiceMonitor.whereis(service.id)), "monitor started")

healthy =
  Scenario.until("the first healthy probe", 30_000, fn ->
    case Monitoring.list_recent_checks(scope, service, 1) do
      [%{status: :healthy} = check] -> check
      _other -> nil
    end
  end)

Scenario.check(
  healthy != nil,
  "the probe really reaches /dev/flaky (a refused connection would prove nothing)"
)

Scenario.step(2, "Break the endpoint and wait for the monitor to open an incident")
Flaky.break()

incident =
  Scenario.until("the incident to open", 90_000, fn ->
    List.first(Incidents.list_active_incidents(scope))
  end)

Scenario.check(incident != nil, "incident opened: #{inspect(incident && incident.title)}")

Scenario.step(3, "Resolve it by hand while the service is still broken")
{:ok, resolved} = Incidents.resolve_incident(scope, incident)
Scenario.check(resolved.resolved_by_id == user.id, "credited to the person who did it")
Scenario.check(Incidents.list_active_incidents(scope) == [], "no active incident right now")
Scenario.check(Flaky.healthy?() == false, "and the endpoint is still broken")

Scenario.step(4, "Within the grace period, the manual resolution must hold")
IO.puts("   grace is #{Application.get_env(:pulse_ops, :incident_reopen_grace_seconds)}s; waiting out two probe cycles")
Process.sleep(25_000)

Scenario.check(
  Incidents.list_active_incidents(scope) == [],
  "still nothing reopened — resolving by hand means snooze"
)

Scenario.step(5, "Past the grace period, the outage must get an incident again")
Application.put_env(:pulse_ops, :incident_reopen_grace_seconds, 0)

reopened =
  Scenario.until("the incident to reopen", 60_000, fn ->
    List.first(Incidents.list_active_incidents(scope))
  end)

Scenario.check(reopened != nil, "a new incident opened")
Scenario.check(reopened && reopened.id != incident.id, "it is a new row, not the resolved one")

if reopened do
  %{events: events} = Incidents.get_incident!(scope, reopened.id)
  event = List.first(events)
  Scenario.check(event.type == :reopened, "first timeline event is :reopened")
  Scenario.check(event.user_id == nil, "written by the monitor, credited to nobody")
  IO.puts("   timeline: #{event.description}")
end

Scenario.step(6, "Heal the endpoint; the monitor must close it on its own")
Flaky.heal()

Scenario.until("the incident to resolve", 60_000, fn ->
  if Incidents.list_active_incidents(scope) == [], do: :resolved
end)

Scenario.check(Incidents.list_active_incidents(scope) == [], "resolved automatically")

final = Incidents.list_incidents(scope)
IO.puts("\n   incidents on record: #{length(final)}")

for i <- Enum.reverse(final) do
  IO.puts("     ##{i.id} #{i.status} resolved_by=#{inspect(i.resolved_by_id)}")
end

Scenario.step(7, "Clean up")
{:ok, _} = Monitoring.delete_service(scope, service)
Application.put_env(:pulse_ops, :incident_reopen_grace_seconds, 300)
IO.puts("   done")
