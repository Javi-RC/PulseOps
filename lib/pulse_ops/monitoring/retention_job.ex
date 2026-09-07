defmodule PulseOps.Monitoring.RetentionJob do
  @moduledoc """
  Nightly job that deletes `service_checks` older than the retention window.

  The window defaults to the `:checks_retention_days` value under the
  `:retention` application config, or can be overridden per-invocation with a
  `"days"` arg — which is how the test suite drives it.

  Cron schedule is configured in `config/config.exs`.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias PulseOps.Monitoring

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"days" => days}}) when is_integer(days) and days > 0 do
    {:ok, Monitoring.prune_old_checks(days)}
  end

  def perform(%Oban.Job{}) do
    days = Application.get_env(:pulse_ops, :retention, [])[:checks_retention_days] || 30

    {:ok, Monitoring.prune_old_checks(days)}
  end
end
