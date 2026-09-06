defmodule PulseOpsWeb.OrganizationLive.Form do
  @moduledoc """
  Creates an organization.

  Deliberately outside the `:require_organization` live session: there is no
  organization to resolve yet.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.UIComponents

  alias PulseOps.Organizations
  alias PulseOps.Organizations.Organization

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "New organization")
     |> assign(:form, to_form(Organizations.change_organization(%Organization{})))}
  end

  @impl true
  def handle_event("validate", %{"organization" => params}, socket) do
    changeset = Organizations.change_organization(%Organization{}, params)

    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"organization" => params}, socket) do
    case Organizations.create_organization(socket.assigns.current_scope.user, params) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{organization.name} is ready.")
         |> push_navigate(to: ~p"/orgs/#{organization.slug}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.public flash={@flash} current_scope={@current_scope} centered>
      <.card>
        <.page_header title="New organization" class="mb-4">
          <:subtitle>
            A separate space for its own services, incidents and members.
          </:subtitle>
        </.page_header>

        <.form
          for={@form}
          id="organization-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-4"
        >
          <.input field={@form[:name]} type="text" label="Name" placeholder="Acme Corp" required />
          <.input
            field={@form[:slug]}
            type="text"
            label="URL"
            placeholder="Leave blank to use the name"
          />
          <p class="text-xs text-base-content/50">
            Used in every address for this organization, as /orgs/&lt;url&gt;.
          </p>

          <div class="flex gap-2 pt-2">
            <.button variant="primary" phx-disable-with="Creating...">Create organization</.button>
            <.link navigate={~p"/"} class="btn btn-soft">Cancel</.link>
          </div>
        </.form>
      </.card>
    </Layouts.public>
    """
  end
end
