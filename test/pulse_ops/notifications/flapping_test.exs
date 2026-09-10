defmodule PulseOps.Notifications.FlappingTest do
  use PulseOps.DataCase, async: false
  use Oban.Testing, repo: PulseOps.Repo

  import PulseOps.MonitoringFixtures
  import PulseOps.NotificationsFixtures
  import PulseOps.OrganizationsFixtures
  import Swoosh.TestAssertions

  alias PulseOps.Incidents
  alias PulseOps.Monitoring.AlertRule
  alias PulseOps.Notifications.DigestJob
  alias PulseOps.Notifications.NotifyJob

  setup do
    scope = organization_scope_fixture()
    %{scope: scope, service: service_fixture(scope, %{name: "Payments API"})}
  end

  # Every fixture user that gets registered sends a confirmation email, so the
  # mailbox has to be emptied after the fixtures and before the assertion, not
  # once in setup.
  defp drain_emails do
    receive do
      {:email, _email} -> drain_emails()
    after
      0 -> :ok
    end
  end

  # Opens and immediately resolves an incident, which is one full oscillation.
  defp oscillate(service, times) do
    for _ <- 1..times do
      {:ok, _incident} = Incidents.open_incident(service, AlertRule.default(), "down")
      announce_incident_events()
      {:ok, _resolved} = Incidents.resolve_open_incident(service)
      announce_incident_events()
    end
  end

  describe "flapping?/2" do
    test "a service that has moved once is not flapping", %{service: service} do
      oscillate(service, 1)

      refute Incidents.flapping?(service)
    end

    test "crossing the threshold makes it a flapper", %{service: service} do
      # The default threshold is three incidents inside the window.
      oscillate(service, 3)

      assert Incidents.flapping?(service)
    end

    test "only counts what happened inside the window", %{service: service} do
      oscillate(service, 3)
      assert Incidents.flapping?(service)

      # An hour later, the same three are long outside a ten-minute window.
      later = DateTime.add(DateTime.utc_now(), 3600, :second)
      refute Incidents.flapping?(service, later)
    end

    test "another service's transitions do not count", %{scope: scope, service: service} do
      other = service_fixture(scope, %{name: "Search"})
      oscillate(other, 5)

      refute Incidents.flapping?(service)
    end
  end

  describe "what a flapping service sends" do
    test "one digest instead of a message per transition", %{scope: scope, service: service} do
      notifier_fixture(scope)

      # The first two crossings are ordinary incidents and notify normally.
      oscillate(service, 2)
      refute_enqueued(worker: DigestJob)

      # The third makes it a flapper, and from here the storm becomes a digest.
      {:ok, _incident} = Incidents.open_incident(service, AlertRule.default(), "down")
      announce_incident_events()

      assert_enqueued(worker: DigestJob, args: %{"service_id" => service.id})
    end

    test "further transitions collapse into the digest already scheduled", %{
      scope: scope,
      service: service
    } do
      notifier_fixture(scope)
      oscillate(service, 3)

      # Six more crossings, all while a digest is waiting.
      oscillate(service, 6)

      digests = all_enqueued(worker: DigestJob)

      # Oban's uniqueness is what makes this true: without it this is ten jobs.
      assert length(digests) == 1
    end

    test "and no per-incident notification is queued while flapping", %{
      scope: scope,
      service: service
    } do
      notifier_fixture(scope)
      oscillate(service, 3)

      # Everything queued so far belongs to the two ordinary crossings.
      before = length(all_enqueued(worker: NotifyJob))

      {:ok, _incident} = Incidents.open_incident(service, AlertRule.default(), "down")
      announce_incident_events()

      assert length(all_enqueued(worker: NotifyJob)) == before
    end
  end

  describe "the digest itself" do
    test "says how often the service moved, in one email", %{scope: scope, service: service} do
      notifier_fixture(scope, %{type: :email, assignee_ids: [assignee_id_fixture(scope)]})
      oscillate(service, 4)
      drain_emails()

      assert :ok =
               perform_job(DigestJob, %{
                 "service_id" => service.id,
                 "organization_id" => scope.organization.id
               })

      assert_email_sent(fn email ->
        assert email.subject =~ "Payments API is flapping"
        assert email.text_body =~ "4 times"
        # A digest is one message about many transitions, and says so.
        assert email.text_body =~ "instead of 4"
      end)
    end

    test "counts when it runs, not when it was scheduled", %{scope: scope, service: service} do
      notifier_fixture(scope, %{type: :email, assignee_ids: [assignee_id_fixture(scope)]})
      oscillate(service, 3)

      # Two more arrive while the job waits; the message has to describe what
      # actually happened, not what had happened when it was queued.
      oscillate(service, 2)
      drain_emails()

      perform_job(DigestJob, %{
        "service_id" => service.id,
        "organization_id" => scope.organization.id
      })

      assert_email_sent(fn email -> assert email.text_body =~ "5 times" end)
    end

    test "is quiet when the service is gone", %{scope: scope} do
      assert :ok =
               perform_job(DigestJob, %{
                 "service_id" => 0,
                 "organization_id" => scope.organization.id
               })
    end

    test "is not sent to an escalation-only channel", %{scope: scope, service: service} do
      notifier_fixture(scope, %{
        type: :email,
        escalation_only: true,
        assignee_ids: [assignee_id_fixture(scope)]
      })

      oscillate(service, 3)
      drain_emails()

      perform_job(DigestJob, %{
        "service_id" => service.id,
        "organization_id" => scope.organization.id
      })

      refute_email_sent()
    end
  end
end
