defmodule PulseOps.Repo.Migrations.CreateNotifiers do
  use Ecto.Migration

  def change do
    create table(:notifiers) do
      add :name, :string, null: false
      add :type, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :url, :string
      add :secret_token, :string
      add :recipient, :string
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:notifiers, [:organization_id])
  end
end
