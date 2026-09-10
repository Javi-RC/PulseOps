defmodule PulseOps.Notifications.TlsNotifier do
  @moduledoc """
  The email that says a certificate is running out.

  Plain text, like every other notification here: this is read on a phone and
  the useful part is a name and a number of days.
  """

  import Swoosh.Email

  alias PulseOps.Notifications.Mailer
  alias PulseOps.Notifications.Notifier

  @doc """
  Sends the warning to everybody assigned to the notifier.
  """
  def deliver(%Notifier{assigned_users: users}, service, days_left) when is_list(users) do
    Enum.reduce_while(users, {:ok, nil}, fn user, _acc ->
      case deliver_one(user.email, service, days_left) do
        {:ok, metadata} -> {:cont, {:ok, metadata}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp deliver_one(recipient, service, days_left) do
    new()
    |> to(recipient)
    |> from(Mailer.from_default())
    |> subject(subject_line(service, days_left))
    |> text_body(body(service, days_left))
    |> Mailer.deliver()
  end

  defp subject_line(service, days) when days < 0,
    do: "#{service.name}: the TLS certificate has expired"

  defp subject_line(service, days),
    do: "#{service.name}: the TLS certificate expires in #{days} days"

  defp body(service, days_left) do
    """

    ==============================

    #{headline(service, days_left)}

    Service:  #{service.name}
    Expires:  #{expires(service)}

    Nothing is wrong with the service right now. This is the one outage that
    announces itself in advance, which is the only reason it is worth an email.

    ==============================
    """
  end

  defp headline(service, days) when days < 0,
    do: "The certificate for #{service.name} expired #{abs(days)} days ago."

  defp headline(service, 0), do: "The certificate for #{service.name} expires today."

  defp headline(service, days),
    do: "The certificate for #{service.name} expires in #{days} days."

  defp expires(%{tls_expires_at: nil}), do: "unknown"
  defp expires(%{tls_expires_at: at}), do: Calendar.strftime(at, "%d %b %Y %H:%M UTC")
end
