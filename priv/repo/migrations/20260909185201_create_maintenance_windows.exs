defmodule PulseOps.Repo.Migrations.CreateMaintenanceWindows do
  use Ecto.Migration

  # A planned deploy currently looks exactly like an outage: the probes fail, an
  # incident opens, and everyone on the notifier list is woken up for something
  # somebody scheduled. A window says "this was expected between these times".
  def change do
    create table(:maintenance_windows) do
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false

      # Null means the whole organization, the same shape alert_rules uses for
      # its default rule.
      add :service_id, references(:services, on_delete: :delete_all)
      add :created_by_id, references(:users, on_delete: :nilify_all)

      add :reason, :string, null: false
      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    # Every read is "is anything covering this service right now", which is a
    # range scan per organization ordered by when things end.
    create index(:maintenance_windows, [:organization_id, :ends_at])
    create index(:maintenance_windows, [:service_id])

    # A window that ends before it starts is silence with no end, which is the
    # one thing a maintenance window must never be able to become by accident.
    create constraint(:maintenance_windows, :maintenance_windows_end_after_start,
             check: "ends_at > starts_at"
           )
  end
end
