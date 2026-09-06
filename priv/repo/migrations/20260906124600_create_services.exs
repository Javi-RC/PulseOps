defmodule PulseOps.Repo.Migrations.CreateServices do
  use Ecto.Migration

  def change do
    create table(:services) do
      add :name, :string, null: false
      add :description, :text
      add :environment, :string, null: false
      add :url, :string, null: false
      add :check_interval_ms, :integer, null: false, default: 60_000
      add :timeout_ms, :integer, null: false, default: 5_000
      add :enabled, :boolean, default: true, null: false
      add :status, :string, null: false, default: "unknown"
      add :last_checked_at, :utc_datetime
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:services, [:organization_id])
    create unique_index(:services, [:organization_id, :name])
  end
end
