defmodule PulseOps.Repo.Migrations.AddInsertedAtIndexToServiceChecks do
  use Ecto.Migration

  # Built without taking a write lock, because service_checks is the
  # fastest-growing table in the schema and this migration will one day run
  # against a table with tens of millions of rows in it. CREATE INDEX
  # CONCURRENTLY cannot run inside a transaction, which is what both attributes
  # below are for.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # The only index on service_checks was [:service_id, :inserted_at], which
  # serves every read — they are all "the latest checks for one service". The
  # nightly retention delete filters on inserted_at alone, and a composite index
  # cannot be used for a predicate that does not constrain its leading column.
  # So the delete was a sequential scan over the largest table in the schema,
  # every night, growing with retention.
  def change do
    create index(:service_checks, [:inserted_at], concurrently: true)
  end
end
