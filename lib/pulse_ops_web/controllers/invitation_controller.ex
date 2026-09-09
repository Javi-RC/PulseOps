defmodule PulseOpsWeb.InvitationController do
  @moduledoc """
  Redeems an invitation and signs the person in.

  A controller rather than a LiveView, for the same reason logging in is one:
  it has to write a session cookie, which a LiveView cannot do.
  """

  use PulseOpsWeb, :controller

  alias PulseOps.Organizations
  alias PulseOpsWeb.UserAuth

  def accept(conn, %{"token" => token}) do
    case Organizations.accept_invitation(token) do
      {:ok, user, membership} ->
        organization = membership.organization

        conn
        |> put_flash(:info, "You are now a member of #{organization.name}.")
        # Signing in here is the point: holding the link proved control of the
        # mailbox, which is the same proof the magic-link login accepts.
        |> put_session(:user_return_to, ~p"/orgs/#{organization.slug}")
        |> UserAuth.log_in_user(user)

      {:error, :invalid_invitation} ->
        conn
        |> put_flash(:error, "That invitation cannot be used.")
        |> redirect(to: ~p"/")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "That invitation could not be accepted.")
        |> redirect(to: ~p"/")
    end
  end
end
