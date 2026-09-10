defmodule PulseOpsWeb.ClientIpTest do
  # Not async: whether the proxy is trusted is application env.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias PulseOpsWeb.ClientIp

  setup do
    on_exit(fn -> Application.put_env(:pulse_ops, :trusted_proxy, false) end)
  end

  defp conn_forwarded_for(values) do
    Enum.reduce(values, conn(:post, "/"), &prepend_req_headers(&2, [{"x-forwarded-for", &1}]))
  end

  describe "without a trusted proxy" do
    setup do
      Application.put_env(:pulse_ops, :trusted_proxy, false)
    end

    test "X-Forwarded-For is ignored, because anyone can send it" do
      assert ClientIp.from_conn(conn_forwarded_for(["203.0.113.9"])) == nil
      assert ClientIp.from_x_headers([{"x-forwarded-for", "203.0.113.9"}]) == nil
    end
  end

  describe "behind a trusted proxy" do
    setup do
      Application.put_env(:pulse_ops, :trusted_proxy, true)
    end

    test "the address is the rightmost entry, the one our proxy appended" do
      # Everything to the left was sent by the client and can be anything.
      conn = conn_forwarded_for(["198.51.100.1, 203.0.113.9"])

      assert ClientIp.from_conn(conn) == "203.0.113.9"
    end

    test "reads the same from a LiveView's x_headers" do
      headers = [{"x-forwarded-for", "198.51.100.1, 203.0.113.9"}, {"x-request-id", "abc"}]

      assert ClientIp.from_x_headers(headers) == "203.0.113.9"
    end

    test "normalises IPv6 and ignores what is not an address" do
      assert ClientIp.from_conn(conn_forwarded_for(["2001:DB8::0:1"])) == "2001:db8::1"
      assert ClientIp.from_conn(conn_forwarded_for(["not-an-address"])) == nil
    end

    test "no header means no address to key on" do
      assert ClientIp.from_conn(conn(:post, "/")) == nil
      assert ClientIp.from_x_headers([]) == nil
    end
  end
end
