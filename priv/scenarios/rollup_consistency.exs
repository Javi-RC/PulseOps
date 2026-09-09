# Checks that the rollup table reproduces the raw checks exactly.
#
# Counts merge across hours by addition, so for every finished hour the summed
# rollups must equal the raw aggregation over the same rows. If this ever
# disagrees, the rollup job and the read path have drifted apart and every
# uptime figure on the dashboard is wrong by an unknown amount.
#
#   docker compose run --rm web mix run priv/scenarios/rollup_consistency.exs

Logger.configure(level: :warning)

import Ecto.Query
alias PulseOps.Repo
alias PulseOps.Monitoring.{Check, Rollup}

rollup_rows = Repo.aggregate(Rollup, :count)
check_rows = Repo.aggregate(Check, :count)
IO.puts("service_checks=#{check_rows}  rollups=#{rollup_rows}")

# For each service, compare the rolled-up totals against the raw checks of the
# same finished hours. They must agree exactly: counts merge by addition.
cutover =
  DateTime.utc_now() |> DateTime.truncate(:second) |> Map.merge(%{minute: 0, second: 0, microsecond: {0, 0}})

raw =
  from(c in Check,
    where: c.inserted_at < ^cutover,
    group_by: c.service_id,
    select: {c.service_id, %{
      total: count(c.id),
      up: fragment("count(*) FILTER (WHERE ? <> 'down')", c.status),
      lat: fragment("count(?)", c.response_time_ms),
      le100: fragment("count(*) FILTER (WHERE ? <= 100)", c.response_time_ms)
    }}
  ) |> Repo.all() |> Map.new()

rolled =
  from(r in Rollup,
    where: r.bucket_start < ^cutover,
    group_by: r.service_id,
    select: {r.service_id, %{
      total: sum(r.total), up: sum(r.up),
      lat: sum(r.latency_count), le100: sum(r.latency_le_100)
    }}
  ) |> Repo.all() |> Map.new()

keys = (Map.keys(raw) ++ Map.keys(rolled)) |> Enum.uniq() |> Enum.sort()

mismatches =
  Enum.reject(keys, fn id ->
    a = Map.get(raw, id)
    b = Map.get(rolled, id)
    a && b && a.total == b.total && a.up == b.up && a.lat == b.lat && a.le100 == b.le100
  end)

for id <- keys do
  a = Map.get(raw, id, %{total: 0, up: 0, lat: 0, le100: 0})
  b = Map.get(rolled, id, %{total: 0, up: 0, lat: 0, le100: 0})
  flag = if id in mismatches, do: "MISMATCH", else: "ok"
  IO.puts("  service #{id}: raw=#{inspect(a)} rollup=#{inspect(b)}  #{flag}")
end

IO.puts(if mismatches == [], do: "\nPASS  rollups agree with the raw checks exactly", else: "\nFAIL  #{inspect(mismatches)}")
