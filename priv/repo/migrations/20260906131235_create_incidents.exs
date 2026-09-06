defmodule PulseOps.Repo.Migrations.CreateIncidents do
  use Ecto.Migration

  def change do
    create table(:incidents) do
      add :service_id, references(:services, on_delete: :delete_all), null: false
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :severity, :string, null: false
      add :status, :string, null: false
      add :cause, :text
      add :started_at, :utc_datetime, null: false
      add :resolved_at, :utc_datetime
      add :resolved_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:incidents, [:organization_id, :started_at])
    create index(:incidents, [:service_id])

    # At most one unresolved incident per service, enforced by the database
    # rather than by a check-then-insert in the application. Two monitors racing
    # — or two nodes, once the system is clustered — cannot both win.
    create unique_index(:incidents, [:service_id],
             where: "resolved_at IS NULL",
             name: :incidents_one_open_per_service
           )

    create table(:incident_events) do
      add :incident_id, references(:incidents, on_delete: :delete_all), null: false
      # Null for events the system generated itself.
      add :user_id, references(:users, on_delete: :nilify_all)
      add :type, :string, null: false
      add :description, :text, null: false
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:incident_events, [:incident_id, :occurred_at])
  end
end
