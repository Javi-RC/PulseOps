defmodule PulseOps.Monitoring.HealthCheck.ReqTest do
  # Not async: UrlGuard reads application-wide config.
  use ExUnit.Case, async: false

  alias PulseOps.Monitoring.HealthCheck.Req, as: Client
  alias PulseOps.Monitoring.HealthCheck.Result

  setup do
    Req.Test.set_req_test_from_context(%{async: false})
    :ok
  end

  defp stub(fun), do: Req.Test.stub(:health_check, fun)

  describe "mapping a response to a result" do
    test "a 2xx is a success carrying the status and a response time" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end)

      assert {:ok, %Result{http_status: 200, response_time_ms: ms, error: nil}} =
               Client.check("https://8.8.8.8/health")

      assert is_integer(ms) and ms >= 0
    end

    test "a non-2xx is a failure that says which status it was" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 503, "nope") end)

      assert {:error, %Result{http_status: 503, error: error}} =
               Client.check("https://8.8.8.8/health")

      assert error =~ "503"
    end

    test "a transport error is a failure carrying the reason" do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Result{http_status: nil, error: error}} =
               Client.check("https://8.8.8.8/health")

      assert error =~ "connection refused" or error =~ "econnrefused"
    end
  end

  describe "the SSRF guard runs before the request" do
    setup do
      Application.put_env(:pulse_ops, :allow_private_targets, false)
      on_exit(fn -> Application.put_env(:pulse_ops, :allow_private_targets, true) end)
    end

    test "a private target is refused without any request being made" do
      # No stub is installed: if the guard let this through, the request would
      # fail for the wrong reason and this test would say so.
      stub(fn _conn -> raise "the request must not be attempted" end)

      assert {:error, %Result{error: error}} = Client.check("http://169.254.169.254/latest/")
      assert error =~ "blocked target"
      assert error =~ "private"
    end

    test "a bad scheme is refused" do
      assert {:error, %Result{error: error}} = Client.check("file:///etc/passwd")
      assert error =~ "blocked target"
    end

    test "a public target still goes through" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end)
      assert {:ok, %Result{http_status: 200}} = Client.check("https://8.8.8.8/health")
    end
  end

  describe "request options" do
    test "sends the configured method" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, conn.method) end)

      assert {:ok, %Result{}} = Client.check("https://8.8.8.8/health", method: :head)
      assert {:ok, %Result{}} = Client.check("https://8.8.8.8/health", method: :post)
    end

    test "sends the configured headers" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert {:ok, _result} =
               Client.check("https://8.8.8.8/health",
                 headers: [{"authorization", "Bearer sekret"}, {"x-probe", "pulseops"}]
               )

      assert_receive {:headers, headers}
      assert {"authorization", "Bearer sekret"} in headers
      assert {"x-probe", "pulseops"} in headers
    end

    test "sends a request body when there is one" do
      test_pid = self()

      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, body})
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert {:ok, _result} =
               Client.check("https://8.8.8.8/health", method: :post, body: ~s({"ping":true}))

      assert_receive {:body, ~s({"ping":true})}
    end
  end

  describe "expected_status" do
    test "a status other than the expected one fails, even a 2xx" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end)

      assert {:error, %Result{http_status: 200, error: error}} =
               Client.check("https://8.8.8.8/health", expected_status: 204)

      assert error =~ "expected HTTP status 204, got 200"
    end

    test "a non-2xx passes when that is what was asked for" do
      # An endpoint that proves it is alive by refusing an unauthenticated
      # request is a real health check, and a bare 2xx rule cannot express it.
      stub(fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end)

      assert {:ok, %Result{http_status: 401}} =
               Client.check("https://8.8.8.8/health", expected_status: 401)
    end

    test "without it, any 2xx is still healthy" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 204, "") end)

      assert {:ok, %Result{http_status: 204}} = Client.check("https://8.8.8.8/health")
    end
  end

  describe "body_assertion" do
    test "catches a service that is up and saying it is not well" do
      # The failure a status code cannot see.
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, ~s({"status":"degraded"})) end)

      assert {:error, %Result{http_status: 200, error: error}} =
               Client.check("https://8.8.8.8/health", body_assertion: ~s("status":"ok"))

      assert error =~ "did not contain"
    end

    test "passes when the text is there" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, ~s({"status":"ok","db":"up"})) end)

      assert {:ok, %Result{http_status: 200}} =
               Client.check("https://8.8.8.8/health", body_assertion: ~s("status":"ok"))
    end

    test "an unexpected status is reported as such, not as a missing string" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

      assert {:error, %Result{error: error}} =
               Client.check("https://8.8.8.8/health", body_assertion: "ok")

      assert error =~ "unexpected HTTP status 503"
      refute error =~ "did not contain"
    end
  end
end
