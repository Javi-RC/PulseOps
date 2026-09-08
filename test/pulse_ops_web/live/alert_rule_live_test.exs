defmodule PulseOpsWeb.AlertRuleLiveTest do
  use PulseOpsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PulseOps.MonitoringFixtures

  alias Ecto.Changeset
  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.AlertRule
  alias PulseOps.Organizations.Membership
  alias PulseOps.Repo

  setup :register_and_log_in_user_with_org

  defp alert_rules_path(scope), do: ~p"/orgs/#{scope.organization.slug}/settings/alert-rules"

  defp new_alert_rule_path(scope),
    do: ~p"/orgs/#{scope.organization.slug}/settings/alert-rules/new"

  defp edit_alert_rule_path(scope, rule),
    do: ~p"/orgs/#{scope.organization.slug}/settings/alert-rules/#{rule.id}/edit"

  describe "index" do
    test "shows the built-in defaults until one is configured", %{conn: conn, scope: scope} do
      {:ok, live, html} = live(conn, alert_rules_path(scope))

      assert html =~ "Organization default"
      assert html =~ "Configure defaults"
      assert html =~ "No per-service rules yet"
      assert has_element?(live, "#default-rule-card")
      assert has_element?(live, "#configure-defaults-link")
      assert has_element?(live, "#new-rule-link")
    end

    test "lists the organization default and each per-service rule", %{
      conn: conn,
      scope: scope
    } do
      service = service_fixture(scope)
      alert_rule_fixture(scope, %{failure_threshold: 5, severity: :low})
      rule = alert_rule_fixture(scope, %{service_id: service.id, severity: :critical})

      {:ok, live, html} = live(conn, alert_rules_path(scope))

      assert html =~ "Organization default"
      assert html =~ service.name
      assert html =~ "Critical"
      refute html =~ "No per-service rules yet"
      assert has_element?(live, "#rule-#{rule.id}")
      assert has_element?(live, "#edit-default-rule-link")
    end

    test "deletes a per-service rule", %{conn: conn, scope: scope} do
      service = service_fixture(scope)
      rule = alert_rule_fixture(scope, %{service_id: service.id})

      {:ok, live, _html} = live(conn, alert_rules_path(scope))
      assert has_element?(live, "#rule-#{rule.id}")

      live
      |> element("#rule-#{rule.id} button[phx-click=\"delete\"]")
      |> render_click()

      assert Monitoring.list_alert_rules(scope) == []
      refute has_element?(live, "#rule-#{rule.id}")
      assert render(live) =~ "No per-service rules yet"
    end

    test "a viewer sees the rules without the management controls", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      Repo.get_by!(Membership, organization_id: scope.organization.id, user_id: user.id)
      |> Changeset.change(role: :viewer)
      |> Repo.update!()

      {:ok, live, html} = live(conn, alert_rules_path(scope))

      assert html =~ "Organization default"
      refute has_element?(live, "#new-rule-link")
      refute has_element?(live, "#configure-defaults-link")
      refute has_element?(live, "#edit-default-rule-link")
    end
  end

  describe "new" do
    test "creates a per-service rule", %{conn: conn, scope: scope} do
      service = service_fixture(scope)

      {:ok, live, html} = live(conn, new_alert_rule_path(scope))
      assert html =~ "New alert rule"

      {:ok, _live, html} =
        live
        |> form("#alert-rule-form", %{
          alert_rule: %{
            service_id: "#{service.id}",
            failure_threshold: "1",
            success_threshold: "2",
            degraded_percent: "75",
            severity: "critical"
          }
        })
        |> render_submit()
        |> follow_redirect(conn, alert_rules_path(scope))

      assert html =~ "Alert rule created"

      assert [rule] = Monitoring.list_alert_rules(scope)
      assert rule.service_id == service.id
      assert rule.failure_threshold == 1
      assert rule.success_threshold == 2
      assert rule.degraded_ratio == 0.75
      assert rule.severity == :critical
    end

    test "creates the organization default when no service is picked", %{
      conn: conn,
      scope: scope
    } do
      {:ok, live, _html} = live(conn, new_alert_rule_path(scope))

      {:ok, _live, html} =
        live
        |> form("#alert-rule-form", %{
          alert_rule: %{
            failure_threshold: "2",
            success_threshold: "1",
            degraded_percent: "60",
            severity: "low"
          }
        })
        |> render_submit()
        |> follow_redirect(conn, alert_rules_path(scope))

      assert html =~ "Alert rule created"

      assert [rule] = Monitoring.list_alert_rules(scope)
      assert rule.service_id == nil
      assert rule.failure_threshold == 2
      assert rule.degraded_ratio == 0.6
    end

    test "does not offer a second rule for a service that has one", %{
      conn: conn,
      scope: scope
    } do
      service = service_fixture(scope)
      alert_rule_fixture(scope, %{service_id: service.id})

      {:ok, _live, html} = live(conn, new_alert_rule_path(scope))

      refute html =~ service.name
      assert html =~ "Organization default"
    end

    test "reports validation errors", %{conn: conn, scope: scope} do
      {:ok, live, _html} = live(conn, new_alert_rule_path(scope))

      html =
        live
        |> form("#alert-rule-form", %{
          alert_rule: %{failure_threshold: "0", degraded_percent: "abc"}
        })
        |> render_change()

      assert html =~ "must be greater than or equal to 1"
      assert html =~ "is invalid"
    end
  end

  describe "edit" do
    test "updates a rule and keeps it bound to its service", %{conn: conn, scope: scope} do
      service = service_fixture(scope)
      rule = alert_rule_fixture(scope, %{service_id: service.id, severity: :critical})

      {:ok, live, html} = live(conn, edit_alert_rule_path(scope, rule))
      assert html =~ "Edit alert rule"
      assert html =~ service.name

      {:ok, _live, html} =
        live
        |> form("#alert-rule-form", %{alert_rule: %{failure_threshold: "5"}})
        |> render_submit()
        |> follow_redirect(conn, alert_rules_path(scope))

      assert html =~ "Alert rule updated"

      assert %AlertRule{failure_threshold: 5, service_id: service_id} = Repo.reload!(rule)
      assert service_id == service.id
    end

    test "edits the organization default from its card", %{conn: conn, scope: scope} do
      default = alert_rule_fixture(scope, %{severity: :low})

      {:ok, live, html} = live(conn, edit_alert_rule_path(scope, default))
      assert html =~ "Organization default"

      {:ok, _live, _html} =
        live
        |> form("#alert-rule-form", %{alert_rule: %{severity: "high"}})
        |> render_submit()
        |> follow_redirect(conn, alert_rules_path(scope))

      assert Repo.reload!(default).severity == :high
    end
  end
end
