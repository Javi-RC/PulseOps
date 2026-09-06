defmodule PulseOpsWeb.DashboardLive do
  @moduledoc """
  The live status of every service in the organization.

  There is no polling here. The page subscribes to the organization's service and
  incident topics on connect, and the monitors push a message when — and only
  when — something actually changed.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.MonitoringComponents

  alias PulseOps.Incidents
  alias PulseOps.Monitoring

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
     |> load_dashboard()}
  end

  # Any change on either topic re-reads the summary. The alternative — patching
  # the assigns from the message payload — would drift out of step with the
  # database the first time two changes raced.
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
    {:noreply, load_dashboard(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_dashboard(socket) do
    scope = socket.assigns.current_scope

    services = Monitoring.list_services(scope)
    uptime = Monitoring.uptime_by_service(scope)
    incidents = Incidents.list_active_incidents(scope)

    socket
    |> assign(:services, Enum.sort_by(services, &{status_rank(&1.status), &1.name}))
    |> assign(:uptime, uptime)
    |> assign(:incidents, incidents)
    |> assign(:overall, overall_status(services))
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
      <div class="mb-6 flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 class="text-2xl font-semibold">{@current_scope.organization.name}</h1>
          <p class="mt-1 text-sm text-base-content/60">
            Live status · updates arrive over the socket, nothing is polled
          </p>
        </div>
        <.status_badge status={@overall} class="text-lg" />
      </div>

      <section class="mb-8">
        <div class="mb-3 flex items-center justify-between">
          <h2 class="text-lg font-medium">Services</h2>
          <.link
            navigate={~p"/orgs/#{@current_scope.organization.slug}/services"}
            class="link text-sm"
          >
            Manage services
          </.link>
        </div>

        <div
          :if={@services == []}
          class="rounded-lg border border-dashed border-base-300 p-8 text-center"
        >
          <p class="text-base-content/60">No services yet.</p>
          <.link
            navigate={~p"/orgs/#{@current_scope.organization.slug}/services/new"}
            class="btn btn-primary btn-sm mt-4"
          >
            Add the first one
          </.link>
        </div>

        <ul :if={@services != []} class="divide-y divide-base-300 rounded-lg border border-base-300">
          <li :for={service <- @services} class="flex flex-wrap items-center gap-4 px-4 py-3">
            <div class="min-w-0 flex-1">
              <.link
                navigate={~p"/orgs/#{@current_scope.organization.slug}/services/#{service}"}
                class="font-medium hover:underline"
              >
                {service.name}
              </.link>
              <div class="text-xs text-base-content/50">
                {service.environment} · checked <.relative_time at={service.last_checked_at} />
              </div>
            </div>

            <div class="w-24 text-right text-sm tabular-nums text-base-content/70">
              {format_percent(@uptime[service.id])}
            </div>

            <.status_badge status={service.status} class="w-28" />
          </li>
        </ul>
      </section>

      <section>
        <h2 class="mb-3 text-lg font-medium">
          Active incidents
          <span :if={@incidents != []} class="ml-1 text-base-content/50">({length(@incidents)})</span>
        </h2>

        <p
          :if={@incidents == []}
          class="rounded-lg border border-base-300 p-6 text-center text-sm text-base-content/60"
        >
          Nothing is on fire.
        </p>

        <ul :if={@incidents != []} class="divide-y divide-base-300 rounded-lg border border-base-300">
          <li :for={incident <- @incidents} class="flex flex-wrap items-center gap-4 px-4 py-3">
            <.severity_tag severity={incident.severity} />
            <div class="min-w-0 flex-1">
              <.link
                navigate={~p"/orgs/#{@current_scope.organization.slug}/incidents/#{incident}"}
                class="font-medium hover:underline"
              >
                {incident.title}
              </.link>
              <div class="text-xs text-base-content/50">
                Started <.relative_time at={incident.started_at} />
                · {incident_status_label(incident.status)}
              </div>
            </div>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end
end
