defmodule PulseOpsWeb.ServiceLive.Index do
  use PulseOpsWeb, :live_view

  alias PulseOps.Monitoring

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Listing Services
        <:actions>
          <.button
            variant="primary"
            navigate={~p"/orgs/#{@current_scope.organization.slug}/services/new"}
          >
            <.icon name="hero-plus" /> New Service
          </.button>
        </:actions>
      </.header>

      <.table
        id="services"
        rows={@streams.services}
        row_click={
          fn {_id, service} ->
            JS.navigate(~p"/orgs/#{@current_scope.organization.slug}/services/#{service}")
          end
        }
      >
        <:col :let={{_id, service}} label="Name">{service.name}</:col>
        <:col :let={{_id, service}} label="Description">{service.description}</:col>
        <:col :let={{_id, service}} label="Environment">{service.environment}</:col>
        <:col :let={{_id, service}} label="Url">{service.url}</:col>
        <:col :let={{_id, service}} label="Check interval ms">{service.check_interval_ms}</:col>
        <:col :let={{_id, service}} label="Timeout ms">{service.timeout_ms}</:col>
        <:col :let={{_id, service}} label="Enabled">{service.enabled}</:col>
        <:col :let={{_id, service}} label="Status">{service.status}</:col>
        <:col :let={{_id, service}} label="Last checked at">{service.last_checked_at}</:col>
        <:action :let={{_id, service}}>
          <div class="sr-only">
            <.link navigate={~p"/orgs/#{@current_scope.organization.slug}/services/#{service}"}>Show</.link>
          </div>
          <.link navigate={~p"/orgs/#{@current_scope.organization.slug}/services/#{service}/edit"}>Edit</.link>
        </:action>
        <:action :let={{id, service}}>
          <.link
            phx-click={JS.push("delete", value: %{id: service.id}) |> hide("##{id}")}
            data-confirm="Are you sure?"
          >
            Delete
          </.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Monitoring.subscribe_services(socket.assigns.current_scope)
    end

    {:ok,
     socket
     |> assign(:page_title, "Listing Services")
     |> stream(:services, list_services(socket.assigns.current_scope))}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    service = Monitoring.get_service!(socket.assigns.current_scope, id)

    case Monitoring.delete_service(socket.assigns.current_scope, service) do
      {:ok, _service} ->
        {:noreply, stream_delete(socket, :services, service)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to delete services.")}
    end
  end

  @impl true
  def handle_info({type, %PulseOps.Monitoring.Service{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply,
     stream(socket, :services, list_services(socket.assigns.current_scope), reset: true)}
  end

  defp list_services(current_scope) do
    Monitoring.list_services(current_scope)
  end
end
