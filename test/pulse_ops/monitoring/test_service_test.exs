defmodule PulseOps.Monitoring.TestServiceTest do
  use PulseOps.DataCase, async: true

  import Mox
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.Check
  alias PulseOps.Monitoring.HealthCheck.Result
  alias PulseOps.Monitoring.HealthCheckMock
  alias PulseOps.Monitoring.Service

  setup :verify_on_exit!

  setup do
    %{scope: organization_scope_fixture()}
  end

  @service %Service{
    url: "https://payments.example.com/health",
    timeout_ms: 3_000,
    http_method: :post,
    request_headers: %{"X-Probe" => "pulseops"},
    request_body: ~s({"ping":true}),
    expected_status: 204,
    body_assertion: "ok"
  }

  describe "check_options/1" do
    test "carries every setting that shapes the request" do
      assert Monitoring.check_options(@service) == [
               timeout_ms: 3_000,
               method: :post,
               headers: [{"X-Probe", "pulseops"}],
               body: ~s({"ping":true}),
               expected_status: 204,
               body_assertion: "ok"
             ]
    end
  end

  describe "test_service/2" do
    test "probes the way the monitor would, and records nothing", %{scope: scope} do
      expect(HealthCheckMock, :check, fn url, opts ->
        assert url == @service.url
        assert opts == Monitoring.check_options(@service)
        {:ok, %Result{http_status: 204, response_time_ms: 12}}
      end)

      assert {:ok, %Result{http_status: 204}} = Monitoring.test_service(scope, @service)
      assert Repo.aggregate(Check, :count) == 0
    end

    test "reports a failure as an ordinary outcome", %{scope: scope} do
      expect(HealthCheckMock, :check, fn _url, _opts ->
        {:error,
         %Result{http_status: 503, response_time_ms: 40, error: "unexpected HTTP status 503"}}
      end)

      assert {:error, %Result{http_status: 503}} = Monitoring.test_service(scope, @service)
    end

    # Mox fails the test if the client is called at all, so this also proves no
    # request left for somebody who may not send one.
    test "needs the permission it takes to save a service", %{scope: scope} do
      assert Monitoring.test_service(%{scope | role: :viewer}, @service) ==
               {:error, :unauthorized}
    end
  end
end
