defmodule PulseOpsWeb.MetricsControllerTest do
  # Not async: :metrics_token is application-wide.
  use PulseOpsWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:pulse_ops, :metrics_token)
    on_exit(fn -> Application.put_env(:pulse_ops, :metrics_token, previous) end)
    :ok
  end

  describe "without a configured token" do
    test "the endpoint does not exist", %{conn: conn} do
      Application.delete_env(:pulse_ops, :metrics_token)

      conn = get(conn, ~p"/metrics")

      # 404 rather than 401: an installation with no metrics configured should
      # not advertise that it has any.
      assert response(conn, 404)
    end
  end

  describe "with a configured token" do
    setup do
      Application.put_env(:pulse_ops, :metrics_token, "scrape-me")
      :ok
    end

    test "rejects a request with no token", %{conn: conn} do
      assert response(get(conn, ~p"/metrics"), 401)
    end

    test "rejects a wrong token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong")
        |> get(~p"/metrics")

      assert response(conn, 401)
    end

    test "rejects a token that is only a prefix of the real one", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer scrape")
        |> get(~p"/metrics")

      assert response(conn, 401)
    end

    test "serves the exposition format to a correct token", %{conn: conn} do
      # The reporter only exposes a metric once its event has fired, so emit the
      # probe event first. This is also what proves it is wired to a metric at
      # all: before this phase it was emitted and heard by nobody.
      :telemetry.execute(
        [:pulse_ops, :monitoring, :check],
        %{response_time_ms: 42},
        %{service_id: 1, status: :healthy}
      )

      conn =
        conn
        |> put_req_header("authorization", "Bearer scrape-me")
        |> get(~p"/metrics")

      body = response(conn, 200)
      assert response_content_type(conn, :text) =~ "text/plain"

      assert body =~ "pulse_ops_monitoring_check_count"
      assert body =~ ~s(status="healthy")
      # The histogram the response time lands in.
      assert body =~ "pulse_ops_monitoring_check_response_time_ms_bucket"
    end

    test "does not label metrics with a service id", %{conn: conn} do
      :telemetry.execute(
        [:pulse_ops, :monitoring, :check],
        %{response_time_ms: 42},
        %{service_id: 12_345, status: :healthy}
      )

      body =
        conn
        |> put_req_header("authorization", "Bearer scrape-me")
        |> get(~p"/metrics")
        |> response(200)

      # Cardinality would otherwise grow with every tenant's every service.
      # Per-service figures live in the database, not in Prometheus.
      refute body =~ "12345"
      refute body =~ "service_id"
    end
  end
end
