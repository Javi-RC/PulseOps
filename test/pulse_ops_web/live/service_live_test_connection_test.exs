defmodule PulseOpsWeb.ServiceLive.TestConnectionTest do
  # Not async: the probe runs in a task the LiveView starts, so the mock has to
  # answer calls from a process this test does not own.
  use PulseOpsWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias PulseOps.Monitoring.HealthCheck.Result
  alias PulseOps.Monitoring.HealthCheckMock
  alias PulseOps.Organizations.Membership
  alias PulseOps.Repo

  setup :set_mox_global
  setup :verify_on_exit!
  setup :register_and_log_in_user_with_org

  @service_attrs %{
    name: "Payments API",
    url: "https://payments.example.com/health",
    check_interval_seconds: 30,
    timeout_seconds: 5
  }

  defp new_service_form(conn, scope, attrs \\ @service_attrs) do
    {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/services/new")
    live |> form("#service-form", service: attrs) |> render_change()
    live
  end

  defp test_connection(live) do
    live |> element("#test-connection") |> render_click()
    render_async(live)
  end

  test "says the URL answers, and how fast", %{conn: conn, scope: scope} do
    expect(HealthCheckMock, :check, fn _url, _opts ->
      {:ok, %Result{http_status: 200, response_time_ms: 84}}
    end)

    live = new_service_form(conn, scope)
    test_connection(live)

    assert has_element?(live, "#connection-test", "It answers.")
    assert has_element?(live, "#connection-test", "HTTP 200 in 84 ms")
  end

  test "says why the check would fail", %{conn: conn, scope: scope} do
    expect(HealthCheckMock, :check, fn _url, _opts ->
      {:error,
       %Result{http_status: 503, response_time_ms: 80, error: "unexpected HTTP status 503"}}
    end)

    live = new_service_form(conn, scope)
    test_connection(live)

    assert has_element?(live, "#connection-test", "This check would fail.")
    assert has_element?(live, "#connection-test", "Unexpected HTTP status 503, after 80 ms.")
  end

  test "sends what the form says now, before anything is saved", %{conn: conn, scope: scope} do
    test_pid = self()

    expect(HealthCheckMock, :check, fn url, opts ->
      send(test_pid, {:probed, url, opts})
      {:ok, %Result{http_status: 200, response_time_ms: 5}}
    end)

    live =
      new_service_form(
        conn,
        scope,
        Map.merge(@service_attrs, %{
          url: "https://payments.example.com/healthz",
          http_method: :post,
          request_headers_text: "X-Probe: pulseops"
        })
      )

    test_connection(live)

    assert_receive {:probed, "https://payments.example.com/healthz", opts}
    assert opts[:method] == :post
    assert opts[:headers] == [{"X-Probe", "pulseops"}]
    assert opts[:timeout_ms] == 5_000
    assert PulseOps.Monitoring.list_services(scope) == []
  end

  test "sends nothing while a field the request depends on is wrong", %{
    conn: conn,
    scope: scope
  } do
    expect(HealthCheckMock, :check, 0, fn _url, _opts -> flunk("no request should be sent") end)

    live = new_service_form(conn, scope, %{@service_attrs | url: "not a url"})
    live |> element("#test-connection") |> render_click()

    assert has_element?(live, "#connection-test", "Fix the highlighted fields first")
  end

  test "forgets a result once the URL is changed", %{conn: conn, scope: scope} do
    expect(HealthCheckMock, :check, fn _url, _opts ->
      {:ok, %Result{http_status: 200, response_time_ms: 84}}
    end)

    live = new_service_form(conn, scope)
    test_connection(live)
    assert has_element?(live, "#connection-test", "It answers.")

    live
    |> form("#service-form",
      service: %{@service_attrs | url: "https://payments.example.com/other"}
    )
    |> render_change()

    refute has_element?(live, "#connection-test", "It answers.")
  end

  test "a viewer cannot use it to make PulseOps send requests", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    expect(HealthCheckMock, :check, 0, fn _url, _opts -> flunk("no request should be sent") end)

    Repo.get_by!(Membership, organization_id: scope.organization.id, user_id: user.id)
    |> Ecto.Changeset.change(role: :viewer)
    |> Repo.update!()

    live = new_service_form(conn, scope)
    test_connection(live)

    assert has_element?(live, "#connection-test", "You do not have permission to test services.")
  end
end
