defmodule PulseOps.Monitoring.TlsCheck do
  @moduledoc """
  The seam between PulseOps and a TLS handshake, mirroring `HealthCheck`.

  Reading a certificate needs a real connection to a real host, which is exactly
  what a test suite must not do, so the implementation is resolved at call time
  and swapped for a mock in tests.
  """

  @type certificate :: %{expires_at: DateTime.t(), issuer: String.t() | nil}

  @doc """
  Reads the certificate a host presents.

  Implementations must not raise. A host that cannot be reached, does not speak
  TLS, or presents something unparseable is an ordinary outcome and is reported
  as `{:error, reason}`.
  """
  @callback certificate(url :: String.t(), opts :: keyword()) ::
              {:ok, certificate()} | {:error, String.t()}

  @doc """
  The configured implementation.
  """
  def client do
    Application.get_env(:pulse_ops, :tls_check_client, __MODULE__.Ssl)
  end
end
