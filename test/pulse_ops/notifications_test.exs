defmodule PulseOps.NotificationsTest do
  use PulseOps.DataCase, async: true
  use Oban.Testing, repo: PulseOps.Repo

  import PulseOps.MonitoringFixtures
  import PulseOps.NotificationsFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Incidents
  alias PulseOps.Monitoring.AlertRule
  alias PulseOps.Notifications
  alias PulseOps.Notifications.NotifyJob

  describe "list_notifiers/1" do
    test "returns only the notifiers of the scoped organization" do
      scope = organization_scope_fixture()
      other_scope = organization_scope_fixture()

      notifier = notifier_fixture(scope)
      notifier_fixture(other_scope)

      assert Notifications.list_notifiers(scope) == [notifier]
    end
  end

  describe "get_notifier/2" do
    test "does not leak another organization's notifier" do
      scope = organization_scope_fixture()
      other_scope = organization_scope_fixture()
      notifier = notifier_fixture(other_scope)

      assert Notifications.get_notifier(scope, notifier.id) == nil
      refute is_nil(Notifications.get_notifier(other_scope, notifier.id))
    end
  end

  describe "create_notifier/2" do
    test "creates a notifier owned by the scoped organization" do
      scope = organization_scope_fixture()

      assert {:ok, notifier} =
               Notifications.create_notifier(scope, %{
                 name: "On-call",
                 type: :email,
                 recipient: "oncall@example.com"
               })

      assert notifier.organization_id == scope.organization.id
      assert notifier.enabled == true
    end

    test "refuses a viewer" do
      viewer_scope = organization_scope_fixture(:viewer)

      assert {:error, :unauthorized} =
               Notifications.create_notifier(viewer_scope, valid_notifier_attributes())
    end
  end

  describe "update_notifier/3 and delete_notifier/2" do
    test "updates a notifier" do
      scope = organization_scope_fixture()
      notifier = notifier_fixture(scope)

      assert {:ok, updated} = Notifications.update_notifier(scope, notifier, %{enabled: false})
      assert updated.enabled == false
    end

    test "deletes a notifier" do
      scope = organization_scope_fixture()
      notifier = notifier_fixture(scope)

      assert {:ok, _deleted} = Notifications.delete_notifier(scope, notifier)
      assert Notifications.list_notifiers(scope) == []
    end

    test "refuses another organization's notifier" do
      scope = organization_scope_fixture()
      other_scope = organization_scope_fixture()
      notifier = notifier_fixture(other_scope)

      assert_raise MatchError, fn ->
        Notifications.update_notifier(scope, notifier, %{enabled: false})
      end

      assert_raise MatchError, fn ->
        Notifications.delete_notifier(scope, notifier)
      end
    end
  end

  describe "enqueue_incident_notifications/3" do
    test "queues one delivery job per enabled notifier" do
      scope = organization_scope_fixture()
      webhook = notifier_fixture(scope)
      email = notifier_fixture(scope, %{type: :email, recipient: "oncall@example.com"})
      notifier_fixture(scope, %{enabled: false})

      {:ok, incident} = open_incident(scope)

      assert_enqueued(worker: NotifyJob, args: job_args(webhook, incident, "opened"))
      assert_enqueued(worker: NotifyJob, args: job_args(email, incident, "opened"))
    end

    test "queues nothing when there are no enabled notifiers" do
      scope = organization_scope_fixture()
      notifier_fixture(scope, %{enabled: false})

      {:ok, incident} = open_incident(scope)

      assert :ok =
               Notifications.enqueue_incident_notifications(
                 scope.organization.id,
                 incident,
                 :opened
               )

      refute_enqueued(worker: NotifyJob)
    end

    test "an incident resolves enqueue a resolved event" do
      scope = organization_scope_fixture()
      notifier = notifier_fixture(scope)
      service = service_fixture(scope)

      {:ok, incident} = Incidents.open_incident(service, AlertRule.default())
      {:ok, _resolved} = Incidents.resolve_open_incident(service)

      assert_enqueued(worker: NotifyJob, args: job_args(notifier, incident, "opened"))
      assert_enqueued(worker: NotifyJob, args: job_args(notifier, incident, "resolved"))
    end
  end

  defp open_incident(scope) do
    service = service_fixture(scope)
    Incidents.open_incident(service, AlertRule.default())
  end

  defp job_args(notifier, incident, event) do
    %{
      "notifier_id" => notifier.id,
      "incident_id" => incident.id,
      "event" => event
    }
  end
end
