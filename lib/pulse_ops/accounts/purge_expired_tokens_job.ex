defmodule PulseOps.Accounts.PurgeExpiredTokensJob do
  @moduledoc """
  Nightly job that deletes `users_tokens` past their purpose-specific validity.

  Session tokens last `UserToken.session_validity_days()`, magic-link tokens
  `UserToken.magic_link_validity_minutes()` and change-email tokens
  `UserToken.change_email_validity_days()`.  Past those windows the tokens
  can never be validated and only consume space.

  Cron schedule is configured in `config/config.exs`.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias PulseOps.Accounts

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, Accounts.purge_expired_tokens()}
  end
end
