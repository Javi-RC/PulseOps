defmodule PulseOps.Monitoring.TlsCheck.CertificateTest do
  use ExUnit.Case, async: true

  alias PulseOps.Monitoring.TlsCheck.Certificate

  describe "expiry/1 with a utcTime" do
    test "reads an ordinary date" do
      assert {:ok, at} = Certificate.expiry({:utcTime, ~c"261026064559Z"})
      assert at == ~U[2026-10-26 06:45:59Z]
    end

    test "puts a year of 49 or less in this century" do
      assert {:ok, at} = Certificate.expiry({:utcTime, ~c"491231235959Z"})
      assert at.year == 2049
    end

    test "and a year of 50 or more in the last one" do
      # RFC 5280 places the pivot here, which is the whole reason a two-digit
      # year is still usable.
      assert {:ok, at} = Certificate.expiry({:utcTime, ~c"500101000000Z"})
      assert at.year == 1950
    end

    test "tolerates a time with no seconds" do
      assert {:ok, at} = Certificate.expiry({:utcTime, ~c"2610260645Z"})
      assert at == ~U[2026-10-26 06:45:00Z]
    end
  end

  describe "expiry/1 with a generalTime" do
    test "reads a four-digit year" do
      assert {:ok, at} = Certificate.expiry({:generalTime, ~c"20991231235959Z"})
      assert at == ~U[2099-12-31 23:59:59Z]
    end
  end

  describe "expiry/1 with something else" do
    test "refuses a format it does not know" do
      assert {:error, message} = Certificate.expiry({:somethingElse, ~c"whatever"})
      assert message =~ "unrecognised"
    end

    test "refuses an impossible date instead of raising" do
      assert {:error, _message} = Certificate.expiry({:utcTime, ~c"261332235959Z"})
    end

    test "refuses something that is not a date at all" do
      assert {:error, _message} = Certificate.expiry({:utcTime, ~c"nonsense"})
      assert {:error, _message} = Certificate.expiry({:generalTime, ~c""})
      assert {:error, _message} = Certificate.expiry(nil)
    end
  end

  describe "common_name/1" do
    test "finds the issuer's common name" do
      issuer =
        {:rdnSequence,
         [
           [{:AttributeTypeAndValue, {2, 5, 4, 10}, {:utf8String, "Example Trust"}}],
           [{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, "Example CA R3"}}]
         ]}

      assert Certificate.common_name(issuer) == "Example CA R3"
    end

    test "reads a printableString too" do
      issuer =
        {:rdnSequence, [[{:AttributeTypeAndValue, {2, 5, 4, 3}, {:printableString, ~c"R10"}}]]}

      assert Certificate.common_name(issuer) == "R10"
    end

    test "is nil when there is no common name" do
      issuer =
        {:rdnSequence, [[{:AttributeTypeAndValue, {2, 5, 4, 10}, {:utf8String, "Org only"}}]]}

      assert Certificate.common_name(issuer) == nil
      assert Certificate.common_name(:unexpected) == nil
    end
  end
end
