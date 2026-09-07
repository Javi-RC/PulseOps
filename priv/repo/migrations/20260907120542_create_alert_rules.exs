defmodule PulseOps.Repo.Migrations.CreateAlertRules do
  use Ecto.Migration

  def change do
    create table(:alert_rules) do
      add :failure_threshold, :integer, null: false, default: 3
      add :success_threshold, :integer, null: false, default: 2
      add :degraded_ratio, :float, null: false, default: 0.5
      add :severity, :string, null: false, default: "medium"
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false
      add :service_id, references(:services, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:alert_rules, [:organization_id])
    # A unique index already covers lookups by service_id; a plain index on the
    # same column would share the name and collide.
    create unique_index(:alert_rules, [:service_id])
  end
end
