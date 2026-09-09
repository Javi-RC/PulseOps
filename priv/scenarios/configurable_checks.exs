# Drives the configurable check options against the running application: real
# monitors, real HTTP against the app's own /dev/flaky endpoint, real timers.
#
#   docker compose run --rm -e PHX_SERVER=true web mix run priv/scenarios/configurable_checks.exs
#
# The interesting case is the last one. /dev/flaky answers 200 with a JSON body,
# and a service can be configured to require something in that body which is not
# there — so the endpoint is up, answering 200, and the service is correctly
# reported down. That is the failure a status code cannot see, and the reason
# body assertions exist.

Logger.configure(level: :warning)

alias PulseOps.Accounts
alias PulseOps.Monitoring
alias PulseOps.Monitoring.ServiceMonitor
alias PulseOps.Organizations

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

# os_time rather than unique_integer, which restarts with each VM and so repeats
# across runs. The organization name must also not slugify to the same thing as
# the email local part: registering a user already creates their personal
# organization with that slug, and a second one would collide with it.
suffix = System.os_time(:millisecond)
{:ok, user} = Accounts.register_user(%{email: "checks-#{suffix}@pulseops.test"})

{:ok, organization} =
  Organizations.create_organization(user, %{name: "Check Options #{suffix}"})

scope =
  user
  |> PulseOps.Accounts.Scope.for_user()
  |> PulseOps.Accounts.Scope.put_organization(organization, :owner)

flaky = "http://localhost:4000/dev/flaky"

base = %{
  environment: :production,
  url: flaky,
  check_interval_ms: 10_000,
  timeout_ms: 5_000,
  enabled: true
}

create = fn attrs ->
  {:ok, service} = Monitoring.create_service(scope, Map.merge(base, attrs))
  service
end

first_check = fn service ->
  Scenario.until("a check for #{service.name}", 30_000, fn ->
    List.first(Monitoring.list_recent_checks(scope, service, 1))
  end)
end

Scenario.step("A HEAD probe is enough for an endpoint that only needs to answer")
head = create.(%{name: "Head Probe #{suffix}", http_method: :head})
check = first_check.(head)
Scenario.check(check && check.status == :healthy, "healthy on HEAD")

Scenario.step("expected_status accepts an answer that is not a 2xx")
# /dev/flaky is currently healthy and answers 200, so demanding 404 must fail.
wrong = create.(%{name: "Wrong Status #{suffix}", expected_status: 404})
check = first_check.(wrong)
Scenario.check(check && check.status == :down, "down when the status is not the expected one")
Scenario.check(check && check.error =~ "expected HTTP status 404, got 200", "and says why")

right = create.(%{name: "Right Status #{suffix}", expected_status: 200})
check = first_check.(right)
Scenario.check(check && check.status == :healthy, "healthy when it is")

Scenario.step("A body assertion catches a service that is up and not well")
# The endpoint answers 200 with {"status":200,"latency_ms":50} and nothing else.
body = create.(%{name: "Body Assertion #{suffix}", body_assertion: ~s("database":"up")})
check = first_check.(body)

Scenario.check(check && check.http_status == 200, "the endpoint really answered 200")
Scenario.check(check && check.status == :down, "and the service is still reported down")
Scenario.check(check && check.error =~ "did not contain", "because the body did not say so")

Scenario.step("The same assertion passes when the text is there")
present = create.(%{name: "Body Present #{suffix}", body_assertion: ~s("latency_ms")})
check = first_check.(present)
Scenario.check(check && check.status == :healthy, "healthy when the body contains it")

Scenario.step("Headers reach the endpoint")
with_headers =
  create.(%{
    name: "With Headers #{suffix}",
    request_headers: %{"X-Probe" => "pulseops"}
  })

check = first_check.(with_headers)
Scenario.check(check && check.status == :healthy, "a probe carrying headers still works")

Scenario.step("Clean up")

for service <- [head, wrong, right, body, present, with_headers] do
  ServiceMonitor.whereis(service.id) && Monitoring.delete_service(scope, service)
end

IO.puts("   done")
