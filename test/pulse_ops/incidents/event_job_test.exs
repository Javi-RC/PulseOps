defmodule PulseOps.Incidents.EventJobTest do
  use PulseOps.DataCase, async: true
  use Oban.Testing, repo: PulseOps.Repo

  import PulseOps.MonitoringFixtures
  import PulseOps.NotificationsFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Incidents
  alias PulseOps.Incidents.EventJob
  alias PulseOps.Monitoring.AlertRule
  alias PulseOps.Notifications.NotifyJob

  setup do
    scope = organization_scope_fixture()
    %{scope: scope, notifier: notifier_fixture(scope), service: service_fixture(scope)}
  end

  describe "on the path that opens or resolves an incident" do
    test "opening queues one announcement and no deliveries", %{service: service} do
      {:ok, incident} = Incidents.open_incident(service, AlertRule.default(), "down")

      assert_enqueued(
        worker: EventJob,
        args: %{"incident_id" => incident.id, "event" => "opened"}
      )

      # Finding the notifiers, checking for flapping and scheduling an escalation
      # used to happen right here — inside the monitor, after the commit. They
      # wait for the announcement now.
      refute_enqueued(worker: NotifyJob)
    end

    test "resolving on recovery queues a resolved announcement", %{service: service} do
      {:ok, incident} = Incidents.open_incident(service, AlertRule.default(), "down")
      {:ok, _resolved} = Incidents.resolve_open_incident(service)

      assert_enqueued(
        worker: EventJob,
        args: %{"incident_id" => incident.id, "event" => "resolved"}
      )
    end

    test "resolving by hand queues one too", %{scope: scope, service: service} do
      {:ok, incident} = Incidents.open_incident(service, AlertRule.default(), "down")
      {:ok, _resolved} = Incidents.resolve_incident(scope, incident)

      assert_enqueued(
        worker: EventJob,
        args: %{"incident_id" => incident.id, "event" => "resolved"}
      )
    end
  end

  describe "running the announcement" do
    test "queues a delivery for each matching notifier", %{
      notifier: notifier,
      service: service
    } do
      {:ok, incident} = Incidents.open_incident(service, AlertRule.default(), "down")

      assert :ok = perform_job(EventJob, %{"incident_id" => incident.id, "event" => "opened"})

      assert_enqueued(
        worker: NotifyJob,
        args: %{"notifier_id" => notifier.id, "incident_id" => incident.id, "event" => "opened"}
      )
    end

    test "is quiet when the incident is gone" do
      assert :ok = perform_job(EventJob, %{"incident_id" => 0, "event" => "opened"})
    end
  end
end
