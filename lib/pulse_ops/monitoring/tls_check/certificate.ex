defmodule PulseOps.Monitoring.TlsCheck.Certificate do
  @moduledoc """
  Turns the parts of an X.509 certificate into things Elixir can use.

  Pure, and separate from the socket work in `TlsCheck.Ssl`, because this is
  where the fiddly bits are — two time formats, a two-digit year with a pivot
  that RFC 5280 places at 2049, and an issuer buried in a nested ASN.1
  structure. None of that needs a network to test, and all of it is worth
  testing.
  """

  @doc """
  The expiry from a certificate's `notAfter` value.

  X.509 writes times two ways and which one is used depends on the year, so
  both have to be understood.
  """
  @spec expiry(term()) :: {:ok, DateTime.t()} | {:error, String.t()}
  def expiry({:utcTime, value}) do
    # YYMMDDHHMMSSZ. RFC 5280 §4.1.2.5.1: 50 and above means 19xx, below means
    # 20xx — which is why a certificate expiring in 2049 and one from 1950 do
    # not collide.
    case to_string(value) do
      <<yy::binary-2, rest::binary>> ->
        prefix = if String.to_integer(yy) >= 50, do: "19", else: "20"
        parse(prefix <> yy <> rest)

      _other ->
        {:error, "unreadable certificate expiry"}
    end
  rescue
    ArgumentError -> {:error, "unreadable certificate expiry"}
  end

  def expiry({:generalTime, value}), do: parse(to_string(value))
  def expiry(_other), do: {:error, "unrecognised certificate validity format"}

  @doc """
  The issuer's common name, or nil when the certificate does not carry one.
  """
  @spec common_name(term()) :: String.t() | nil
  def common_name({:rdnSequence, rdns}) do
    rdns
    |> List.flatten()
    |> Enum.find_value(fn
      # 2.5.4.3 is the object identifier for commonName.
      {:AttributeTypeAndValue, {2, 5, 4, 3}, value} -> readable(value)
      _other -> nil
    end)
  end

  def common_name(_issuer), do: nil

  defp parse(<<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, rest::binary>>) do
    second =
      case rest do
        <<s::binary-2, _tz::binary>> -> String.to_integer(s)
        _no_seconds -> 0
      end

    case NaiveDateTime.new(
           String.to_integer(y),
           String.to_integer(mo),
           String.to_integer(d),
           String.to_integer(h),
           String.to_integer(mi),
           second
         ) do
      {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
      {:error, _reason} -> {:error, "unreadable certificate expiry"}
    end
  rescue
    ArgumentError -> {:error, "unreadable certificate expiry"}
  end

  defp parse(_other), do: {:error, "unreadable certificate expiry"}

  defp readable({:utf8String, value}), do: to_string(value)
  defp readable({:printableString, value}), do: to_string(value)
  defp readable(value) when is_list(value), do: to_string(value)
  defp readable(value) when is_binary(value), do: value
  defp readable(_other), do: nil
end
