defmodule PulseOps.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    create table(:api_tokens) do
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false

      # The person the token acts as. A token is not an identity of its own: it
      # borrows one, and the role it gets is read from that person's membership
      # at request time. Removing somebody from an organization therefore
      # disarms every token they made, without anything having to remember to.
      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :name, :string, null: false

      # Only the hash is stored. The token itself is shown once, at creation,
      # and is unrecoverable afterwards — which is the difference between this
      # and notifiers.secret_token, and the reason this one is not the same
      # piece of debt.
      add :hashed_token, :binary, null: false

      # The first few characters of the token, kept in the clear so a person can
      # tell two tokens apart in a list without the database holding anything
      # that could be replayed.
      add :prefix, :string, null: false

      add :last_used_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Every request looks a token up by its hash, so this index is the API's hot
    # path, and the uniqueness is what makes a collision a database error rather
    # than an authentication mystery.
    create unique_index(:api_tokens, [:hashed_token])
    create index(:api_tokens, [:organization_id])
    create unique_index(:api_tokens, [:organization_id, :name])
  end
end
