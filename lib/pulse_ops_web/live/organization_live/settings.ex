defmodule PulseOpsWeb.OrganizationLive.Settings do
  @moduledoc """
  The organization's own settings: its name and address, its public status
  page, and the way in to the integrations that live under it.

  Laid out as sections — what a group of settings is for on the left, the
  settings themselves on the right — so a page of two forms and two links reads
  as three decisions rather than a stack of look-alike boxes. Alert rules are not
  here: they have their own entry in the navigation, next to maintenance.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.UIComponents

  alias Phoenix.HTML.Form
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
      open_incident_count={@open_incident_count}
    >
      <.page_header title="Settings">
        <:subtitle>
          The organization's name and address, its public status page, and how other systems
          connect to it.
        </:subtitle>
      </.page_header>

      <div class="divide-y divide-base-300">
        <.settings_section id="general" title="General">
          <:description>
            How the organization is named, and the address its pages live at.
          </:description>

          <.card>
            <.form
              for={@form}
              id="organization-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-4"
            >
              <.input field={@form[:name]} type="text" label="Name" required />

              <div>
                <.input field={@form[:slug]} type="text" label="Address" required />
                <p class="-mt-1 text-xs text-base-content/50">
                  Pages live at <code class="break-all">{url(~p"/orgs/#{slug_value(@form)}")}</code>
                </p>
              </div>

              <div
                :if={slug_changed?(@form, @organization)}
                id="slug-warning"
                class="flex items-start gap-2 rounded-lg border border-warning/40 bg-warning/10 p-3 text-sm"
              >
                <.icon name="lucide-triangle-alert" class="mt-0.5 size-4 shrink-0 text-warning" />
                <p>
                  Changing the address changes every link to this organization. Existing links and
                  bookmarks will stop working, including the public status page's.
                </p>
              </div>

              <div class="flex justify-end">
                <.button variant="primary" phx-disable-with="Saving...">Save changes</.button>
              </div>
            </.form>
          </.card>
        </.settings_section>

        <.settings_section id="status-page" title="Status page">
          <:description>
            A page anybody can read without an account. Service names, statuses and uptime
            appear on it; URLs, incident causes and timelines never do.
          </:description>

          <.card>
            <.form
              for={@status_page_form}
              id="status-page-form"
              phx-change="validate_status_page"
              phx-submit="save_status_page"
              class="space-y-4"
            >
              <div class="flex flex-wrap items-center justify-between gap-3">
                <div class="flex items-center gap-2">
                  <.badge color={
                    if(@organization.status_page_enabled, do: "success", else: "default")
                  }>
                    {if @organization.status_page_enabled, do: "Published", else: "Not published"}
                  </.badge>
                  <code class="break-all text-xs text-base-content/50">
                    /status/{@organization.slug}
                  </code>
                </div>
                <.button
                  :if={@organization.status_page_enabled}
                  navigate={~p"/status/#{@organization.slug}"}
                  variant="ghost"
                  size="sm"
                >
                  View the page <.icon name="lucide-arrow-up-right" class="size-4" />
                </.button>
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

              <div class="flex justify-end">
                <.button variant="primary" phx-disable-with="Saving...">Save</.button>
              </div>
            </.form>
          </.card>
        </.settings_section>

        <.settings_section id="integrations" title="Integrations">
          <:description>
            Where incidents are announced, and how programs talk to PulseOps.
          </:description>

          <.list_card id="integration-links" class="overflow-hidden">
            <:item
              :for={link <- integration_links(@current_scope)}
              class="relative transition-colors hover:bg-base-200/50"
            >
              <div class="flex items-center gap-4">
                <span class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-base-200 text-base-content/60">
                  <.icon name={link.icon} class="size-4" />
                </span>
                <div class="min-w-0 flex-1">
                  <%!-- The link stretches over the whole row, so the row is the target
                        without nesting anything interactive inside a link. --%>
                  <.link navigate={link.href} class="font-medium after:absolute after:inset-0">
                    {link.title}
                  </.link>
                  <p class="text-sm text-base-content/60">{link.description}</p>
                </div>
                <.icon name="lucide-chevron-right" class="size-4 shrink-0 text-base-content/40" />
              </div>
            </:item>
          </.list_card>
        </.settings_section>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :description, required: true
  slot :inner_block, required: true

  defp settings_section(assigns) do
    ~H"""
    <section
      id={"settings-#{@id}"}
      aria-labelledby={"settings-#{@id}-title"}
      class="grid gap-4 py-8 first:pt-0 lg:grid-cols-3 lg:gap-8"
    >
      <div>
        <h2 id={"settings-#{@id}-title"} class="font-semibold">{@title}</h2>
        <p class="mt-1 text-sm text-base-content/60">{render_slot(@description)}</p>
      </div>
      <div class="lg:col-span-2">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  defp integration_links(scope) do
    slug = scope.organization.slug

    [
      %{
        title: "Notifiers",
        icon: "lucide-bell",
        href: ~p"/orgs/#{slug}/settings/notifiers",
        description:
          "The webhook endpoints and email addresses that hear about incidents as they open and resolve."
      },
      %{
        title: "API tokens",
        icon: "lucide-key-round",
        href: ~p"/orgs/#{slug}/settings/api-tokens",
        description: "Let a program read and change services and incidents over HTTP."
      }
    ]
  end

  defp slug_value(form), do: Form.input_value(form, :slug) || ""

  # The warning is about a change, so it only appears once there is one.
  defp slug_changed?(form, organization), do: slug_value(form) != organization.slug
end
