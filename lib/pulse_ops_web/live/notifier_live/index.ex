defmodule PulseOpsWeb.NotifierLive.Index do
  @moduledoc """
  Lists the organization's incident notification channels: webhook endpoints
  and email addresses. Deleting a notifier just stops delivery; the incident
  history is untouched.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.UIComponents

  alias PulseOps.Notifications
  alias PulseOps.Organizations

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Notifications") |> load_notifiers()}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Enum.find(socket.assigns.notifiers, &(&1.id == String.to_integer(id))) do
      nil ->
        {:noreply, socket}

      notifier ->
        case Notifications.delete_notifier(scope, notifier) do
          {:ok, _notifier} ->
            {:noreply,
             socket
             |> put_flash(:info, "Notifier removed; incidents will no longer be sent to it.")
             |> load_notifiers()}

          {:error, :unauthorized} ->
            {:noreply, put_flash(socket, :error, "You do not have permission to do that.")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "That notifier could not be removed.")}
        end
    end
  end

  defp load_notifiers(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:notifiers, Notifications.list_notifiers(scope))
    |> assign(:can_manage?, Organizations.can?(scope, :manage_organization))
  end

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
      <.page_header title="Notifications">
        <:subtitle>
          Where incidents are announced when they open and when they resolve. Each
          notifier is a webhook endpoint or an email address.
        </:subtitle>
        <:actions>
          <.button
            :if={@can_manage?}
            id="new-notifier-link"
            navigate={~p"/orgs/#{@current_scope.organization.slug}/settings/notifiers/new"}
            variant="primary"
            size="sm"
          >
            <.icon name="lucide-plus" class="size-4" /> New notifier
          </.button>
        </:actions>
      </.page_header>

      <%= if @notifiers == [] do %>
        <.empty_state icon="lucide-bell" title="Nobody has been told yet">
          <:subtitle>
            Add a webhook (Discord, Teams, ntfy, a custom endpoint…) or an email address to
            hear about incidents as they happen.
          </:subtitle>
          <:actions>
            <.button
              :if={@can_manage?}
              navigate={~p"/orgs/#{@current_scope.organization.slug}/settings/notifiers/new"}
              size="sm"
            >
              Add a notifier
            </.button>
          </:actions>
        </.empty_state>
      <% else %>
        <.card id="notifiers" padded={false} class="divide-y divide-base-200">
          <div
            :for={notifier <- @notifiers}
            id={"notifier-#{notifier.id}"}
            class="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3"
          >
            <.type_badge type={notifier.type} />
            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2">
                <p class="truncate text-sm font-medium">{notifier.name}</p>
                <span
                  :if={notifier.service}
                  class="inline-flex items-center rounded-full bg-base-300 px-2 py-0.5 text-xs font-medium text-base-content"
                >
                  <.icon name="lucide-server" class="size-3.5" />
                  {notifier.service.name}
                </span>
                <span
                  :if={is_nil(notifier.service)}
                  class="inline-flex items-center rounded-full bg-base-300 px-2 py-0.5 text-xs font-medium text-base-content/60"
                >
                  All services
                </span>
                <%= if notifier.enabled do %>
                  <span class="inline-flex items-center rounded-full bg-success/10 px-2 py-0.5 text-xs font-medium text-success">
                    Active
                  </span>
                <% else %>
                  <span class="inline-flex items-center rounded-full bg-base-200 px-2 py-0.5 text-xs font-medium text-base-content/50">
                    Paused
                  </span>
                <% end %>
              </div>
              <div class="mt-0.5 flex flex-wrap items-center gap-x-3 gap-y-1">
                <p class="truncate text-xs text-base-content/50">{destination(notifier)}</p>
                <p :if={notifier.assigned_users != []} class="truncate text-xs text-base-content/50">
                  {Enum.map_join(notifier.assigned_users, ", ", & &1.email)}
                </p>
              </div>
            </div>
            <%= if @can_manage? do %>
              <div class="flex items-center gap-1">
                <.button
                  navigate={
                    ~p"/orgs/#{@current_scope.organization.slug}/settings/notifiers/#{notifier.id}/edit"
                  }
                  variant="ghost"
                  size="sm"
                >
                  Edit
                </.button>
                <.button
                  type="button"
                  phx-click="delete"
                  phx-value-id={notifier.id}
                  data-confirm={"Remove #{notifier.name}? Incidents will no longer be sent to it."}
                  data-confirm-label="Remove notifier"
                  variant="danger-ghost"
                  size="sm"
                  aria-label={"Delete notifier #{notifier.name}"}
                >
                  <.icon name="lucide-trash" class="size-4" />
                </.button>
              </div>
            <% end %>
          </div>
        </.card>
      <% end %>
    </Layouts.app>
    """
  end

  defp type_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium",
      @type == :webhook && "bg-base-300 text-base-content",
      @type == :email && "bg-primary/10 text-primary"
    ]}>
      <.icon name={(@type == :webhook && "lucide-webhook") || "lucide-mail"} class="size-3.5" />
      {@type}
    </span>
    """
  end

  defp destination(%{type: :webhook, url: url}), do: url
  defp destination(%{type: :email}), do: "Email to assigned members"
end
