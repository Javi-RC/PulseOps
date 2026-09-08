defmodule PulseOps.Notifications.NotifyJobTest do
  use PulseOps.DataCase, async: true
  use Oban.Testing, repo: PulseOps.Repo

  import Swoosh.TestAssertions
  import PulseOps.MonitoringFixtures
  import PulseOps.NotificationsFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Incidents
  alias PulseOps.Monitoring.AlertRule
  alias PulseOps.Notifications.NotifyJob

  setup do
    scope = organization_scope_fixture()
    service = service_fixture(scope)
    {:ok, incident} = Incidents.open_incident(service, AlertRule.default())

    %{scope: scope, service: service, incident: incident}
  end

  describe "webhook deliveries" do
    test "posts the incident payload with the bearer token", %{
      scope: scope,
      service: service,
      incident: incident
    } do
      agent = start_supervised!({Agent, fn -> nil end})

      Req.Test.stub(:pulseops, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Agent.update(agent, fn _ -> {conn.req_headers, body} end)
        Plug.Conn.send_resp(conn, 200, "")
      end)

      notifier =
        notifier_fixture(scope, %{
          url: "https://hooks.example.com/pulseops",
          secret_token: "token-123"
        })

      assert :ok = perform_job(NotifyJob, job_args(notifier, incident, "opened"))

      {headers, body} = Agent.get(agent, & &1)

      assert {"authorization", "Bearer token-123"} in headers

      payload = Jason.decode!(body)
      assert payload["event"] == "opened"
      assert payload["incident"]["title"] == incident.title
      assert payload["incident"]["status"] == "open"
      assert payload["incident"]["severity"] == "medium"
      assert payload["service"]["name"] == service.name
      assert payload["organization"]["slug"] == scope.organization.slug

      assert payload["incident"]["url"] =~
               "/orgs/#{scope.organization.slug}/incidents/#{incident.id}"
    end

    test "a rejected payload is returned as an error so the job retries", %{
      scope: scope,
      incident: incident
    } do
      Req.Test.stub(:pulseops, fn conn ->
        Plug.Conn.send_resp(conn, 500, "nope")
      end)

      notifier = notifier_fixture(scope, %{url: "https://hooks.example.com/pulseops"})

      assert {:error, {:http_status, 500}} =
               perform_job(NotifyJob, job_args(notifier, incident, "resolved"))
    end
  end

  describe "email deliveries" do
    test "sends a plain text incident email", %{scope: scope, incident: incident} do
      drain_swoosh_mailbox()
      notifier = notifier_fixture(scope, %{type: :email, recipient: "oncall@example.com"})

      assert {:ok, _metadata} = perform_job(NotifyJob, job_args(notifier, incident, "opened"))

      assert_email_sent(fn email ->
        assert email.to == [{"", "oncall@example.com"}]
        assert email.subject == "[PulseOps] Incident opened: #{incident.title}"
        assert email.text_body =~ "An incident opened"
        assert email.text_body =~ incident.title
      end)
    end
  end

  describe "quiet cleanups" do
    test "a notifier deleted before the job ran is a no-op", %{incident: incident} do
      assert :ok =
               perform_job(NotifyJob, %{
                 "incident_id" => incident.id,
                 "notifier_id" => 999_999,
                 "event" => "opened"
               })
    end

    test "a paused notifier is a no-op", %{scope: scope, incident: incident} do
      notifier = notifier_fixture(scope, %{enabled: false})

      assert :ok = perform_job(NotifyJob, job_args(notifier, incident, "opened"))
    end

    test "an incident that no longer exists is a no-op", %{scope: scope} do
      notifier = notifier_fixture(scope)

      assert :ok =
               perform_job(NotifyJob, %{
                 "incident_id" => 999_999,
                 "notifier_id" => notifier.id,
                 "event" => "opened"
               })
    end
  end

  defp job_args(notifier, incident, event) do
    %{
      "notifier_id" => notifier.id,
      "incident_id" => incident.id,
      "event" => event
    }
  end

  # Account fixtures send a confirmation email into the test process mailbox;
  # drain it so the delivery assertion sees only the notifier email.
  defp drain_swoosh_mailbox do
    receive do
      {:email, _email} -> drain_swoosh_mailbox()
    after
      0 -> :ok
    end
  end
end
