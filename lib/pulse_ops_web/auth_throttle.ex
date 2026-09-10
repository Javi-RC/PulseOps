defmodule PulseOpsWeb.AuthThrottle do
  @moduledoc """
  How often someone may try to get into an account (ADR-019).

  Each action is limited per email and, behind a trusted proxy, per client
  address. The email limit stops one account being guessed at or flooded with
  magic links; the address limit stops one client working through many emails.
  Without a trusted proxy there is no address worth believing
  (`PulseOpsWeb.ClientIp`), so only the email limit applies.

  Password attempts count only when they fail, and are checked *before* the
  password is verified, so a refused attempt costs no bcrypt. Magic links and
  registrations count every request, because every request can send an email.
  """

  alias PulseOpsWeb.RateLimiter

  @minute 60_000

  @limits %{
    password: [email: {5, 15 * @minute}, address: {50, 15 * @minute}],
    magic_link: [email: {3, 15 * @minute}, address: {20, 15 * @minute}],
    registration: [email: {3, 60 * @minute}, address: {10, 60 * @minute}]
  }

  @type result :: :ok | {:deny, pos_integer()}

  @doc """
  Whether another password attempt may be made. Counts nothing.
  """
  @spec check_password(String.t() | nil, String.t() | nil) :: result()
  def check_password(email, address) do
    apply_limits(:password, email, address, &RateLimiter.check/3)
  end

  @doc """
  Counts a failed password attempt.
  """
  @spec failed_password(String.t() | nil, String.t() | nil) :: result()
  def failed_password(email, address) do
    apply_limits(:password, email, address, &RateLimiter.hit/3)
  end

  @doc """
  Counts a magic-link request or a registration, and says whether it may go
  ahead.
  """
  @spec hit(:magic_link | :registration, String.t() | nil, String.t() | nil) :: result()
  def hit(action, email, address) when action in [:magic_link, :registration] do
    apply_limits(action, email, address, &RateLimiter.hit/3)
  end

  @doc """
  What to tell someone who has been refused. It says nothing about whether the
  email has an account: the limit applies either way.
  """
  @spec message({:deny, pos_integer()}) :: String.t()
  def message({:deny, retry_after_ms}) do
    minutes = max(1, div(retry_after_ms + @minute - 1, @minute))
    unit = if minutes == 1, do: "minute", else: "minutes"

    "Too many attempts. Try again in #{minutes} #{unit}."
  end

  # Every bucket is counted, even once one has refused, so a client cannot keep
  # one limit fresh by tripping another.
  defp apply_limits(action, email, address, count) do
    identities = %{email: normalize_email(email), address: address}

    denials =
      for {dimension, {limit, window_ms}} <- Map.fetch!(@limits, action),
          identity <- [identities[dimension]],
          identity != nil,
          {:deny, _retry_after} = denial <- [
            count.({action, dimension, identity}, limit, window_ms)
          ],
          do: denial

    case denials do
      [] -> :ok
      _refused -> {:deny, denials |> Enum.map(&elem(&1, 1)) |> Enum.max()}
    end
  end

  # One account, however its email is typed.
  defp normalize_email(email) when is_binary(email) do
    case email |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_email(_email), do: nil
end
