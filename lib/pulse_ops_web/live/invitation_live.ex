defmodule PulseOpsWeb.InvitationLive do
  @moduledoc """
  The page an invitation link opens, at `/invitations/:token`.

  It only *offers* to accept. A `GET` is followed by mail scanners and link
  prefetchers, so a link that joined an organization by being fetched would have
  people joining organizations they never opened an email about. Accepting is a
  form post, which is the same shape `phx.gen.auth` uses for confirming an
  account.

  Public, because the whole point is that the person may not have an account
  here yet.
  """

  use PulseOpsWeb, :live_view

  alias PulseOps.Organizations

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Organizations.fetch_invitation(token) do
      {:ok, invitation} ->
        {:ok,
         socket
         |> assign(:page_title, "Join #{invitation.organization.name}")
         |> assign(:invitation, invitation)
         |> assign(:token, token)}

      {:error, :invalid_invitation} ->
        {:ok,
         socket
         |> assign(:page_title, "Invitation")
         |> assign(:invitation, nil)
         |> assign(:token, token)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.public flash={@flash} current_scope={@current_scope} centered>
      <div class="mx-auto max-w-sm">
        <div :if={@invitation}>
          <.header>
            Join {@invitation.organization.name}
            <:subtitle>
              {inviter(@invitation)} invited {@invitation.email} to help watch their services,
              as {@invitation.role}.
            </:subtitle>
          </.header>

          <form action={~p"/invitations/#{@token}/accept"} method="post" class="mt-6">
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <.button variant="primary" class="w-full">Accept invitation</.button>
          </form>

          <p class="mt-4 text-center text-xs text-base-content/50">
            Accepting signs you in as {@invitation.email}. If you do not have an account yet, one
            is created for that address.
          </p>
        </div>

        <div :if={is_nil(@invitation)} class="text-center">
          <.header>
            This invitation cannot be used
            <:subtitle>
              It may have been accepted already, withdrawn, or simply expired — invitations last {PulseOps.Organizations.Invitation.validity_days()} days. Ask whoever invited you to
              send another.
            </:subtitle>
          </.header>

          <.button navigate={~p"/"} class="mt-6">Back to PulseOps</.button>
        </div>
      </div>
    </Layouts.public>
    """
  end

  defp inviter(%{invited_by: nil}), do: "Somebody"
  defp inviter(%{invited_by: user}), do: user.email
end
