# Drives the F10 scenario against the running application: two real services,
# real ServiceMonitor processes probing the app's own /dev/flaky endpoint, and
# one of them killed until its restart budget runs out. Nothing here is mocked.
#
# Takes about half a minute. Leaves its scenario user and organization behind in
# the development database; the services it creates are deleted at the end.
#
#   docker compose run --rm -e PHX_SERVER=true web mix run priv/scenarios/f10_isolation.exs
#
# PHX_SERVER matters: under plain `mix run` the endpoint starts but does not
# listen, so the bystander's probes would record "connection refused".

# Ecto logs every statement at :debug, and every kill logs a crash report.
Logger.configure(level: :critical)

alias PulseOps.Accounts
alias PulseOps.Monitoring
alias PulseOps.Monitoring.MonitorContainer
alias PulseOps.Monitoring.MonitorSupervisor
alias PulseOps.Monitoring.ServiceMonitor
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

  def until(label, timeout_ms, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(label, deadline, fun)
  end

  defp poll(label, deadline, fun) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(50)
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

Flaky.heal()
suffix = System.unique_integer([:positive])

{:ok, user} = Accounts.register_user(%{email: "f10-#{suffix}@pulseops.test"})
{:ok, organization} = Organizations.create_organization(user, %{name: "F10 Scenario #{suffix}"})

scope =
  user
  |> PulseOps.Accounts.Scope.for_user()
  |> PulseOps.Accounts.Scope.put_organization(organization, :owner)

service = fn name ->
  {:ok, service} =
    Monitoring.create_service(scope, %{
      name: name,
      environment: :production,
      url: "http://localhost:4000/dev/flaky",
      check_interval_ms: 10_000,
      timeout_ms: 5_000,
      enabled: true
    })

  service
end

Scenario.step(1, "Watch two services")
crashy = service.("Crashy")
bystander = service.("Bystander")

Scenario.check(is_pid(ServiceMonitor.whereis(crashy.id)), "Crashy has a monitor")
Scenario.check(is_pid(ServiceMonitor.whereis(bystander.id)), "Bystander has a monitor")

bystander_pid = ServiceMonitor.whereis(bystander.id)
shared_supervisor = Process.whereis(MonitorSupervisor)

Scenario.step(2, "Kill Crashy's monitor five times — each inside its budget")

last =
  Enum.reduce(1..5, ServiceMonitor.whereis(crashy.id), fn n, monitor ->
    Process.exit(monitor, :kill)

    restarted =
      Scenario.until("restart #{n}", 5_000, fn ->
        case ServiceMonitor.whereis(crashy.id) do
          pid when is_pid(pid) and pid != monitor -> pid
          _other -> nil
        end
      end)

    Scenario.check(is_pid(restarted), "kill #{n}: restarted as #{inspect(restarted)}")
    restarted
  end)

Scenario.step(3, "Kill it a sixth time — past the budget")
Process.exit(last, :kill)

Scenario.until("Crashy's container to give up", 5_000, fn ->
  if MonitorContainer.whereis(crashy.id) == nil, do: :gone
end)

Process.sleep(500)
Scenario.check(ServiceMonitor.whereis(crashy.id) == nil, "Crashy is no longer restarted")
Scenario.check(Monitoring.monitor_state(crashy) == :stopped, "and says it is not watched")

Scenario.step(4, "Bystander must not have noticed")

Scenario.check(
  ServiceMonitor.whereis(bystander.id) == bystander_pid,
  "Bystander's monitor is the same process"
)

Scenario.check(
  Process.whereis(MonitorSupervisor) == shared_supervisor,
  "MonitorSupervisor never restarted"
)

Scenario.check(Monitoring.monitor_state(bystander) == :running, "Bystander reads as watched")

started = DateTime.utc_now()

fresh =
  Scenario.until("a Bystander probe after the kills", 20_000, fn ->
    case Monitoring.list_recent_checks(scope, bystander, 1) do
      [check] -> if DateTime.compare(check.inserted_at, started) != :lt, do: check
      _none -> nil
    end
  end)

Scenario.check(
  match?(%{status: :healthy}, fresh),
  "and it is still probing: #{inspect(fresh && {fresh.status, fresh.http_status, fresh.error})}"
)

Scenario.step(5, "Editing Crashy watches it again")
{:ok, crashy} = Monitoring.update_service(scope, crashy, %{name: "Crashy (edited)"})
Scenario.check(Monitoring.monitor_state(crashy) == :running, "Crashy is watched again")

Scenario.step(6, "Clean up")
{:ok, _} = Monitoring.delete_service(scope, crashy)
{:ok, _} = Monitoring.delete_service(scope, bystander)
IO.puts("   done")
