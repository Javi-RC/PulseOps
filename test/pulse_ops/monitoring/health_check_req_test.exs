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
end
