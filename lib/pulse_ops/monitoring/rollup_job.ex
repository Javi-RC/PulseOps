defmodule PulseOps.Monitoring.RollupJob do
  @moduledoc """
  Hourly job that pre-aggregates `service_checks` into `service_check_rollups`.

  Runs a few minutes past the hour and rolls up the hour that has just finished,
  so it never races the checks still landing in the current one. Accepts an
  `"hours_ago"` arg to roll a different hour, and a `"backfill"` arg to catch up
  a range — which is how the table was populated when it was introduced, and how
  a missed run is repaired.

  `roll_up_hour/1` recomputes an hour and upserts it rather than adding to what
  is there, so a retry, a backfill overlapping a scheduled run, or two runs of
  the same hour all converge on the same numbers instead of double-counting.

  Cron schedule is configured in `config/config.exs`.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias PulseOps.Monitoring

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"backfill" => hours}}) when is_integer(hours) and hours > 0 do
    {:ok, Monitoring.backfill_rollups(hours)}
  end

  def perform(%Oban.Job{args: %{"hours_ago" => hours_ago}}) when is_integer(hours_ago) do
    {:ok, Monitoring.roll_up_hour(hours_ago(hours_ago))}
  end

  def perform(%Oban.Job{}) do
    {:ok, Monitoring.roll_up_hour(hours_ago(1))}
  end

  defp hours_ago(hours), do: DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
end
