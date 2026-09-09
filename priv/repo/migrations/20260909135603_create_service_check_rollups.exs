defmodule PulseOps.Repo.Migrations.CreateServiceCheckRollups do
  use Ecto.Migration

  # One row per service per hour, so the dashboard stops aggregating raw checks.
  #
  # service_checks grows at 86,400 / interval rows per service per day — 100
  # services at 30 s is ~29M rows a month — and both uptime_by_service/2 and
  # service_metrics/3 aggregated over that raw data. Worse, retention is
  # configurable, so lengthening the window silently made the dashboard slower.
  # A rollup row covers 120 raw checks at a 30 s interval, and the count is
  # bounded by hours rather than by probe frequency.
  #
  # Counts merge across hours by addition. Percentiles do not: the p95 of a day
  # is not the average of 24 hourly p95s, and storing hourly percentiles would
  # produce a number that looks right and is not. So latency is kept as a
  # cumulative histogram — latency_le_<n> counts every check at or under <n> ms —
  # which does merge by addition, and percentiles are interpolated out of it the
  # way Prometheus does it. The cost is bounded error, not silent error.
  def change do
    create table(:service_check_rollups) do
      add :service_id, references(:services, on_delete: :delete_all), null: false
      # Truncated to the hour; the row covers [bucket_start, bucket_start + 1h).
      add :bucket_start, :utc_datetime, null: false

      add :total, :integer, null: false, default: 0
      add :up, :integer, null: false, default: 0
      add :degraded, :integer, null: false, default: 0
      add :down, :integer, null: false, default: 0

      # Checks that recorded a response time at all — a connection refused has
      # none, so this is not the same as total.
      add :latency_count, :integer, null: false, default: 0
      add :latency_sum, :bigint, null: false, default: 0
      add :latency_max, :integer

      for bound <- [25, 50, 100, 250, 500, 1000, 2500, 5000] do
        add :"latency_le_#{bound}", :integer, null: false, default: 0
      end

      timestamps(type: :utc_datetime)
    end

    # The job recomputes an hour rather than appending to it, so it needs to
    # upsert on this key; the reads are all "these services, this hour range".
    create unique_index(:service_check_rollups, [:service_id, :bucket_start])
  end
end
