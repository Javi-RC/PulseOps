defmodule PulseOps.Repo.Migrations.AddDefaultAlertRuleUniqueIndex do
  use Ecto.Migration

  # An organization has at most one default alert rule — the row with a null
  # service_id. `unique_index(:alert_rules, [:service_id])` does not say that:
  # in Postgres NULLs are distinct from each other, so any number of defaults
  # are legal as far as the database is concerned. The only thing standing in
  # the way was the form hiding the "Organization default" option once one
  # existed, which is check-then-act with no transaction around it.
  #
  # With several defaults in place, `rule_for_monitoring/1` orders by
  # `is_nil(service_id)` with `limit: 1` and no tiebreaker, so which rule
  # governs a service becomes whatever the planner feels like returning.
  #
  # This is the invariant a constraint can express, so it belongs here and not
  # in a LiveView (ADR-004 is the precedent).
  def up do
    # A development database may already carry duplicates, and the index cannot
    # be created while they exist. Keep the oldest of each set, which is the one
    # the ordering above would most likely have been resolving to anyway.
    execute("""
    DELETE FROM alert_rules a
    USING alert_rules b
    WHERE a.service_id IS NULL
      AND b.service_id IS NULL
      AND a.organization_id = b.organization_id
      AND a.id > b.id
    """)

    create unique_index(:alert_rules, [:organization_id],
             where: "service_id IS NULL",
             name: :alert_rules_one_default_per_organization
           )
  end

  def down do
    drop index(:alert_rules, [:organization_id], name: :alert_rules_one_default_per_organization)
  end
end
