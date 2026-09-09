defmodule PulseOps.Monitoring.AlertRuleTest do
  use PulseOps.DataCase, async: true

  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.AlertRule

  setup do
    %{scope: organization_scope_fixture()}
  end

  describe "create_alert_rule/2" do
    test "creates an organization-wide default rule", %{scope: scope} do
      assert {:ok, rule} =
               Monitoring.create_alert_rule(scope, valid_alert_rule_attributes())

      assert rule.organization_id == scope.organization.id
      assert rule.service_id == nil
      assert rule.failure_threshold == 3
      assert rule.severity == :medium
    end

    test "creates a per-service rule", %{scope: scope} do
      service = service_fixture(scope)

      assert {:ok, rule} =
               Monitoring.create_alert_rule(
                 scope,
                 valid_alert_rule_attributes(%{service_id: service.id, severity: :critical})
               )

      assert rule.service_id == service.id
      assert rule.severity == :critical
    end

    test "a rule cannot be bound to another organization's service", %{scope: scope} do
      victim = organization_scope_fixture()
      their_service = service_fixture(victim)

      assert {:error, changeset} =
               Monitoring.create_alert_rule(
                 scope,
                 valid_alert_rule_attributes(%{service_id: their_service.id})
               )

      assert "must belong to the organization" in errors_on(changeset).service_id

      # The point is not that the attacker reads anything — rule_for_monitoring/1
      # filters by organization anyway — but that the row would occupy the
      # victim's slot in the unique index and lock them out of their own service.
      assert {:ok, rule} =
               Monitoring.create_alert_rule(
                 victim,
                 valid_alert_rule_attributes(%{service_id: their_service.id})
               )

      assert rule.service_id == their_service.id
    end

    test "a member may not manage alert rules", %{scope: scope} do
      assert Monitoring.create_alert_rule(%{scope | role: :member}, %{}) ==
               {:error, :unauthorized}
    end

    test "an organization cannot have two default rules", %{scope: scope} do
      assert {:ok, _first} =
               Monitoring.create_alert_rule(scope, valid_alert_rule_attributes(severity: :high))

      # Postgres treats NULLs as distinct, so the plain unique index on
      # service_id never held this; a partial unique index does. The form's
      # check-then-act guard is now a convenience, not the guarantee.
      assert {:error, changeset} =
               Monitoring.create_alert_rule(scope, valid_alert_rule_attributes(severity: :low))

      assert "this organization already has a default rule" in errors_on(changeset).service_id
    end

    test "another organization is free to have its own default", %{scope: scope} do
      other = organization_scope_fixture()

      assert {:ok, _first} = Monitoring.create_alert_rule(scope, valid_alert_rule_attributes())
      assert {:ok, _second} = Monitoring.create_alert_rule(other, valid_alert_rule_attributes())
    end

    test "a service cannot have two rules", %{scope: scope} do
      service = service_fixture(scope)
      alert_rule_fixture(scope, %{service_id: service.id})

      assert {:error, changeset} =
               Monitoring.create_alert_rule(
                 scope,
                 valid_alert_rule_attributes(%{service_id: service.id})
               )

      assert "this service already has an alert rule" in errors_on(changeset).service_id
    end
  end

  describe "list_alert_rules/1" do
    test "lists only the scoped organization's rules, service rules first", %{scope: scope} do
      other_scope = organization_scope_fixture()
      alert_rule_fixture(other_scope)

      service = service_fixture(scope)
      service_rule = alert_rule_fixture(scope, %{service_id: service.id})
      org_rule = alert_rule_fixture(scope)

      rules = Monitoring.list_alert_rules(scope)

      assert Enum.map(rules, & &1.id) == [service_rule.id, org_rule.id]
      refute Enum.any?(rules, &(&1.organization_id == other_scope.organization.id))
    end
  end

  describe "get_rule_for_service/2 and rule_for_monitoring/1" do
    test "prefers the service rule over the organization default", %{scope: scope} do
      service = service_fixture(scope)
      alert_rule_fixture(scope, %{severity: :low})
      alert_rule_fixture(scope, %{service_id: service.id, severity: :critical})

      assert %AlertRule{severity: :critical} = Monitoring.get_rule_for_service(scope, service)
      assert %AlertRule{severity: :critical} = Monitoring.rule_for_monitoring(service)
    end

    test "falls back to the organization default when there is no service rule", %{scope: scope} do
      service = service_fixture(scope)
      alert_rule_fixture(scope, %{severity: :high})

      assert %AlertRule{severity: :high} = Monitoring.rule_for_monitoring(service)
    end

    test "falls back to the hardcoded defaults", %{scope: scope} do
      service = service_fixture(scope)

      assert %AlertRule{failure_threshold: 3, severity: :medium} =
               Monitoring.rule_for_monitoring(service)
    end

    test "does not leak another organization's rule", %{scope: _scope} do
      other_scope = organization_scope_fixture()
      service = service_fixture(other_scope)

      # A rule in another organization must never govern this service.
      alert_rule_fixture(other_scope, %{service_id: service.id, severity: :critical})
      alert_rule_fixture(other_scope, %{severity: :low})

      assert %AlertRule{severity: :critical} = Monitoring.rule_for_monitoring(service)
    end
  end

  describe "update/delete alert rules" do
    test "updates a rule", %{scope: scope} do
      rule = alert_rule_fixture(scope)

      assert {:ok, updated} =
               Monitoring.update_alert_rule(scope, rule, %{failure_threshold: 5, severity: :high})

      assert updated.failure_threshold == 5
      assert updated.severity == :high
    end

    test "deletes a rule", %{scope: scope} do
      rule = alert_rule_fixture(scope)

      assert {:ok, %AlertRule{}} = Monitoring.delete_alert_rule(scope, rule)
      assert Monitoring.list_alert_rules(scope) == []
    end

    test "a service defaults apply again once its rule is deleted", %{scope: scope} do
      service = service_fixture(scope)
      rule = alert_rule_fixture(scope, %{service_id: service.id, severity: :critical})

      Monitoring.delete_alert_rule(scope, rule)

      assert %AlertRule{severity: :medium} = Monitoring.rule_for_monitoring(service)
    end
  end

  describe "change_alert_rule/3" do
    test "returns a changeset", %{scope: scope} do
      rule = alert_rule_fixture(scope)

      assert %Ecto.Changeset{} = Monitoring.change_alert_rule(scope, rule)
    end
  end
end
