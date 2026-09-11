defmodule PulseOpsWeb.ServiceLive.Index do
  @moduledoc """
  Every service in the organization, with what a reader actually wants at a
  glance: whether it is up, how reliable it has been, and when it was last seen.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.MonitoringComponents
  import PulseOpsWeb.UIComponents

  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.Service
  alias PulseOps.Organizations

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket), do: Monitoring.subscribe_services(scope)

    {:ok,
     socket
     |> assign(:page_title, "Services")
     |> assign(:now, DateTime.utc_now())
     |> schedule_tick()
     |> assign(:environment_filter, :all)
     |> assign(:status_filter, :all)
     |> assign(:can_manage?, Organizations.can?(scope, :manage_services))
     |> load_services()}
  end

  @impl true
  def handle_info({type, %Service{}}, socket) when type in [:created, :updated, :deleted] do
    {:noreply, load_services(socket)}
  end

  def handle_info(:tick, socket) do
    {:noreply, socket |> assign(:now, DateTime.utc_now()) |> schedule_tick()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
  # The only timer on these pages, and it touches nothing but the clock: without
  # it a "3 min ago" label sits frozen until the next broadcast happens to
  # arrive. It issues no queries, so it is not polling.
  @tick_ms 30_000

  defp schedule_tick(socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @tick_ms)
    socket
  end

  @impl true
  def handle_event("filter", %{"key" => "environment", "value" => value}, socket) do
    {:noreply, socket |> assign(:environment_filter, to_filter(value)) |> apply_filters()}
  end

  def handle_event("filter", %{"key" => "status", "value" => value}, socket) do
    {:noreply, socket |> assign(:status_filter, to_filter(value)) |> apply_filters()}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    service = Monitoring.get_service!(socket.assigns.current_scope, id)

    case Monitoring.delete_service(socket.assigns.current_scope, service) do
      {:ok, _service} ->
        {:noreply, socket |> put_flash(:info, "#{service.name} deleted.") |> load_services()}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to delete services.")}
    end
  end

  defp to_filter("all"), do: :all
  defp to_filter(value), do: String.to_existing_atom(value)

  defp load_services(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:services, Monitoring.list_services(scope))
    |> assign(:uptime, Monitoring.uptime_by_service(scope))
    |> apply_filters()
  end

  defp apply_filters(socket) do
    %{
      services: services,
      environment_filter: environment,
      status_filter: status
    } = socket.assigns

    visible =
      services
      |> Enum.filter(fn service ->
        (environment == :all or service.environment == environment) and
          (status == :all or service.status == status)
      end)
      |> Enum.sort_by(&{status_rank(&1.status), &1.name})

    assign(socket, :visible_services, visible)
  end

  # Whatever is wrong comes first: that is why somebody opens this page.
  defp status_rank(:down), do: 0
  defp status_rank(:degraded), do: 1
  defp status_rank(:unknown), do: 2
  defp status_rank(:healthy), do: 3

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
      <.page_header title="Services">
        <:subtitle>
          {length(@services)} monitored in {@current_scope.organization.name}.
        </:subtitle>
        <:actions>
          <.button
            :if={@can_manage?}
            navigate={~p"/orgs/#{@current_scope.organization.slug}/services/new"}
            variant="primary"
            size="sm"
          >
            <.icon name="lucide-plus" class="size-4" /> New service
          </.button>
        </:actions>
      </.page_header>

      <.filter_bar :if={@services != []}>
        <span class="text-xs font-medium uppercase tracking-wide text-base-content/50">Status</span>
        <.filter_chip
          label="All"
          active={@status_filter == :all}
          phx-click="filter"
          phx-value-key="status"
          phx-value-value="all"
        />
        <.filter_chip
          :for={status <- Service.statuses()}
          label={status_meta(status).label}
          active={@status_filter == status}
          phx-click="filter"
          phx-value-key="status"
          phx-value-value={status}
        />

        <span class="ml-2 text-xs font-medium uppercase tracking-wide text-base-content/50">
          Environment
        </span>
        <.filter_chip
          label="All"
          active={@environment_filter == :all}
          phx-click="filter"
          phx-value-key="environment"
          phx-value-value="all"
        />
        <.filter_chip
          :for={environment <- Service.environments()}
          label={String.capitalize(to_string(environment))}
          active={@environment_filter == environment}
          phx-click="filter"
          phx-value-key="environment"
          phx-value-value={environment}
        />
      </.filter_bar>

      <.empty_state :if={@services == []} icon="lucide-server" title="No services yet">
        <:subtitle>
          Register an endpoint and PulseOps starts watching it from its own supervised process.
        </:subtitle>
        <:actions>
          <.button
            :if={@can_manage?}
            navigate={~p"/orgs/#{@current_scope.organization.slug}/services/new"}
            variant="primary"
            size="sm"
          >
            Add the first one
          </.button>
        </:actions>
      </.empty_state>

      <.empty_state
        :if={@services != [] and @visible_services == []}
        icon="lucide-filter"
        title="Nothing matches these filters"
      >
        <:subtitle>Try widening the status or environment filter.</:subtitle>
      </.empty_state>

      <.card :if={@visible_services != []} padded={false} class="overflow-hidden">
        <ul class="divide-y divide-base-300">
          <%!-- On a phone the status and uptime fold under the name, instead of
                wrapping onto a ragged second row of their own. --%>
          <li
            :for={service <- @visible_services}
            id={"service-#{service.id}"}
            class="flex items-start gap-3 px-4 py-3 hover:bg-base-200/50 sm:items-center sm:gap-4"
          >
            <.status_badge status={service.status} class="w-28 shrink-0 max-sm:hidden" />

            <div class="min-w-0 flex-1">
              <.link
                navigate={~p"/orgs/#{@current_scope.organization.slug}/services/#{service}"}
                class="font-medium hover:underline"
              >
                {service.name}
              </.link>
              <div class="truncate text-xs text-base-content/50">
                {service.environment} · every {seconds(service.check_interval_ms)} · {service.url}
              </div>
              <div class="mt-1 flex items-center gap-2 text-xs sm:hidden">
                <.status_badge status={service.status} />
                <span class="tabular-nums text-base-content/60">
                  {format_percent(@uptime[service.id])} · 24h
                </span>
              </div>
            </div>

            <div class="w-20 shrink-0 text-right max-sm:hidden">
              <div class="text-sm tabular-nums">{format_percent(@uptime[service.id])}</div>
              <div class="text-xs text-base-content/40">24h</div>
            </div>

            <div class="hidden w-28 shrink-0 text-right text-xs text-base-content/50 md:block">
              <.relative_time now={@now} at={service.last_checked_at} />
            </div>

            <div :if={@can_manage?} class="flex shrink-0 items-center gap-1">
              <span
                :if={not service.enabled}
                class="rounded bg-base-300 px-1.5 py-0.5 text-xs text-base-content/60"
              >
                Paused
              </span>
              <.button
                navigate={~p"/orgs/#{@current_scope.organization.slug}/services/#{service}/edit"}
                variant="ghost"
                size="xs"
                aria-label={"Edit #{service.name}"}
              >
                <.icon name="lucide-pencil" class="size-4" />
              </.button>
              <.button
                phx-click="delete"
                phx-value-id={service.id}
                data-confirm={"Delete #{service.name}? Its checks and incidents go with it."}
                data-confirm-label="Delete service"
                variant="danger-ghost"
                size="xs"
                aria-label={"Delete #{service.name}"}
              >
                <.icon name="lucide-trash" class="size-4" />
              </.button>
            </div>
          </li>
        </ul>
      </.card>
    </Layouts.app>
    """
  end

  defp seconds(ms) when ms >= 60_000, do: "#{div(ms, 60_000)} min"
  defp seconds(ms), do: "#{div(ms, 1000)} s"
end
