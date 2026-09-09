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
     |> assign(:form, to_form(Organizations.change_organization(organization)))
     |> assign(:status_page_form, to_form(Organizations.change_organization(organization)))}
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

  def handle_event("validate_status_page", %{"organization" => params}, socket) do
    changeset = Organizations.change_organization(socket.assigns.organization, params)

    {:noreply, assign(socket, :status_page_form, to_form(changeset, action: :validate))}
  end

  def handle_event("save_status_page", %{"organization" => params}, socket) do
    scope = socket.assigns.current_scope

    # Only the two status page fields, whatever else the form posted: this
    # control must not become a second way to rename the organization or move
    # its slug.
    params = Map.take(params, ["status_page_enabled", "status_page_headline"])

    case Organizations.update_organization(scope, socket.assigns.organization, params) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> put_flash(:info, status_page_flash(organization))
         |> assign(:organization, organization)
         |> assign(:status_page_form, to_form(Organizations.change_organization(organization)))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to do that.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :status_page_form, to_form(changeset))}
    end
  end

  defp status_page_flash(%{status_page_enabled: true}), do: "Status page published."
  defp status_page_flash(_organization), do: "Status page taken down."

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

      <.card class="mt-6 max-w-xl">
        <.form
          for={@status_page_form}
          id="status-page-form"
          phx-change="validate_status_page"
          phx-submit="save_status_page"
          class="space-y-4"
        >
          <div>
            <p class="font-medium">Public status page</p>
            <p class="mt-0.5 text-sm text-base-content/50">
              A page anybody can read without an account, at <code class="text-xs">/status/{@organization.slug}</code>. Service names, statuses
              and uptime appear on it. URLs, incident causes and timelines never do.
            </p>
          </div>

          <.input
            field={@status_page_form[:status_page_enabled]}
            type="checkbox"
            label="Publish a status page"
          />

          <.input
            field={@status_page_form[:status_page_headline]}
            type="text"
            label="Headline"
            placeholder="Live status of our services"
          />

          <div class="flex items-center gap-3">
            <.button variant="primary" phx-disable-with="Saving...">Save</.button>
            <.link
              :if={@organization.status_page_enabled}
              navigate={~p"/status/#{@organization.slug}"}
              class="btn btn-soft btn-sm"
            >
              View the page
            </.link>
          </div>
        </.form>
      </.card>

      <.card class="mt-6 max-w-xl">
        <div class="flex items-center justify-between gap-4">
          <div>
            <p class="font-medium">Alert rules</p>
            <p class="mt-0.5 text-sm text-base-content/50">
              When a service counts as down, how quickly it recovers, and how its incidents are
              classified.
            </p>
          </div>
          <.link
            navigate={~p"/orgs/#{@current_scope.organization.slug}/settings/alert-rules"}
            class="btn btn-soft btn-sm"
          >
            Edit rules
          </.link>
        </div>
      </.card>
      <.card class="mt-6 max-w-xl">
        <div class="flex items-center justify-between gap-4">
          <div>
            <p class="font-medium">API tokens</p>
            <p class="mt-0.5 text-sm text-base-content/50">
              Let a program read and change this organization's services and incidents over HTTP.
            </p>
          </div>
          <.link
            navigate={~p"/orgs/#{@current_scope.organization.slug}/settings/api-tokens"}
            class="btn btn-soft btn-sm"
          >
            Manage tokens
          </.link>
        </div>
      </.card>

      <.card class="mt-6 max-w-xl">
        <div class="flex items-center justify-between gap-4">
          <div>
            <p class="font-medium">Notifications</p>
            <p class="mt-0.5 text-sm text-base-content/50">
              The webhook endpoints and email addresses that hear about incidents when they
              open and resolve.
            </p>
          </div>
          <.link
            navigate={~p"/orgs/#{@current_scope.organization.slug}/settings/notifiers"}
            class="btn btn-soft btn-sm"
          >
            Manage notifiers
          </.link>
        </div>
      </.card>
    </Layouts.app>
    """
  end
end
