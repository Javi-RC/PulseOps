defmodule PulseOps.Repo.Migrations.CreateOrganizations do
  use Ecto.Migration

  def change do
    create table(:organizations) do
      add :name, :string, null: false
      add :slug, :string, null: false

      timestamps(type: :utc_datetime)
    end

    # The slug is the tenant key in every route, so it must be unique and fast
    # to look up.
    create unique_index(:organizations, [:slug])

    create table(:organization_members) do
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organization_members, [:organization_id, :user_id])
    create index(:organization_members, [:user_id])
  end
end
