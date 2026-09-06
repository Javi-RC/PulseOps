defmodule PulseOpsWeb.OrganizationLive.Settings do
  @moduledoc """
  Renames an organization or changes the slug its addresses are built from.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.UIComponents

  alias PulseOps.Organizations

  @impl true
  def mount(_params, _session, socket) do
    organization = socket.assigns.current_scope.organization

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:organization, organization)
     |> assign(:form, to_form(Organizations.change_organization(organization)))}
  end

  @impl true
  def handle_event("validate", %{"organization" => params}, socket) do
    changeset = Organizations.change_organization(socket.assigns.organization, params)

    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"organization" => params}, socket) do
    scope = socket.assigns.current_scope

    case Organizations.update_organization(scope, socket.assigns.organization, params) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> put_flash(:info, "Organization updated.")
         # The slug may have changed, and with it every address below it.
         |> push_navigate(to: ~p"/orgs/#{organization.slug}/settings")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to do that.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
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
      <.page_header title="Settings">
        <:subtitle>How this organization is named and addressed.</:subtitle>
      </.page_header>

      <.card class="max-w-xl">
        <.form
          for={@form}
          id="organization-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-4"
        >
          <.input field={@form[:name]} type="text" label="Name" required />
          <.input field={@form[:slug]} type="text" label="URL" required />

          <div class="rounded-lg bg-warning/10 p-3 text-xs text-base-content/70">
            <.icon name="lucide-triangle-alert" class="mr-1 size-3.5 align-text-bottom" />
            Changing the URL changes every address for this organization. Existing links and
            bookmarks will stop working.
          </div>

          <.button variant="primary" phx-disable-with="Saving...">Save changes</.button>
        </.form>
      </.card>
    </Layouts.app>
    """
  end
end
