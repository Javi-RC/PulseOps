defmodule PulseOpsWeb.ClientIp do
  @moduledoc """
  The client's address, when there is one worth believing (ADR-019).

  PulseOps is deployed behind a proxy that terminates TLS, so the socket's peer
  is the proxy and says nothing about who is asking. The client's address is
  only in `X-Forwarded-For` — which the client can also write. It is therefore
  read only when `:trusted_proxy` is set, meaning every request passes through a
  proxy that appends the address it saw, and then only the rightmost entry is
  taken: that one was written by the proxy, everything to its left by whoever
  sent the request.

  Without a trusted proxy this is always nil, and callers limit by what they
  can trust instead.
  """

  @doc """
  The trusted client address of a request, or nil.
  """
  @spec from_conn(Plug.Conn.t()) :: String.t() | nil
  def from_conn(%Plug.Conn{} = conn) do
    conn
    |> Plug.Conn.get_req_header("x-forwarded-for")
    |> from_forwarded_for()
  end

  @doc """
  The same, from a LiveView's `get_connect_info(socket, :x_headers)`.
  """
  @spec from_x_headers([{String.t(), String.t()}] | nil) :: String.t() | nil
  def from_x_headers(headers) when is_list(headers) do
    for({"x-forwarded-for", value} <- headers, do: value)
    |> from_forwarded_for()
  end

  def from_x_headers(_headers), do: nil

  defp from_forwarded_for(values) do
    if Application.get_env(:pulse_ops, :trusted_proxy, false) do
      values
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> List.last()
      |> parse()
    end
  end

  # Normalised, so one address written two ways is one key.
  defp parse(nil), do: nil

  defp parse(value) do
    case :inet.parse_strict_address(String.to_charlist(value)) do
      {:ok, address} -> address |> :inet.ntoa() |> to_string()
      {:error, _reason} -> nil
    end
  end
end
