defmodule PulseOps.Monitoring.TlsJobTest do
  use PulseOps.DataCase, async: false
  use Oban.Testing, repo: PulseOps.Repo

  import Mox
  import PulseOps.MonitoringFixtures
  import PulseOps.NotificationsFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.TlsCheckMock
  alias PulseOps.Monitoring.TlsJob
  alias PulseOps.Notifications.TlsWarningJob

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    %{scope: organization_scope_fixture()}
  end

  defp https_service(scope, attrs \\ %{}) do
    service_fixture(scope, Enum.into(attrs, %{url: "https://api.example.com/health"}))
  end

  defp expires_in(days) do
    DateTime.add(DateTime.utc_now(:second), days * 86_400, :second)
  end

  defp stub_certificate(expires_at) do
    stub(TlsCheckMock, :certificate, fn _url, _opts ->
      {:ok, %{expires_at: expires_at, issuer: "Test CA"}}
    end)
  end

  describe "which services are looked at" do
    test "only https ones", %{scope: scope} do
      https = https_service(scope, %{name: "Secure"})
      service_fixture(scope, %{name: "Plain", url: "http://api.example.com/health"})

      # There is no certificate behind an http URL, and asking would produce an
      # error a person would have to learn to ignore.
      assert Enum.map(Monitoring.list_services_for_tls_check(), & &1.id) == [https.id]
    end

    test "only enabled ones", %{scope: scope} do
      enabled = https_service(scope, %{name: "Watched"})
      https_service(scope, %{name: "Paused", enabled: false})

      assert Enum.map(Monitoring.list_services_for_tls_check(), & &1.id) == [enabled.id]
    end
  end

  describe "recording what it found" do
    test "stores the expiry and clears any previous error", %{scope: scope} do
      service = https_service(scope)
      expires_at = expires_in(90)
      stub_certificate(expires_at)

      assert {:ok, 1} = perform_job(TlsJob, %{})

      reloaded = Repo.reload!(service)
      assert DateTime.compare(reloaded.tls_expires_at, expires_at) == :eq
      assert reloaded.tls_checked_at
      assert reloaded.tls_error == nil
    end

    test "records a failure without losing the last known expiry", %{scope: scope} do
      service = https_service(scope)
      stub_certificate(expires_in(90))
      perform_job(TlsJob, %{})

      stub(TlsCheckMock, :certificate, fn _url, _opts -> {:error, "connection refused"} end)
      perform_job(TlsJob, %{})

      reloaded = Repo.reload!(service)
      # A failed handshake today does not mean the certificate stopped existing.
      assert reloaded.tls_expires_at
      assert reloaded.tls_error == "connection refused"
    end
  end

  describe "warning" do
    test "says nothing about a certificate with months left", %{scope: scope} do
      https_service(scope)
      notifier_fixture(scope)
      stub_certificate(expires_in(90))

      perform_job(TlsJob, %{})

      refute_enqueued(worker: TlsWarningJob)
    end

    test "warns once inside the window", %{scope: scope} do
      service = https_service(scope)
      notifier = notifier_fixture(scope)
      stub_certificate(expires_in(10))

      perform_job(TlsJob, %{})

      assert_enqueued(
        worker: TlsWarningJob,
        args: %{"notifier_id" => notifier.id, "service_id" => service.id}
      )
    end

    test "and not again the next day for the same expiry", %{scope: scope} do
      https_service(scope)
      notifier_fixture(scope)
      stub_certificate(expires_in(10))

      perform_job(TlsJob, %{})
      before = length(all_enqueued(worker: TlsWarningJob))

      # The sweep runs again tomorrow, and the day after.
      perform_job(TlsJob, %{})
      perform_job(TlsJob, %{})

      assert length(all_enqueued(worker: TlsWarningJob)) == before
    end

    test "warns again once the certificate is renewed and running out anew", %{scope: scope} do
      https_service(scope)
      notifier_fixture(scope)

      stub_certificate(expires_in(10))
      perform_job(TlsJob, %{})
      first = length(all_enqueued(worker: TlsWarningJob))

      # Renewed: a different expiry, and later on it is close again. Recording
      # *which* expiry was warned about is what makes this possible; a boolean
      # would have gone quiet for ever.
      stub_certificate(expires_in(15))
      perform_job(TlsJob, %{})

      assert length(all_enqueued(worker: TlsWarningJob)) > first
    end

    test "warns about one that has already expired", %{scope: scope} do
      https_service(scope)
      notifier_fixture(scope)
      stub_certificate(expires_in(-2))

      perform_job(TlsJob, %{})

      assert_enqueued(worker: TlsWarningJob)
    end

    test "an escalation-only channel is not told", %{scope: scope} do
      https_service(scope)
      notifier_fixture(scope, %{escalation_only: true})
      stub_certificate(expires_in(5))

      perform_job(TlsJob, %{})

      refute_enqueued(worker: TlsWarningJob)
    end
  end

  describe "helpers" do
    test "days left, and whether that is worth saying", %{scope: scope} do
      service = https_service(scope)
      stub_certificate(expires_in(30))
      perform_job(TlsJob, %{})

      reloaded = Repo.reload!(service)

      assert Monitoring.tls_days_left(reloaded) in 29..30
      refute Monitoring.tls_expiring?(reloaded)
    end

    test "a service never checked has nothing to say", %{scope: scope} do
      service = https_service(scope)

      assert Monitoring.tls_days_left(service) == nil
      refute Monitoring.tls_expiring?(service)
    end
  end
end
