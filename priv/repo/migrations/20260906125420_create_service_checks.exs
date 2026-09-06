defmodule PulseOps.Repo.Migrations.CreateServiceChecks do
  use Ecto.Migration

  def change do
    create table(:service_checks) do
      add :service_id, references(:services, on_delete: :delete_all), null: false
      add :status, :string, null: false
      add :http_status, :integer
      add :response_time_ms, :integer
      add :error, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Every read of this table is "the latest checks for one service", and it is
    # by far the fastest-growing table in the schema.
    create index(:service_checks, [:service_id, :inserted_at])
  end
end
