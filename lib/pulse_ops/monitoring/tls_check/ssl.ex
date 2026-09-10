defmodule PulseOps.Monitoring.TlsCheck.Ssl do
  @moduledoc """
  Reads a host's certificate over a real TLS handshake.

  Only the socket work lives here; reading the dates and names out of the
  certificate is in `TlsCheck.Certificate`, which is pure and tested directly.

  ## Why the certificate is not verified

  The connection is made with `verify: :verify_none`. That looks alarming and is
  deliberate: the job here is to *read* the expiry date the host presents, and a
  certificate that has already expired, or is self-signed, or is for the wrong
  name, fails verification — which are precisely the cases somebody most needs
  told about. Verifying would turn "your certificate expired last night" into a
  connection error with no date in it.

  Nothing is trusted as a result. The only thing taken from the peer is a date,
  and it is used to decide whether to warn a human.

  The same `UrlGuard` that protects the probes runs first, because this opens a
  connection to an address a tenant chose (ADR: see F5 in the roadmap).
  """

  @behaviour PulseOps.Monitoring.TlsCheck

  alias PulseOps.Monitoring.TlsCheck.Certificate
  alias PulseOps.Monitoring.UrlGuard

  @default_timeout_ms 10_000

  @impl true
  def certificate(url, opts \\ []) do
    with {:ok, host, port} <- target(url),
         :ok <- UrlGuard.validate(url) do
      connect(host, port, Keyword.get(opts, :timeout_ms, @default_timeout_ms))
    else
      # Only a certificate has an expiry to read, so anything that is not https
      # is a statement about the service rather than a failure to reach it.
      {:error, :not_https} -> {:error, "not an https URL"}
      {:error, reason} -> {:error, UrlGuard.message(reason)}
    end
  end

  defp target(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, port: port} when is_binary(host) and host != "" ->
        {:ok, String.to_charlist(host), port || 443}

      _otherwise ->
        {:error, :not_https}
    end
  end

  defp target(_url), do: {:error, :not_https}

  defp connect(host, port, timeout) do
    options = [
      verify: :verify_none,
      active: false,
      # Without SNI a host serving several certificates hands back the wrong
      # one, and the expiry date would belong to somebody else's site.
      server_name_indication: host
    ]

    case :ssl.connect(host, port, options, timeout) do
      {:ok, socket} ->
        result = read_certificate(socket)
        :ssl.close(socket)
        result

      {:error, reason} ->
        {:error, describe(reason)}
    end
  end

  defp read_certificate(socket) do
    case :ssl.peercert(socket) do
      {:ok, der} -> decode(der)
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  defp decode(der) do
    certificate = :public_key.pkix_decode_cert(der, :otp)

    {:OTPCertificate, tbs, _signature_algorithm, _signature} = certificate
    {:OTPTBSCertificate, _v, _serial, _sig, issuer, validity, _subject, _rest} = truncate(tbs)
    {:Validity, _not_before, not_after} = validity

    with {:ok, expires_at} <- Certificate.expiry(not_after) do
      {:ok, %{expires_at: expires_at, issuer: Certificate.common_name(issuer)}}
    end
  rescue
    error -> {:error, "could not read the certificate: #{Exception.message(error)}"}
  end

  # The OTPTBSCertificate record has more fields than are needed here, and its
  # arity has changed between OTP releases. Taking the first seven by position
  # is stable across both.
  defp truncate(tbs) do
    tbs |> Tuple.to_list() |> Enum.take(8) |> List.to_tuple()
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_atom(reason), do: to_string(reason)
  defp describe({:tls_alert, {_alert, message}}), do: to_string(message)
  defp describe(reason), do: inspect(reason)
end
