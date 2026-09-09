defmodule PulseOps.Notifications.TlsWarningJobTest do
  use PulseOps.DataCase, async: false
  use Oban.Testing, repo: PulseOps.Repo

  import PulseOps.MonitoringFixtures
  import PulseOps.NotificationsFixtures
  import PulseOps.OrganizationsFixtures
  import Swoosh.TestAssertions

  alias PulseOps.Notifications
  alias PulseOps.Notifications.TlsWarningJob

  setup do
    scope = organization_scope_fixture()

    service =
      scope
      |> service_fixture(%{name: "Payments API", url: "https://api.example.com/health"})
      |> with_expiry(9)

    %{scope: scope, service: service}
  end

  defp with_expiry(service, days) do
    service
    |> Ecto.Changeset.change(
      tls_expires_at: DateTime.add(DateTime.utc_now(:second), days * 86_400, :second),
      tls_checked_at: DateTime.utc_now(:second)
    )
    |> Repo.update!()
  end

  defp drain_emails do
    receive do
      {:email, _email} -> drain_emails()
    after
      0 -> :ok
    end
  end

  describe "email delivery" do
    test "says which service and how long is left", %{scope: scope, service: service} do
      notifier =
        notifier_fixture(scope, %{type: :email, assignee_ids: [assignee_id_fixture(scope)]})

      drain_emails()

      assert {:ok, _metadata} =
               perform_job(TlsWarningJob, %{
                 "notifier_id" => notifier.id,
                 "service_id" => service.id,
                 "days_left" => 9
               })

      assert_email_sent(fn email ->
        assert email.subject =~ "Payments API"
        assert email.subject =~ "expires in 8 days" or email.subject =~ "expires in 9 days"
        # An expiring certificate is not an outage, and the message says so
        # rather than reading like a page.
        assert email.text_body =~ "Nothing is wrong with the service right now"
      end)
    end

    test "reads differently once it has already expired", %{scope: scope, service: service} do
      service = with_expiry(service, -3)

      notifier =
        notifier_fixture(scope, %{type: :email, assignee_ids: [assignee_id_fixture(scope)]})

      drain_emails()

      perform_job(TlsWarningJob, %{
        "notifier_id" => notifier.id,
        "service_id" => service.id,
        "days_left" => -3
      })

      assert_email_sent(fn email ->
        assert email.subject =~ "has expired"
        assert email.text_body =~ "expired"
      end)
    end

    test "recomputes the days rather than trusting a stale argument", %{
      scope: scope,
      service: service
    } do
      notifier =
        notifier_fixture(scope, %{type: :email, assignee_ids: [assignee_id_fixture(scope)]})

      drain_emails()

      # A job that sat in a retry backlog overnight would otherwise announce a
      # number that is a day stale.
      perform_job(TlsWarningJob, %{
        "notifier_id" => notifier.id,
        "service_id" => service.id,
        "days_left" => 400
      })

      assert_email_sent(fn email ->
        refute email.subject =~ "400"
        assert email.subject =~ "expires in"
      end)
    end
  end

  describe "when there is nothing to deliver" do
    test "a deleted notifier is quiet", %{service: service} do
      assert :ok =
               perform_job(TlsWarningJob, %{
                 "notifier_id" => 0,
                 "service_id" => service.id,
                 "days_left" => 5
               })
    end

    test "a paused notifier is quiet", %{scope: scope, service: service} do
      notifier =
        notifier_fixture(scope, %{
          type: :email,
          enabled: false,
          assignee_ids: [assignee_id_fixture(scope)]
        })

      drain_emails()

      assert :ok =
               perform_job(TlsWarningJob, %{
                 "notifier_id" => notifier.id,
                 "service_id" => service.id,
                 "days_left" => 5
               })

      refute_email_sent()
    end

    test "a deleted service is quiet", %{scope: scope} do
      notifier = notifier_fixture(scope, %{type: :email})

      assert :ok =
               perform_job(TlsWarningJob, %{
                 "notifier_id" => notifier.id,
                 "service_id" => 0,
                 "days_left" => 5
               })
    end
  end

  describe "webhook delivery" do
    setup do
      Req.Test.set_req_test_from_context(%{async: false})
      :ok
    end

    test "posts a payload a receiver can route on", %{scope: scope, service: service} do
      notifier = notifier_fixture(scope, %{type: :webhook})
      test_pid = self()

      Req.Test.stub(:pulseops, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:payload, Jason.decode!(body)})
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert :ok =
               perform_job(TlsWarningJob, %{
                 "notifier_id" => notifier.id,
                 "service_id" => service.id,
                 "days_left" => 9
               })

      assert_receive {:payload, payload}
      # A distinct event, so a receiver can route it differently from an outage.
      assert payload["event"] == "tls_expiring"
      assert payload["service"]["name"] == "Payments API"
      assert payload["expires_at"]
      assert payload["days_left"] in [8, 9]
    end
  end

  describe "enqueueing" do
    test "one job per matching channel", %{scope: scope, service: service} do
      one = notifier_fixture(scope, %{name: "One"})
      two = notifier_fixture(scope, %{name: "Two"})

      assert :ok = Notifications.enqueue_tls_warning(service, 9)

      assert_enqueued(worker: TlsWarningJob, args: %{"notifier_id" => one.id})
      assert_enqueued(worker: TlsWarningJob, args: %{"notifier_id" => two.id})
    end

    test "nothing at all when the organization has no channels", %{service: service} do
      assert :ok = Notifications.enqueue_tls_warning(service, 9)

      refute_enqueued(worker: TlsWarningJob)
    end
  end
end
