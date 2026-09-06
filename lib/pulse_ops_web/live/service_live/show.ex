defmodule PulseOpsWeb.ServiceLive.Show do
  use PulseOpsWeb, :live_view

  alias PulseOps.Monitoring

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Service {@service.id}
        <:subtitle>This is a service record from your database.</:subtitle>
        <:actions>
          <.button navigate={~p"/orgs/#{@current_scope.organization.slug}/services"}>
            <.icon name="hero-arrow-left" />
          </.button>
          <.button
            variant="primary"
            navigate={
              ~p"/orgs/#{@current_scope.organization.slug}/services/#{@service}/edit?return_to=show"
            }
          >
            <.icon name="hero-pencil-square" /> Edit service
          </.button>
        </:actions>
      </.header>

      <.list>
        <:item title="Name">{@service.name}</:item>
        <:item title="Description">{@service.description}</:item>
        <:item title="Environment">{@service.environment}</:item>
        <:item title="Url">{@service.url}</:item>
        <:item title="Check interval ms">{@service.check_interval_ms}</:item>
        <:item title="Timeout ms">{@service.timeout_ms}</:item>
        <:item title="Enabled">{@service.enabled}</:item>
        <:item title="Status">{@service.status}</:item>
        <:item title="Last checked at">{@service.last_checked_at}</:item>
      </.list>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Monitoring.subscribe_services(socket.assigns.current_scope)
    end

    {:ok,
     socket
     |> assign(:page_title, "Show Service")
     |> assign(:service, Monitoring.get_service!(socket.assigns.current_scope, id))}
  end

  @impl true
  def handle_info(
        {:updated, %PulseOps.Monitoring.Service{id: id} = service},
        %{assigns: %{service: %{id: id}}} = socket
      ) do
    {:noreply, assign(socket, :service, service)}
  end

  def handle_info(
        {:deleted, %PulseOps.Monitoring.Service{id: id}},
        %{assigns: %{service: %{id: id}}} = socket
      ) do
    {:noreply,
     socket
     |> put_flash(:error, "The current service was deleted.")
     |> push_navigate(to: ~p"/orgs/#{socket.assigns.current_scope.organization.slug}/services")}
  end

  def handle_info({type, %PulseOps.Monitoring.Service{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply, socket}
  end
end
