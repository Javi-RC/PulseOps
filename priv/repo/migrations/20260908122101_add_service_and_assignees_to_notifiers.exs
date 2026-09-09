defmodule PulseOps.Repo.Migrations.AddServiceAndAssigneesToNotifiers do
  use Ecto.Migration

  def change do
    alter table(:notifiers) do
      add :service_id, references(:services, on_delete: :nilify_all)
    end

    create index(:notifiers, [:service_id])

    create table(:notifier_assignments) do
      add :notifier_id, references(:notifiers, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:notifier_assignments, [:notifier_id, :user_id])
    create index(:notifier_assignments, [:user_id])
  end
end
