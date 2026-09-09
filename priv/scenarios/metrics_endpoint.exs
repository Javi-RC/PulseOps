# Smoke-checks the Prometheus endpoint against the running application: that it
# refuses an absent or wrong token, and that the metrics which only exist once
# their event has fired are actually being produced.
#
#   docker compose run --rm -e PHX_SERVER=true web mix run priv/scenarios/metrics_endpoint.exs
#
# PHX_SERVER matters: under plain `mix run` the endpoint starts but never
# listens, so every request here would fail to connect.

Logger.configure(level: :warning)

# Give the probes a moment to emit something.
Process.sleep(3_000)

base = "http://localhost:4000/metrics"

IO.puts("no token ->  #{Req.get!(base).status}")
IO.puts("bad token -> #{Req.get!(base, headers: [{"authorization", "Bearer nope"}]).status}")

resp = Req.get!(base, headers: [{"authorization", "Bearer dev-metrics"}])
IO.puts("good token -> #{resp.status}")

lines = String.split(resp.body, "\n")

for prefix <- ~w(pulse_ops_monitoring_check_count pulse_ops_monitoring_check_response_time_ms_bucket oban_job_stop_duration pulse_ops_repo_query_total_time vm_memory_total) do
  hit = Enum.find(lines, &String.starts_with?(&1, prefix))
  IO.puts(if hit, do: "  #{hit}", else: "  (no series yet) #{prefix}")
end

IO.puts("\nservice_id label present? #{String.contains?(resp.body, "service_id")}")
