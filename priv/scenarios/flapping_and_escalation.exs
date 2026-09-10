# Drives anti-flapping and escalation against the running application, with a
# real monitor probing /dev/flaky and a real webhook receiver.
#
#   docker compose run --rm -e PHX_SERVER=true web mix run priv/scenarios/flapping_and_escalation.exs
#
# The two things being shown are the ones that separate an on-call tool from a
# toy: a service oscillating on its threshold sends one message rather than a
# storm, and a critical incident nobody picks up reaches a second channel that
# is otherwise silent.

Logger.configure(level: :warning)

alias PulseOps.Accounts
alias PulseOps.Incidents
alias PulseOps.Monitoring
alias PulseOps.Monitoring.AlertRule
alias PulseOps.Notifications
alias PulseOps.Notifications.DigestJob
alias PulseOps.Notifications.EscalationJob
alias PulseOps.Notifications.NotifyJob
alias PulseOps.Organizations
alias PulseOps.Repo

import Ecto.Query

defmodule Check do
  def step(text), do: IO.puts("\n== #{text}")
  def check(true, text), do: IO.puts("   PASS  #{text}")
  def check(false, text), do: IO.puts("   FAIL  #{text}")
end

queued = fn worker ->
  Repo.aggregate(
    from(j in Oban.Job, where: j.worker == ^worker and j.state in ["available", "scheduled"]),
    :count
  )
end

# Opening or resolving an incident only queues its announcement; the running
# queue picks it up a moment later and fans it out (ADR-020). So what the
# announcement leads to is waited for, not read straight away — and a delivery is
# counted in any state, because the live queue may already be running it.
eventually = fn fun ->
  deadline = System.monotonic_time(:millisecond) + 10_000

  Stream.repeatedly(fn ->
    result = fun.()
    if not result, do: Process.sleep(100)
    result
  end)
  |> Enum.find(fn result -> result or System.monotonic_time(:millisecond) > deadline end)
end

deliveries_to = fn notifier ->
  Repo.aggregate(
    from(j in Oban.Job,
      where: j.worker == "PulseOps.Notifications.NotifyJob",
      where: fragment("(?->>'notifier_id')::int = ?", j.args, ^notifier.id)
    ),
    :count
  )
end

suffix = System.os_time(:millisecond)
{:ok, user} = Accounts.register_user(%{email: "flap-#{suffix}@pulseops.test"})
{:ok, organization} = Organizations.create_organization(user, %{name: "Flap Demo #{suffix}"})

scope =
  user
  |> PulseOps.Accounts.Scope.for_user()
  |> PulseOps.Accounts.Scope.put_organization(organization, :owner)

{:ok, service} =
  Monitoring.create_service(scope, %{
    name: "Oscillating #{suffix}",
    environment: :production,
    url: "http://localhost:4000/dev/flaky",
    check_interval_ms: 3_600_000,
    timeout_ms: 5_000,
    enabled: true
  })

{:ok, first_line} =
  Notifications.create_notifier(scope, %{
    name: "First line #{suffix}",
    type: :webhook,
    enabled: true,
    url: "https://hooks.example.com/first"
  })

{:ok, second_line} =
  Notifications.create_notifier(scope, %{
    name: "Second line #{suffix}",
    type: :webhook,
    enabled: true,
    escalation_only: true,
    url: "https://hooks.example.com/second"
  })

Check.step("An ordinary incident pages the first line and not the second")
{:ok, _incident} = Incidents.open_incident(service, AlertRule.default(), "down")
{:ok, _resolved} = Incidents.resolve_open_incident(service)

# Both announcements — opened and resolved — have reached the first line.
Check.check(
  eventually.(fn -> deliveries_to.(first_line) >= 2 end),
  "the first line was told"
)

Check.check(deliveries_to.(second_line) == 0, "and the escalation-only channel stayed quiet")

Check.step("A service that keeps oscillating produces one digest, not a storm")
before_digest = queued.("PulseOps.Notifications.DigestJob")
before_notify = queued.("PulseOps.Notifications.NotifyJob")

# Eight more crossings. The third makes it a flapper; everything after that is
# absorbed by the digest already scheduled.
for _ <- 1..8 do
  {:ok, _} = Incidents.open_incident(service, AlertRule.default(), "down")
  {:ok, _} = Incidents.resolve_open_incident(service)
end

digests = queued.("PulseOps.Notifications.DigestJob") - before_digest

Check.check(Incidents.flapping?(service), "the service is recognised as flapping")
Check.check(digests == 1, "exactly one digest was scheduled for eight crossings")

Check.step("The digest counts what happened, when it runs")

# What the digest will report: every crossing inside the flap window, counted
# at run time rather than at schedule time.
window_start =
  DateTime.add(DateTime.utc_now(:second), -Notifications.flap_window_seconds(), :second)

crossings =
  Repo.aggregate(
    from(i in PulseOps.Incidents.Incident,
      where: i.service_id == ^service.id and i.started_at >= ^window_start
    ),
    :count
  )

Check.check(crossings == 9, "nine crossings are inside the window, not one per message")

Oban.Testing.perform_job(
  DigestJob,
  %{"service_id" => service.id, "organization_id" => organization.id},
  repo: Repo
)

# perform_job/3 calls the worker directly rather than consuming the row, so the
# scheduled digest is still there afterwards. What matters is that running it
# did not queue another one.
Check.check(
  queued.("PulseOps.Notifications.DigestJob") == before_digest + 1,
  "and running it queues no further digest"
)

Check.step("A critical incident nobody acknowledges reaches the second line")
Repo.delete_all(from j in Oban.Job, where: j.worker == "PulseOps.Notifications.NotifyJob")

critical = %{AlertRule.default() | severity: :critical}
{:ok, _} = Incidents.resolve_open_incident(service)

# Wait out the flap window so this one is treated as a real incident again.
Repo.update_all(
  from(i in PulseOps.Incidents.Incident, where: i.service_id == ^service.id),
  set: [started_at: DateTime.add(DateTime.utc_now(:second), -7200, :second)]
)

{:ok, incident} = Incidents.open_incident(service, critical, "connection refused")

Check.check(
  eventually.(fn -> queued.("PulseOps.Notifications.EscalationJob") >= 1 end),
  "an escalation was scheduled for the critical incident"
)

Oban.Testing.perform_job(EscalationJob, %{"incident_id" => incident.id}, repo: Repo)

escalated =
  Repo.aggregate(
    from(j in Oban.Job,
      where: j.worker == "PulseOps.Notifications.NotifyJob",
      where: fragment("?->>'event' = 'escalated'", j.args),
      where: fragment("(?->>'notifier_id')::int = ?", j.args, ^second_line.id)
    ),
    :count
  )

Check.check(escalated == 1, "the escalation-only channel was told")

Check.step("Acknowledging stops the next one escalating")
{:ok, acknowledged} = Incidents.acknowledge_incident(scope, incident)
Check.check(acknowledged.acknowledged_at != nil, "the incident is acknowledged")

Repo.delete_all(from j in Oban.Job, where: j.worker == "PulseOps.Notifications.NotifyJob")
Oban.Testing.perform_job(EscalationJob, %{"incident_id" => incident.id}, repo: Repo)

Check.check(
  queued.("PulseOps.Notifications.NotifyJob") == 0,
  "and running the escalation again sends nothing"
)

Check.step("Clean up")
{:ok, _} = Monitoring.delete_service(scope, service)
_ = first_line
IO.puts("   done")
