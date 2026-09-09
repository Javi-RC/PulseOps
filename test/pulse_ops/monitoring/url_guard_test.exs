defmodule PulseOps.Monitoring.UrlGuardTest do
  # Not async: :allow_private_targets is application-wide, and flipping it while
  # another module's fixtures are saving a service URL fails their validation.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias PulseOps.Monitoring.UrlGuard

  setup do
    # The suite as a whole allows private targets, because its fixtures point at
    # hosts that do not resolve. These tests are the ones that exercise the
    # guard, so they turn it on.
    Application.put_env(:pulse_ops, :allow_private_targets, false)
    on_exit(fn -> Application.put_env(:pulse_ops, :allow_private_targets, true) end)
  end

  describe "scheme" do
    test "rejects anything that is not http or https" do
      for url <- [
            "ftp://example.com/",
            "file:///etc/passwd",
            "gopher://example.com/",
            "redis://10.0.0.1:6379",
            "//example.com/",
            "not a url",
            "",
            nil,
            :bad
          ] do
        assert UrlGuard.validate(url) == {:error, :invalid_scheme}, "allowed #{inspect(url)}"
      end
    end
  end

  describe "private and internal addresses" do
    test "rejects loopback" do
      assert UrlGuard.validate("http://127.0.0.1/") == {:error, :private_address}
      assert UrlGuard.validate("http://127.0.0.1:5432/") == {:error, :private_address}
      assert UrlGuard.validate("https://[::1]/") == {:error, :private_address}
    end

    test "rejects the cloud metadata endpoint" do
      # The one that turns "monitor my service" into "read my instance's
      # credentials".
      assert UrlGuard.validate("http://169.254.169.254/latest/meta-data/") ==
               {:error, :private_address}
    end

    test "rejects the RFC 1918 ranges" do
      for url <- ["http://10.0.0.1/", "http://172.16.0.1/", "http://192.168.1.1/"] do
        assert UrlGuard.validate(url) == {:error, :private_address}, "allowed #{url}"
      end
    end

    test "rejects unique-local and link-local IPv6" do
      assert UrlGuard.validate("http://[fc00::1]/") == {:error, :private_address}
      assert UrlGuard.validate("http://[fd12:3456::1]/") == {:error, :private_address}
      assert UrlGuard.validate("http://[fe80::1]/") == {:error, :private_address}
      assert UrlGuard.validate("http://[::]/") == {:error, :private_address}
    end

    test "rejects a private IPv4 wrapped in an IPv6 address" do
      # ::ffff:127.0.0.1 reaches loopback while looking nothing like it.
      assert UrlGuard.validate("http://[::ffff:127.0.0.1]/") == {:error, :private_address}
      assert UrlGuard.validate("http://[::ffff:169.254.169.254]/") == {:error, :private_address}
      assert UrlGuard.validate("http://[64:ff9b::10.0.0.1]/") == {:error, :private_address}
    end

    test "rejects multicast, reserved and broadcast" do
      for url <- ["http://224.0.0.1/", "http://240.0.0.1/", "http://255.255.255.255/"] do
        assert UrlGuard.validate(url) == {:error, :private_address}, "allowed #{url}"
      end
    end

    test "rejects a name that resolves to a private address" do
      # localhost is the name form of the same attack, and resolves without a
      # network round trip.
      assert UrlGuard.validate("http://localhost:4000/health") == {:error, :private_address}
    end

    test "rejects a host that resolves to nothing rather than failing open" do
      assert UrlGuard.validate("https://this-name-does-not-exist.invalid/") ==
               {:error, :unresolvable}
    end

    test "accepts a public address" do
      assert UrlGuard.validate("https://8.8.8.8/") == :ok
      assert UrlGuard.validate("http://93.184.216.34/health") == :ok
      assert UrlGuard.validate("https://[2001:4860:4860::8888]/") == :ok
    end
  end

  describe "allow_private_targets" do
    test "lets a private address through when the installation says so" do
      Application.put_env(:pulse_ops, :allow_private_targets, true)

      assert UrlGuard.validate("http://127.0.0.1:4000/health") == :ok
      assert UrlGuard.validate("http://10.0.0.1/") == :ok
    end

    test "still rejects a bad scheme" do
      Application.put_env(:pulse_ops, :allow_private_targets, true)

      assert UrlGuard.validate("file:///etc/passwd") == {:error, :invalid_scheme}
    end
  end

  describe "properties" do
    property "every address in a private range is rejected, whatever the host bits" do
      check all(url <- private_ipv4_url()) do
        assert UrlGuard.validate(url) == {:error, :private_address}
      end
    end

    property "a public address is accepted, whatever the host bits" do
      check all(url <- public_ipv4_url()) do
        assert UrlGuard.validate(url) == :ok
      end
    end
  end

  defp private_ipv4_url do
    gen all(
          {a, b} <-
            one_of([
              tuple({constant(10), integer(0..255)}),
              tuple({constant(127), integer(0..255)}),
              tuple({constant(172), integer(16..31)}),
              tuple({constant(192), constant(168)}),
              tuple({constant(169), constant(254)}),
              tuple({constant(100), integer(64..127)}),
              tuple({integer(224..255), integer(0..255)})
            ]),
          c <- integer(0..255),
          d <- integer(0..255)
        ) do
      "http://#{a}.#{b}.#{c}.#{d}/"
    end
  end

  # 8.x and 93.x carry no private range, so anything in them must be allowed.
  defp public_ipv4_url do
    gen all(
          a <- member_of([8, 93]),
          b <- integer(0..255),
          c <- integer(0..255),
          d <- integer(1..254)
        ) do
      "https://#{a}.#{b}.#{c}.#{d}/health"
    end
  end
end
