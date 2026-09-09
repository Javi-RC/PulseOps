defmodule PulseOpsWeb.ApiTokenLive.Index do
  @moduledoc """
  The organization's API tokens: minting one, seeing which exist, revoking one.

  A new token is shown exactly once, in the response that created it. There is
  no "show token" control anywhere on this page because there is nothing to
  show — only the hash was kept, which is what makes a leaked database useless
  for impersonating a tenant.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.UIComponents

  alias PulseOps.Api
  alias PulseOps.Api.Token
  alias PulseOps.Organizations

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:page_title, "API tokens")
     |> assign(:can_manage?, Organizations.can?(scope, :manage_organization))
     |> assign(:revealed, nil)
     |> assign(:form, to_form(%{"name" => ""}, as: :token))
     |> load_tokens()}
  end

  @impl true
  def handle_event("create", %{"token" => params}, socket) do
    case Api.create_token(socket.assigns.current_scope, params) do
      {:ok, plaintext, token} ->
        {:noreply,
         socket
         |> assign(:revealed, %{plaintext: plaintext, name: token.name})
         |> assign(:form, to_form(%{"name" => ""}, as: :token))
         |> load_tokens()}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to do that.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :token))}
    end
  end

  def handle_event("dismiss", _params, socket) do
    {:noreply, assign(socket, :revealed, nil)}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case Api.revoke_token(socket.assigns.current_scope, String.to_integer(id)) do
      {:ok, token} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{token.name} revoked. Anything using it stops working now.")
         |> load_tokens()}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to do that.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That token no longer exists.")}
    end
  end

  defp load_tokens(socket) do
    assign(socket, :tokens, Api.list_tokens(socket.assigns.current_scope))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      organizations={@organizations}
      current_path={@current_path}
    >
      <.page_header title="API tokens">
        <:subtitle>
          Let a program read and change this organization's services and incidents.
        </:subtitle>
      </.page_header>

      <div :if={@revealed} class="mb-6 rounded-box border border-success/40 bg-success/5 p-4 sm:p-5">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div class="min-w-0">
            <p class="font-medium">{@revealed.name} is ready</p>
            <p class="mt-0.5 text-sm text-base-content/60">
              Copy it now. Only a hash was stored, so this cannot be shown again — if it is lost,
              revoke it and make another.
            </p>
          </div>
          <button phx-click="dismiss" class="btn btn-ghost btn-sm">Done</button>
        </div>

        <pre class="mt-3 overflow-x-auto rounded-lg bg-base-300 p-3 text-sm"><code>{@revealed.plaintext}</code></pre>
      </div>

      <.card :if={@can_manage?} class="mb-6 max-w-xl">
        <.form for={@form} id="api-token-form" phx-submit="create" class="space-y-4">
          <div>
            <p class="font-medium">New token</p>
            <p class="mt-0.5 text-sm text-base-content/50">
              It acts as you, with whatever you are allowed to do here — so it can never do more
              than you can, and it stops working if you leave the organization.
            </p>
          </div>

          <.input field={@form[:name]} type="text" label="Name" placeholder="CI pipeline" required />

          <.button variant="primary" phx-disable-with="Creating...">Create token</.button>
        </.form>
      </.card>

      <p
        :if={@tokens == []}
        class="rounded-box border border-base-300 p-6 text-sm text-base-content/60"
      >
        No tokens yet.
      </p>

      <ul :if={@tokens != []} class="divide-y divide-base-300 rounded-box border border-base-300">
        <li
          :for={token <- @tokens}
          class="flex flex-wrap items-center justify-between gap-3 p-4 sm:p-5"
        >
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <span class="font-medium">{token.name}</span>
              <span :if={not Token.active?(token)} class="badge badge-sm badge-ghost">Revoked</span>
            </div>
            <p class="mt-0.5 font-mono text-xs text-base-content/50">{token.prefix}…</p>
            <p class="mt-0.5 text-xs text-base-content/50">
              Acts as {token.user.email} · last used {last_used(token)}
            </p>
          </div>

          <button
            :if={@can_manage? and Token.active?(token)}
            phx-click="revoke"
            phx-value-id={token.id}
            data-confirm={"Revoke #{token.name}? Anything using it stops working immediately."}
            class="btn btn-soft btn-sm btn-error"
          >
            Revoke
          </button>
        </li>
      </ul>

      <.card class="mt-6">
        <p class="font-medium">Using it</p>
        <pre class="mt-3 overflow-x-auto rounded-lg bg-base-300 p-3 text-xs"><code>{curl_example()}</code></pre>
        <p class="mt-2 text-xs text-base-content/50">
          Services and incidents, read and write. The token's role decides what it may change.
        </p>
      </.card>
    </Layouts.app>
    """
  end

  # Built here rather than in the template: a heredoc inside <pre> keeps its
  # own indentation, so the markup's indentation would end up inside the
  # command somebody copies.
  defp curl_example do
    ~s(curl -H "Authorization: Bearer <token>" ) <> url(~p"/api/v1/services")
  end

  defp last_used(%{last_used_at: nil}), do: "never"
  defp last_used(%{last_used_at: at}), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
end
