defmodule PulseOps.Repo.Migrations.AddFlappingAndEscalation do
  use Ecto.Migration

  # Notifications fired 1:1 with incidents and nothing suppressed them, so a
  # service sitting on its threshold produced a storm — and there was no way to
  # say "somebody is on this" or "nobody is, make more noise".
  def change do
    alter table(:incidents) do
      # Distinct from the :investigating workflow status on purpose. Moving an
      # incident to :investigating is a statement about the *incident*;
      # acknowledging is a statement about the *people* — somebody has it, stop
      # escalating. Conflating them means you cannot say "I have seen this" and
      # "I have not diagnosed it yet" at the same time, which is the normal case
      # in the first minute.
      add :acknowledged_at, :utc_datetime
      add :acknowledged_by_id, references(:users, on_delete: :nilify_all)
    end

    alter table(:notifiers) do
      # A channel that stays quiet until an incident has gone unacknowledged.
      # The whole point of a second line is that it is not paged for everything.
      add :escalation_only, :boolean, null: false, default: false
    end

    # Flap detection counts how many incidents a service has opened recently, so
    # the query is "this service, started after this moment".
    create index(:incidents, [:service_id, :started_at])
  end
end
