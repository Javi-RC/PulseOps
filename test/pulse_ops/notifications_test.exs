defmodule PulseOps.NotificationsTest do
  use PulseOps.DataCase, async: true
  use Oban.Testing, repo: PulseOps.Repo

  import PulseOps.MonitoringFixtures
  import PulseOps.NotificationsFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Incidents
  alias PulseOps.Maintenance
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

  describe "a webhook's secret token" do
    setup do
      scope = organization_scope_fixture()
      notifier = notifier_fixture(scope, %{secret_token: "a-recognisable-token"})
      %{scope: scope, notifier: notifier}
    end

    test "is encrypted in the database and read back in the clear", %{
      scope: scope,
      notifier: notifier
    } do
      %{rows: [[stored]]} =
        PulseOps.Repo.query!("SELECT secret_token FROM notifiers WHERE id = $1", [notifier.id])

      refute stored =~ "a-recognisable-token"
      assert Notifications.get_notifier(scope, notifier.id).secret_token == "a-recognisable-token"
    end

    test "does not appear when the notifier is inspected", %{notifier: notifier} do
      refute inspect(notifier) =~ "a-recognisable-token"
    end

    test "is kept when an update leaves it blank", %{scope: scope, notifier: notifier} do
      {:ok, _} = Notifications.update_notifier(scope, notifier, %{"secret_token" => ""})

      assert PulseOps.Repo.reload!(notifier).secret_token == "a-recognisable-token"
    end

    test "is replaced when an update supplies a new one", %{scope: scope, notifier: notifier} do
      {:ok, _} = Notifications.update_notifier(scope, notifier, %{"secret_token" => "rotated"})

      assert PulseOps.Repo.reload!(notifier).secret_token == "rotated"
    end

    test "is removed only when asked to", %{scope: scope, notifier: notifier} do
      {:ok, _} = Notifications.update_notifier(scope, notifier, %{"clear_secret_token" => "true"})

      assert PulseOps.Repo.reload!(notifier).secret_token == nil
    end
  end

  describe "create_notifier/2" do
    test "creates a notifier owned by the scoped organization" do
      scope = organization_scope_fixture()

      assert {:ok, notifier} =
               Notifications.create_notifier(scope, %{
                 name: "On-call",
                 type: :email
               })

      assert notifier.organization_id == scope.organization.id
      assert notifier.enabled == true
      assert notifier.assigned_users == []
    end

    test "creates a notifier with its assigned users" do
      scope = organization_scope_fixture()
      user_a = assignee_id_fixture(scope)
      user_b = assignee_id_fixture(scope)

      {:ok, notifier} =
        Notifications.create_notifier(scope, %{
          name: "On-call",
          type: :email,
          assignee_ids: [user_a, user_b]
        })

      assert notifier.assigned_users |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([user_a, user_b])
    end

    test "refuses a viewer" do
      viewer_scope = organization_scope_fixture(:viewer)

      assert {:error, :unauthorized} =
               Notifications.create_notifier(viewer_scope, valid_notifier_attributes())
    end
  end

  describe "update_notifier/3 and delete_notifier/2" do
    test "updates a notifier and its assignments" do
      scope = organization_scope_fixture()
      user = assignee_id_fixture(scope)
      notifier = notifier_fixture(scope)

      assert {:ok, updated} =
               Notifications.update_notifier(scope, notifier, %{
                 enabled: false,
                 assignee_ids: [user]
               })

      assert updated.enabled == false
      assert updated.assigned_users |> Enum.map(& &1.id) == [user]
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
      email = notifier_fixture(scope, %{type: :email})
      notifier_fixture(scope, %{enabled: false})

      {:ok, incident} = open_incident(scope)

      assert_enqueued(worker: NotifyJob, args: job_args(webhook, incident, "opened"))
      assert_enqueued(worker: NotifyJob, args: job_args(email, incident, "opened"))
    end

    test "only fires notifiers narrowed to the incident's service" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)
      other_service = service_fixture(scope)

      targeted = notifier_fixture(scope, %{service_id: service.id})
      other_targeted = notifier_fixture(scope, %{service_id: other_service.id})
      org_wide = notifier_fixture(scope)

      {:ok, incident} = Incidents.open_incident(service, AlertRule.default())

      assert_enqueued(worker: NotifyJob, args: job_args(targeted, incident, "opened"))
      assert_enqueued(worker: NotifyJob, args: job_args(org_wide, incident, "opened"))

      refute_enqueued(
        worker: NotifyJob,
        args: job_args(other_targeted, incident, "opened")
      )
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

  describe "notifications during a maintenance window" do
    setup do
      %{scope: organization_scope_fixture()}
    end

    test "nobody is paged for a deploy somebody scheduled", %{scope: scope} do
      service = service_fixture(scope)
      notifier_fixture(scope)

      {:ok, _window} =
        Maintenance.create_window(scope, %{
          reason: "Deploying",
          starts_at: DateTime.add(DateTime.utc_now(:second), -60, :second),
          ends_at: DateTime.add(DateTime.utc_now(:second), 1800, :second)
        })

      assert Incidents.open_incident(service, AlertRule.default(), "down") == {:ok, :suppressed}

      # The suppression is not a second rule about notifications: no incident
      # opened, so there was nothing to announce.
      refute_enqueued(worker: NotifyJob)
    end

    test "and is paged normally once it has ended", %{scope: scope} do
      service = service_fixture(scope)
      notifier = notifier_fixture(scope)

      {:ok, _window} =
        Maintenance.create_window(scope, %{
          reason: "Finished",
          starts_at: DateTime.add(DateTime.utc_now(:second), -3600, :second),
          ends_at: DateTime.add(DateTime.utc_now(:second), -60, :second)
        })

      assert {:ok, incident} = Incidents.open_incident(service, AlertRule.default(), "down")

      assert_enqueued(worker: NotifyJob, args: job_args(notifier, incident, "opened"))
    end

    test "a recovery during a window is still announced", %{scope: scope} do
      service = service_fixture(scope)
      notifier = notifier_fixture(scope)

      # The incident opened before the window, from a real outage.
      {:ok, incident} = Incidents.open_incident(service, AlertRule.default(), "down")

      {:ok, _window} =
        Maintenance.create_window(scope, %{
          reason: "Deploying",
          starts_at: DateTime.add(DateTime.utc_now(:second), -60, :second),
          ends_at: DateTime.add(DateTime.utc_now(:second), 1800, :second)
        })

      {:ok, _resolved} = Incidents.resolve_open_incident(service)

      # Telling people something recovered is not a page in the night, and
      # leaving it out would make the timeline lie.
      assert_enqueued(worker: NotifyJob, args: job_args(notifier, incident, "resolved"))
    end
  end
end
