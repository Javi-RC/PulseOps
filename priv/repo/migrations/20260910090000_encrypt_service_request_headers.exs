defmodule PulseOps.Repo.Migrations.EncryptServiceRequestHeaders do
  @moduledoc """
  Moves `services.request_headers` from `jsonb` to a ciphertext of its JSON
  (ADR-018), the same way `notifiers.secret_token` was moved: in Elixir, so the
  key never appears in SQL.

  Every row is converted, including the empty maps, because the column stays
  `NOT NULL` and there is no ciphertext a database default could hold.
  """

  use Ecto.Migration

  import Ecto.Query

  alias PulseOps.Vault

  def up do
    rename table(:services), :request_headers, to: :request_headers_plaintext

    alter table(:services) do
      add :request_headers, :binary
    end

    flush()

    for {id, headers} <- rows_with(:request_headers_plaintext) do
      ciphertext = headers |> Jason.encode!() |> Vault.encrypt()

      repo().update_all(
        from(s in "services",
          where: s.id == ^id,
          update: [set: [request_headers: type(^ciphertext, :binary)]]
        ),
        []
      )
    end

    alter table(:services) do
      modify :request_headers, :binary, null: false
      remove :request_headers_plaintext
    end
  end

  def down do
    rename table(:services), :request_headers, to: :request_headers_ciphertext

    alter table(:services) do
      add :request_headers, :map, null: false, default: %{}
    end

    flush()

    for {id, ciphertext} <- rows_with(:request_headers_ciphertext) do
      {:ok, json} = Vault.decrypt(ciphertext)
      headers = Jason.decode!(json)

      repo().update_all(
        from(s in "services",
          where: s.id == ^id,
          update: [set: [request_headers: type(^headers, :map)]]
        ),
        []
      )
    end

    alter table(:services) do
      remove :request_headers_ciphertext
    end
  end

  defp rows_with(column) do
    repo().all(
      from(s in "services",
        where: not is_nil(field(s, ^column)),
        select: {s.id, field(s, ^column)}
      )
    )
  end
end
