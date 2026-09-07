defmodule PulseOps.Accounts.PurgeExpiredTokensJobTest do
  use PulseOps.DataCase, async: true
  use Oban.Testing, repo: PulseOps.Repo

  import PulseOps.AccountsFixtures

  alias PulseOps.Accounts
  alias PulseOps.Accounts.PurgeExpiredTokensJob
  alias PulseOps.Accounts.UserToken

  setup do
    %{user: user_fixture()}
  end

  test "purges all token families past their validity windows", %{user: user} do
    _session = Accounts.generate_user_session_token(user)
    _login = generate_user_magic_link_token(user)

    _ =
      Accounts.deliver_user_update_email_instructions(
        user,
        user.email,
        &"/users/settings/confirm-email/#{&1}"
      )

    {3, nil} =
      Repo.update_all(
        from(t in UserToken, where: t.user_id == ^user.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -31, :day)]
      )

    assert {:ok, 3} = perform_job(PurgeExpiredTokensJob, %{})
    assert Repo.all(from(t in UserToken, where: t.user_id == ^user.id)) == []
  end
end
