defmodule PulseOps.Notifications.EscalationTest do
  use PulseOps.DataCase, async: false
  use Oban.Testing, repo: PulseOps.Repo

  import PulseOps.MonitoringFixtures
  import PulseOps.NotificationsFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Incidents
  alias PulseOps.Monitoring.AlertRule
  alias PulseOps.Notifications.EscalationJob
  alias PulseOps.Notifications.NotifyJob

  setup do
    previous = Application.get_env(:pulse_ops, :notifications, [])

    Application.put_env(
      :pulse_ops,
      :notifications,
      Keyword.put(previous, :escalation_after_seconds, 900)
    )

    on_exit(fn -> Application.put_env(:pulse_ops, :notifications, previous) end)

    scope = organization_scope_fixture()
    %{scope: scope, service: service_fixture(scope, %{name: "Payments API"})}
  end

  defp critical_rule, do: %{AlertRule.default() | severity: :critical}

  describe "acknowledging" do
    test "records who has it, and when", %{scope: scope, service: service} do
      {:ok, incident} = Incidents.open_incident(service, critical_rule(), "down")

      assert {:ok, acknowledged} = Incidents.acknowledge_incident(scope, incident)

      assert acknowledged.acknowledged_at
      assert acknowledged.acknowledged_by_id == scope.user.id
    end

    test "is not the same thing as investigating", %{scope: scope, service: service} do
      {:ok, incident} = Incidents.open_incident(service, critical_rule(), "down")
      {:ok, acknowledged} = Incidents.acknowledge_incident(scope, incident)

      # Somebody has it, and has not diagnosed it — which is the normal state of
      # affairs in the first minute and cannot be said with one field.
      assert acknowledged.status == :open
      assert acknowledged.acknowledged_at
    end

    test "shows on the timeline with an author", %{scope: scope, service: service} do
      {:ok, incident} = Incidents.open_incident(service, critical_rule(), "down")
      {:ok, _acknowledged} = Incidents.acknowledge_incident(scope, incident)

      %{events: events} = Incidents.get_incident!(scope, incident.id)
      event = Enum.find(events, &(&1.type == :acknowledged))

      assert event
      assert event.user_id == scope.user.id
    end

    test "a viewer cannot acknowledge", %{scope: scope, service: service} do
      {:ok, incident} = Incidents.open_incident(service, critical_rule(), "down")

      assert Incidents.acknowledge_incident(%{scope | role: :viewer}, incident) ==
               {:error, :unauthorized}
    end

    test "a resolved incident cannot be acknowledged", %{scope: scope, service: service} do
      {:ok, incident} = Incidents.open_incident(service, critical_rule(), "down")
      {:ok, _resolved} = Incidents.resolve_open_incident(service)

      resolved = Incidents.get_incident!(scope, incident.id)

      assert Incidents.acknowledge_incident(scope, resolved) == {:error, :already_resolved}
    end
  end

  describe "scheduling an escalation" do
    test "a critical incident schedules one", %{service: service} do
      {:ok, incident} = Incidents.open_incident(service, critical_rule(), "down")

      assert_enqueued(worker: EscalationJob, args: %{"incident_id" => incident.id})
    end

    test "an ordinary incident does not", %{service: service} do
      {:ok, _incident} = Incidents.open_incident(service, AlertRule.default(), "down")

      refute_enqueued(worker: EscalationJob)
    end

    test "and neither does resolving one", %{service: service} do
      {:ok, _incident} = Incidents.open_incident(service, critical_rule(), "down")
      {:ok, _resolved} = Incidents.resolve_open_incident(service)

      assert length(all_enqueued(worker: EscalationJob)) == 1
    end

    test "nothing is scheduled when escalation is switched off", %{service: service} do
      previous = Application.get_env(:pulse_ops, :notifications, [])

      Application.put_env(
        :pulse_ops,
        :notifications,
        Keyword.put(previous, :escalation_after_seconds, nil)
      )

      {:ok, _incident} = Incidents.open_incident(service, critical_rule(), "down")

      refute_enqueued(worker: EscalationJob)
    end
  end

  describe "running the escalation" do
    test "tells the escalation-only channels when nobody picked it up", %{
      scope: scope,
      service: service
    } do
      second_line = notifier_fixture(scope, %{name: "Second line", escalation_only: true})
      {:ok, incident} = Incidents.open_incident(service, critical_rule(), "down")

      assert :ok = perform_job(EscalationJob, %{"incident_id" => incident.id})

      assert_enqueued(
        worker: NotifyJob,
        args: %{
          "notifier_id" => second_line.id,
          "incident_id" => incident.id,
          "event" => "escalated"
        }
      )
    end

    test "acknowledging cancels it", %{scope: scope, service: service} do
      notifier_fixture(scope, %{name: "Second line", escalation_only: true})
      {:ok, incident} = Incidents.open_incident(service, critical_rule(), "down")
      {:ok, acknowledged} = Incidents.acknowledge_incident(scope, incident)

      assert :ok = perform_job(EscalationJob, %{"incident_id" => acknowledged.id})

      # Checked when the job runs rather than by finding and deleting a
      # scheduled job, which is the more robust way round.
      refute_enqueued(worker: NotifyJob, args: %{"event" => "escalated"})
    end

    test "resolving cancels it too", %{scope: scope, service: service} do
      notifier_fixture(scope, %{name: "Second line", escalation_only: true})
      {:ok, incident} = Incidents.open_incident(service, critical_rule(), "down")
      {:ok, _resolved} = Incidents.resolve_open_incident(service)

      assert :ok = perform_job(EscalationJob, %{"incident_id" => incident.id})

      refute_enqueued(worker: NotifyJob, args: %{"event" => "escalated"})
      _ = scope
    end

    test "is quiet when the incident is gone", %{scope: _scope} do
      assert :ok = perform_job(EscalationJob, %{"incident_id" => 0})
    end

    test "writes the escalation onto the timeline", %{scope: scope, service: service} do
      notifier_fixture(scope, %{name: "Second line", escalation_only: true})
      {:ok, incident} = Incidents.open_incident(service, critical_rule(), "down")

      perform_job(EscalationJob, %{"incident_id" => incident.id})

      %{events: events} = Incidents.get_incident!(scope, incident.id)
      event = Enum.find(events, &(&1.type == :escalated))

      # No author: nobody did this, which is the point being recorded.
      assert event
      assert event.user_id == nil
    end
  end

  describe "escalation-only channels" do
    test "stay quiet for an ordinary incident", %{scope: scope, service: service} do
      second_line = notifier_fixture(scope, %{name: "Second line", escalation_only: true})
      first_line = notifier_fixture(scope, %{name: "First line"})

      {:ok, incident} = Incidents.open_incident(service, critical_rule(), "down")

      assert_enqueued(worker: NotifyJob, args: %{"notifier_id" => first_line.id})

      refute_enqueued(
        worker: NotifyJob,
        args: %{
          "notifier_id" => second_line.id,
          "incident_id" => incident.id,
          "event" => "opened"
        }
      )
    end

    test "an escalation reaches everybody, including those already told", %{
      scope: scope,
      service: service
    } do
      second_line = notifier_fixture(scope, %{name: "Second line", escalation_only: true})
      first_line = notifier_fixture(scope, %{name: "First line"})

      {:ok, incident} = Incidents.open_incident(service, critical_rule(), "down")
      perform_job(EscalationJob, %{"incident_id" => incident.id})

      # Nobody picked it up, so more noise is exactly the intent.
      assert_enqueued(
        worker: NotifyJob,
        args: %{"notifier_id" => second_line.id, "event" => "escalated"}
      )

      assert_enqueued(
        worker: NotifyJob,
        args: %{"notifier_id" => first_line.id, "event" => "escalated"}
      )
    end
  end
end
