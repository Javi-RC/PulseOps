defmodule PulseOps.Monitoring.UrlGuard do
  @moduledoc """
  Decides whether PulseOps is allowed to make a request to a URL a tenant
  supplied.

  Both the health checks and the outgoing webhooks fetch a URL that somebody
  typed into a form, from inside the network PulseOps runs in. Without a guard
  that is a server-side request forgery primitive handed to every tenant: point
  a "service" at `http://169.254.169.254/latest/meta-data/` or
  `http://localhost:5432` and the dashboard reports back the HTTP status and the
  response time of an internal endpoint, probed on a schedule, for free.

  ## Why the check runs twice

  Validating in the changeset is not enough. Between the moment a URL is saved
  and the moment it is fetched, the name can be repointed at a private address —
  DNS rebinding — and the check interval means that window is permanently open.
  So the guard also runs immediately before each request, where what it resolves
  is what the request is about to use.

  ## Private networks are a legitimate deployment

  Plenty of installations exist to watch things on a private network, so the
  guard is switched off with `config :pulse_ops, :allow_private_targets, true`
  (the default in development and test). Production leaves it on. The scheme
  check applies either way.
  """

  import Bitwise

  @type reason :: :invalid_scheme | :unresolvable | :private_address

  @doc """
  Checks a URL. `:ok` means the request may be made.

  Resolves the host, so a name pointing at a private address is rejected just
  like a literal one. A host that resolves to nothing is rejected too: an
  unresolvable target cannot be probed usefully, and treating the failure as
  "allowed" would make the guard fail open.
  """
  @spec validate(term()) :: :ok | {:error, reason()}
  def validate(url) do
    with {:ok, host} <- host(url) do
      if allow_private_targets?(), do: :ok, else: check_addresses(host)
    end
  end

  @doc """
  Human-readable form of a rejection, for changeset errors and check results.
  """
  @spec message(reason()) :: String.t()
  def message(:invalid_scheme), do: "must be a valid http or https URL"
  def message(:unresolvable), do: "could not be resolved"

  def message(:private_address),
    do: "must not point at a private, loopback or link-local address"

  defp allow_private_targets? do
    Application.get_env(:pulse_ops, :allow_private_targets, false)
  end

  defp host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        case unbracket(host) do
          "" -> {:error, :invalid_scheme}
          host -> {:ok, host}
        end

      _otherwise ->
        {:error, :invalid_scheme}
    end
  end

  defp host(_other), do: {:error, :invalid_scheme}

  # A literal IPv6 host keeps its brackets in some URI forms and loses them in
  # others; :inet wants it without either way.
  defp unbracket(host) do
    host |> String.trim_leading("[") |> String.trim_trailing("]")
  end

  defp check_addresses(host) do
    case resolve(host) do
      [] ->
        {:error, :unresolvable}

      addresses ->
        # Every address the name answers with has to be acceptable. One public
        # answer alongside a private one is still a way in.
        if Enum.any?(addresses, &private?/1) do
          {:error, :private_address}
        else
          :ok
        end
    end
  end

  defp resolve(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, address} -> [address]
      {:error, _reason} -> lookup(charlist)
    end
  end

  defp lookup(charlist) do
    Enum.flat_map([:inet, :inet6], fn family ->
      case :inet.getaddrs(charlist, family) do
        {:ok, addresses} -> addresses
        {:error, _reason} -> []
      end
    end)
  end

  # IPv4. "Private" here is everything that is not a routable public address:
  # anything reaching a host the tenant should not be able to aim PulseOps at.
  defp private?({0, _b, _c, _d}), do: true
  defp private?({10, _b, _c, _d}), do: true
  defp private?({127, _b, _c, _d}), do: true
  defp private?({169, 254, _c, _d}), do: true
  defp private?({192, 168, _c, _d}), do: true
  defp private?({192, 0, 0, _d}), do: true
  defp private?({172, b, _c, _d}) when b >= 16 and b <= 31, do: true
  # Carrier-grade NAT.
  defp private?({100, b, _c, _d}) when b >= 64 and b <= 127, do: true
  # Benchmarking range.
  defp private?({198, b, _c, _d}) when b in [18, 19], do: true
  # Multicast, reserved, and the broadcast address.
  defp private?({a, _b, _c, _d}) when a >= 224, do: true
  defp private?({_a, _b, _c, _d}), do: false

  # IPv6. The two embedded-IPv4 forms are unwrapped and judged as IPv4, or
  # ::ffff:127.0.0.1 would walk straight past the guard.
  defp private?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}), do: private?(embedded_v4(ab, cd))
  defp private?({0x64, 0xFF9B, 0, 0, 0, 0, ab, cd}), do: private?(embedded_v4(ab, cd))
  # Unique local, fc00::/7.
  defp private?({a, _b, _c, _d, _e, _f, _g, _h}) when (a &&& 0xFE00) == 0xFC00, do: true
  # Link-local, fe80::/10.
  defp private?({a, _b, _c, _d, _e, _f, _g, _h}) when (a &&& 0xFFC0) == 0xFE80, do: true
  defp private?({_a, _b, _c, _d, _e, _f, _g, _h}), do: false

  defp embedded_v4(ab, cd), do: {ab >>> 8, ab &&& 0xFF, cd >>> 8, cd &&& 0xFF}
end
