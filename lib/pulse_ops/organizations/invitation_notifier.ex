defmodule PulseOps.Organizations.InvitationNotifier do
  @moduledoc """
  The email that carries an invitation link.

  Uses `PulseOps.Mailer`, the same one the login links go through, rather than
  `PulseOps.Notifications.Mailer`. That split is on purpose: the notifications
  mailer is the one an organization points at its own provider for incident
  alerts, and an invitation is not an incident — it is account correspondence,
  and it has to keep working whether or not a tenant has configured anything.
  """

  import Swoosh.Email

  alias PulseOps.Mailer
  alias PulseOps.Organizations.Invitation

  @doc """
  Sends the invitation.
  """
  @spec deliver_invitation(Invitation.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_invitation(%Invitation{} = invitation, url) do
    organization = invitation.organization
    inviter = invitation.invited_by

    email =
      new()
      |> to(invitation.email)
      |> from(Mailer.from_default())
      |> subject("You have been invited to #{organization.name} on PulseOps")
      |> text_body(body(organization, inviter, invitation, url))

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  defp body(organization, inviter, invitation, url) do
    """

    ==============================

    #{who(inviter)} invited you to join #{organization.name} on PulseOps,
    as #{article(invitation.role)} #{invitation.role}.

    PulseOps watches services and tells people when they break.

    Accept the invitation here:

    #{url}

    The link works once and expires in #{Invitation.validity_days()} days. You do
    not need an account first — opening it will create one for this address.

    If you were not expecting this, ignore this email and nothing will happen.

    ==============================
    """
  end

  defp who(nil), do: "Somebody"
  defp who(inviter), do: inviter.email

  defp article(role) when role in [:owner, :admin], do: "an"
  defp article(_role), do: "a"
end
