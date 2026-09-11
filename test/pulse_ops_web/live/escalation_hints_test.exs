defmodule PulseOpsWeb.EscalationHintsTest do
  # Not async: the escalation delay is application-wide configuration, and the
  # suite runs with escalation switched off.
  use PulseOpsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PulseOps.MonitoringFixtures

  alias PulseOps.Incidents
  alias PulseOps.Monitoring.AlertRule

  setup :register_and_log_in_user_with_org

  defp escalate_after(seconds) do
    previous = Application.get_env(:pulse_ops, :notifications, [])

    Application.put_env(
      :pulse_ops,
      :notifications,
      Keyword.put(previous, :escalation_after_seconds, seconds)
    )

    on_exit(fn -> Application.put_env(:pulse_ops, :notifications, previous) end)
  end

  defp open_incident(scope, severity) do
    service = service_fixture(scope)
    rule = %{AlertRule.default() | severity: severity}
    {:ok, incident} = Incidents.open_incident(service, rule, "connection refused")
    incident
  end

  describe "the notifier form" do
    test "says how long a critical incident waits before escalating", %{conn: conn, scope: scope} do
      escalate_after(900)

      {:ok, live, _html} =
        live(conn, ~p"/orgs/#{scope.organization.slug}/settings/notifiers/new")

      assert has_element?(
               live,
               "#escalation-hint",
               "15 minutes without anybody acknowledging it"
             )
    end

    test "says so when escalation is switched off", %{conn: conn, scope: scope} do
      escalate_after(nil)

      {:ok, live, _html} =
        live(conn, ~p"/orgs/#{scope.organization.slug}/settings/notifiers/new")

      assert has_element?(live, "#escalation-hint", "switched off")
    end
  end

  describe "an open incident" do
    test "a critical one says when it will escalate, until it is acknowledged", %{
      conn: conn,
      scope: scope
    } do
      escalate_after(900)
      incident = open_incident(scope, :critical)

      {:ok, live, _html} =
        live(conn, ~p"/orgs/#{scope.organization.slug}/incidents/#{incident}")

      assert has_element?(live, "#escalation-note", "If nobody does by")

      live |> element("button", "Acknowledge") |> render_click()

      refute has_element?(live, "#escalation-note")
    end

    test "one that is not critical never mentions escalating", %{conn: conn, scope: scope} do
      escalate_after(900)
      incident = open_incident(scope, :high)

      {:ok, live, _html} =
        live(conn, ~p"/orgs/#{scope.organization.slug}/incidents/#{incident}")

      refute has_element?(live, "#escalation-note")
    end
  end
end
