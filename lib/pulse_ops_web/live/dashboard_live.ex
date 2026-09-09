defmodule PulseOpsWeb.DashboardLive do
  @moduledoc """
  The live status of every service in the organization.

  There is no polling here. The page subscribes to the organization's service and
  incident topics on connect, and the monitors push a message when — and only
  when — something actually changed.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.MonitoringComponents
  import PulseOpsWeb.UIComponents

  alias PulseOps.Incidents
  alias PulseOps.Monitoring
  alias PulseOps.Organizations

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Monitoring.subscribe_services(scope)
      Incidents.subscribe_incidents(scope)
    end

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:now, DateTime.utc_now())
     |> schedule_tick()
     |> assign(:can_manage?, Organizations.can?(scope, :manage_services))
     |> assign(:reload_pending?, false)
     |> load_dashboard()}
  end

  # Any change on either topic re-reads the summary. The alternative — patching
  # the assigns from the message payload — would drift out of step with the
  # database the first time two changes raced.
  #
  # The re-read is deferred rather than immediate, because a broadcast arrives
  # per status change per viewer and the summary costs four queries, one of them
  # aggregating a day of raw checks. A flapping service with several dashboards
  # open multiplies that out; coalescing a burst into one reload cuts it back to
  # one regardless of how many messages arrived.
  @impl true
  def handle_info({event, _payload}, socket)
      when event in [
             :created,
             :updated,
             :deleted,
             :incident_opened,
             :incident_updated,
             :incident_resolved
           ] do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:reload, socket) do
    {:noreply, socket |> assign(:reload_pending?, false) |> load_dashboard()}
  end

  def handle_info(:tick, socket) do
    {:noreply, socket |> assign(:now, DateTime.utc_now()) |> schedule_tick()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Every broadcast that arrives while a reload is already queued is absorbed by
  # the one already pending, so a burst of N messages costs one reload.
  defp schedule_reload(%{assigns: %{reload_pending?: true}} = socket), do: socket

  defp schedule_reload(socket) do
    case debounce_ms() do
      # No window: re-read inside this callback. Deferring by a message instead
      # would land behind a render call already sitting in the mailbox, which is
      # a race for anything observing the page right after a broadcast.
      ms when ms <= 0 ->
        load_dashboard(socket)

      ms ->
        Process.send_after(self(), :reload, ms)
        assign(socket, :reload_pending?, true)
    end
  end

  defp debounce_ms, do: Application.get_env(:pulse_ops, :dashboard_debounce_ms, 250)
  # The only timer on these pages, and it touches nothing but the clock: without
  # it a "3 min ago" label sits frozen until the next broadcast happens to
  # arrive. It issues no queries, so it is not polling.
  @tick_ms 30_000

  defp schedule_tick(socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @tick_ms)
    socket
  end

  defp load_dashboard(socket) do
    scope = socket.assigns.current_scope

    services = Monitoring.list_services(scope)

    socket
    |> assign(:services, Enum.sort_by(services, &{status_rank(&1.status), &1.name}))
    |> assign(:uptime, Monitoring.uptime_by_service(scope))
    |> assign(:history, Monitoring.recent_checks_by_service(scope))
    |> assign(:incidents, Incidents.list_active_incidents(scope))
    |> assign(:overall, overall_status(services))
    |> assign(:counts, Enum.frequencies_by(services, & &1.status))
  end

  # Anything wrong floats to the top of the list: the reason to open this page is
  # to find what is broken.
  defp status_rank(:down), do: 0
  defp status_rank(:degraded), do: 1
  defp status_rank(:unknown), do: 2
  defp status_rank(:healthy), do: 3

  defp overall_status([]), do: :unknown

  defp overall_status(services) do
    services
    |> Enum.map(& &1.status)
    |> Enum.min_by(&status_rank/1)
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
      <.page_header title={@current_scope.organization.name}>
        <:subtitle>
          Live status. Updates arrive over the socket — nothing on this page polls.
        </:subtitle>
        <:actions>
          <.status_badge status={@overall} class="rounded-full border border-base-300 px-3 py-1.5" />
        </:actions>
      </.page_header>

      <div :if={@services != []} class="mb-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <.stat_tile label="Services" value={to_string(length(@services))} />
        <.stat_tile
          label="Healthy"
          value={to_string(Map.get(@counts, :healthy, 0))}
          hint={"of #{length(@services)}"}
        />
        <.stat_tile label="Degraded" value={to_string(Map.get(@counts, :degraded, 0))} />
        <.stat_tile label="Down" value={to_string(Map.get(@counts, :down, 0))} />
      </div>

      <section class="mb-8">
        <div class="mb-3 flex items-center justify-between">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Services
          </h2>
          <.link
            navigate={~p"/orgs/#{@current_scope.organization.slug}/services"}
            class="text-sm text-base-content/60 hover:underline"
          >
            Manage
          </.link>
        </div>

        <.empty_state
          :if={@services == []}
          icon="lucide-server"
          title="Nothing is being watched yet"
        >
          <:subtitle>
            Register an endpoint and PulseOps starts probing it from its own supervised process.
          </:subtitle>
          <:actions>
            <.link
              :if={@can_manage?}
              navigate={~p"/orgs/#{@current_scope.organization.slug}/services/new"}
              class="btn btn-primary btn-sm"
            >
              Add the first service
            </.link>
          </:actions>
        </.empty_state>

        <div :if={@services != []} class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
          <.link
            :for={service <- @services}
            navigate={~p"/orgs/#{@current_scope.organization.slug}/services/#{service}"}
            id={"service-#{service.id}"}
            class="rounded-box border border-base-300 bg-base-100 p-4 transition-shadow hover:shadow-md"
          >
            <div class="flex items-start justify-between gap-2">
              <div class="min-w-0">
                <div class="truncate font-medium">{service.name}</div>
                <div class="text-xs text-base-content/50">{service.environment}</div>
              </div>
              <.status_badge status={service.status} />
            </div>

            <div class="mt-3">
              <.uptime_bar checks={Map.get(@history, service.id, [])} />
            </div>

            <div class="mt-3 flex items-center justify-between text-xs text-base-content/50">
              <span class="tabular-nums">{format_percent(@uptime[service.id])} · 24h</span>
              <.relative_time now={@now} at={service.last_checked_at} />
            </div>
          </.link>
        </div>
      </section>

      <section>
        <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-base-content/60">
          Active incidents
          <span :if={@incidents != []} class="ml-1 normal-case text-base-content/40">
            ({length(@incidents)})
          </span>
        </h2>

        <.empty_state :if={@incidents == []} icon="lucide-circle-check" title="Nothing is on fire">
          <:subtitle>Incidents open automatically when a service stops answering.</:subtitle>
        </.empty_state>

        <.card :if={@incidents != []} padded={false}>
          <ul class="divide-y divide-base-300">
            <li :for={incident <- @incidents} class="flex flex-wrap items-center gap-3 px-4 py-3">
              <.severity_tag severity={incident.severity} />
              <div class="min-w-0 flex-1">
                <.link
                  navigate={~p"/orgs/#{@current_scope.organization.slug}/incidents/#{incident}"}
                  class="font-medium hover:underline"
                >
                  {incident.title}
                </.link>
                <div class="text-xs text-base-content/50">
                  Started <.relative_time now={@now} at={incident.started_at} />
                  · {incident_status_label(incident.status)}
                </div>
              </div>
            </li>
          </ul>
        </.card>
      </section>
    </Layouts.app>
    """
  end
end
