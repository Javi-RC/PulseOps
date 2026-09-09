defmodule PulseOps.Notifications.DigestNotifier do
  @moduledoc """
  The email a flapping service produces: one message saying how often it moved,
  instead of one message per move.

  Plain text for the same reason the incident emails are — this arrives on a
  phone, at night, and the useful part has to be readable in a notification
  preview.
  """

  import Swoosh.Email

  alias PulseOps.Notifications.Mailer
  alias PulseOps.Notifications.Notifier

  @doc """
  Sends the digest to everybody assigned to the notifier.
  """
  def deliver(%Notifier{assigned_users: users}, service, summary) when is_list(users) do
    Enum.reduce_while(users, {:ok, nil}, fn user, _acc ->
      case deliver_one(user.email, service, summary) do
        {:ok, metadata} -> {:cont, {:ok, metadata}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp deliver_one(recipient, service, summary) do
    email =
      new()
      |> to(recipient)
      |> from(Mailer.from_default())
      |> subject("#{service.name} is flapping")
      |> text_body(body(service, summary))

    Mailer.deliver(email)
  end

  defp body(service, summary) do
    """

    ==============================

    #{service.name} has gone down and come back #{summary.count} times
    in the last #{minutes(summary)} minutes.

    It is #{state(summary)} right now.

    A service moving this often is usually a threshold set too tight or a
    dependency of its own that is struggling — not #{summary.count} separate
    outages. This is one message instead of #{summary.count}.

    ==============================
    """
  end

  defp minutes(%{first_at: nil}), do: "a few"

  defp minutes(%{first_at: first_at}) do
    DateTime.utc_now() |> DateTime.diff(first_at) |> div(60) |> max(1)
  end

  defp state(%{still_open: 0}), do: "back up"
  defp state(_summary), do: "down"
end
