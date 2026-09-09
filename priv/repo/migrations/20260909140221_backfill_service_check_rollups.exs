defmodule PulseOps.Repo.Migrations.BackfillServiceCheckRollups do
  use Ecto.Migration

  # Without this, an existing installation gets an empty rollup table and the
  # dashboard's uptime silently narrows to the current hour: the reads take
  # complete hours from rollups and only the current one from raw checks, so
  # every finished hour would simply be missing.
  #
  # Written as one SQL statement rather than by calling the context, so the
  # migration does not depend on application code that will keep changing
  # around it. It is the same aggregation `roll_up_hour/1` performs, over every
  # finished hour at once.
  #
  # ON CONFLICT DO NOTHING makes it safe to run after the hourly job has already
  # produced some rows.
  def up do
    execute("""
    INSERT INTO service_check_rollups (
      service_id, bucket_start, total, up, degraded, down,
      latency_count, latency_sum, latency_max,
      latency_le_25, latency_le_50, latency_le_100, latency_le_250,
      latency_le_500, latency_le_1000, latency_le_2500, latency_le_5000,
      inserted_at, updated_at
    )
    SELECT
      service_id,
      date_trunc('hour', inserted_at),
      count(*),
      count(*) FILTER (WHERE status <> 'down'),
      count(*) FILTER (WHERE status = 'degraded'),
      count(*) FILTER (WHERE status = 'down'),
      count(response_time_ms),
      coalesce(sum(response_time_ms), 0),
      max(response_time_ms),
      count(*) FILTER (WHERE response_time_ms <= 25),
      count(*) FILTER (WHERE response_time_ms <= 50),
      count(*) FILTER (WHERE response_time_ms <= 100),
      count(*) FILTER (WHERE response_time_ms <= 250),
      count(*) FILTER (WHERE response_time_ms <= 500),
      count(*) FILTER (WHERE response_time_ms <= 1000),
      count(*) FILTER (WHERE response_time_ms <= 2500),
      count(*) FILTER (WHERE response_time_ms <= 5000),
      now() AT TIME ZONE 'utc',
      now() AT TIME ZONE 'utc'
    FROM service_checks
    WHERE inserted_at < date_trunc('hour', now() AT TIME ZONE 'utc')
    GROUP BY service_id, date_trunc('hour', inserted_at)
    ON CONFLICT (service_id, bucket_start) DO NOTHING
    """)
  end

  def down do
    execute("DELETE FROM service_check_rollups")
  end
end
