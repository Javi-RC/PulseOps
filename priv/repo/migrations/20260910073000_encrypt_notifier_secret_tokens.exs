defmodule PulseOps.Repo.Migrations.EncryptNotifierSecretTokens do
  @moduledoc """
  Moves `notifiers.secret_token` from plain text to a ciphertext (ADR-018).

  The rows are converted here, in Elixir, because the key lives in the
  application environment and must never appear in SQL. That makes this
  migration depend on `PulseOps.Vault` — acceptable while the ciphertext format
  carries a version byte, since a later format has to keep reading version 1
  anyway.
  """

  use Ecto.Migration

  import Ecto.Query

  alias PulseOps.Vault

  def up do
    rename table(:notifiers), :secret_token, to: :secret_token_plaintext

    alter table(:notifiers) do
      add :secret_token, :binary
    end

    flush()

    for {id, plaintext} <- rows_with(:secret_token_plaintext) do
      ciphertext = Vault.encrypt(plaintext)

      repo().update_all(
        from(n in "notifiers",
          where: n.id == ^id,
          update: [set: [secret_token: type(^ciphertext, :binary)]]
        ),
        []
      )
    end

    alter table(:notifiers) do
      remove :secret_token_plaintext
    end
  end

  def down do
    rename table(:notifiers), :secret_token, to: :secret_token_ciphertext

    alter table(:notifiers) do
      add :secret_token, :string
    end

    flush()

    for {id, ciphertext} <- rows_with(:secret_token_ciphertext) do
      {:ok, plaintext} = Vault.decrypt(ciphertext)

      repo().update_all(
        from(n in "notifiers", where: n.id == ^id, update: [set: [secret_token: ^plaintext]]),
        []
      )
    end

    alter table(:notifiers) do
      remove :secret_token_ciphertext
    end
  end

  defp rows_with(column) do
    repo().all(
      from(n in "notifiers",
        where: not is_nil(field(n, ^column)),
        select: {n.id, field(n, ^column)}
      )
    )
  end
end
