defmodule PulseOpsWeb.StatusPageLive do
  @moduledoc """
  An organization's public status page, at `/status/:slug`.

  Mounted outside `live_session :require_organization`, because the whole point
  is that nobody signs in. `PulseOps.StatusPage` is the only context it talks
  to, and that context decides what a stranger may see — this module has no
  filtering of its own to forget.

  It subscribes to the same PubSub topics the signed-in dashboard uses, so an
  outage reaches a reader's open tab as fast as it reaches the on-call
  dashboard, over a connection that is already there.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.MonitoringComponents

  alias PulseOps.StatusPage

  @tick_ms 30_000

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case StatusPage.get_organization(slug) do
      nil ->
        # Indistinguishable from a slug that was never taken: a stranger cannot
        # use this page to find out who has an account here.
        raise PulseOpsWeb.StatusPageLive.NotFound

      organization ->
        if connected?(socket), do: StatusPage.subscribe(organization)

        {:ok,
         socket
         |> assign(:page_title, "#{organization.name} status")
         |> assign(:organization, organization)
         |> assign(:now, DateTime.utc_now())
         |> schedule_tick()
         |> load()}
    end
  end

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
    {:noreply, load(socket)}
  end

  def handle_info(:tick, socket) do
    {:noreply, socket |> assign(:now, DateTime.utc_now()) |> schedule_tick()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp schedule_tick(socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @tick_ms)
    socket
  end

  defp load(socket) do
    overview = StatusPage.overview(socket.assigns.organization)

    socket
    |> assign(:services, overview.services)
    |> assign(:uptime, overview.uptime)
    |> assign(:history, overview.history)
    |> assign(:active_incidents, overview.active_incidents)
    |> assign(:past_incidents, overview.past_incidents)
    |> assign(:maintenance, overview.maintenance)
    |> assign(:maintenance_by_service, overview.maintenance_by_service)
    |> assign(:overall, overview.overall)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.public flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto w-full max-w-4xl px-4 py-10 sm:px-6">
        <header class="mb-8">
          <h1 class="text-2xl font-semibold tracking-tight">{@organization.name}</h1>
          <p :if={@organization.status_page_headline} class="mt-1 text-sm text-base-content/60">
            {@organization.status_page_headline}
          </p>
        </header>

        <section class={[
          "mb-8 flex items-center gap-3 rounded-box border p-4 sm:p-5",
          banner_class(assigns, @overall)
        ]}>
          <.icon name={banner_icon(assigns, @overall)} class="size-6 shrink-0" />
          <div>
            <p class="font-medium">{headline(assigns, @overall)}</p>
            <p class="text-sm opacity-70">
              Updated <.relative_time at={latest_check(@services)} now={@now} />
            </p>
          </div>
        </section>

        <section :if={@maintenance != []} class="mb-8">
          <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Planned maintenance
          </h2>
          <ul class="space-y-2">
            <li
              :for={window <- @maintenance}
              class="rounded-box border border-info/40 bg-info/5 p-4"
            >
              <div class="flex flex-wrap items-center justify-between gap-2">
                <span class="font-medium">{window.reason}</span>
                <span class="text-sm text-base-content/60">
                  until {Calendar.strftime(window.ends_at, "%d %b %H:%M")} UTC
                </span>
              </div>
            </li>
          </ul>
        </section>

        <section :if={@active_incidents != []} class="mb-8">
          <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Open incidents
          </h2>
          <ul class="space-y-2">
            <li
              :for={incident <- @active_incidents}
              class="rounded-box border border-error/40 bg-error/5 p-4"
            >
              <div class="flex flex-wrap items-center justify-between gap-2">
                <span class="font-medium">{incident.title}</span>
                <.severity_tag severity={incident.severity} />
              </div>
              <p class="mt-1 text-sm text-base-content/60">
                Started
                <.relative_time at={incident.started_at} now={@now} />, ongoing for {format_duration(
                  DateTime.diff(@now, incident.started_at)
                )}
              </p>
            </li>
          </ul>
        </section>

        <section class="mb-8">
          <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Services
          </h2>

          <p
            :if={@services == []}
            class="rounded-box border border-base-300 p-6 text-sm text-base-content/60"
          >
            Nothing is published here yet.
          </p>

          <ul
            :if={@services != []}
            class="divide-y divide-base-300 rounded-box border border-base-300"
          >
            <li :for={service <- @services} class="p-4 sm:p-5">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <div class="min-w-0">
                  <p class="font-medium">{service.name}</p>
                  <p :if={service.description} class="text-sm text-base-content/60">
                    {service.description}
                  </p>
                </div>
                <div class="flex items-center gap-2">
                  <span
                    :if={Map.has_key?(@maintenance_by_service, service.id)}
                    class="badge badge-sm badge-info"
                  >
                    Maintenance
                  </span>
                  <.status_badge status={service.status} />
                </div>
              </div>

              <div class="mt-3 flex flex-wrap items-center gap-4">
                <.uptime_bar checks={Map.get(@history, service.id, [])} />
                <span class="text-sm tabular-nums text-base-content/60">
                  {format_percent(Map.get(@uptime, service.id))} over 24h
                </span>
              </div>
            </li>
          </ul>
        </section>

        <section :if={@past_incidents != []}>
          <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Recent history
          </h2>
          <ul class="divide-y divide-base-300 rounded-box border border-base-300">
            <li
              :for={incident <- @past_incidents}
              class="flex flex-wrap items-center justify-between gap-2 p-4"
            >
              <div class="min-w-0">
                <p class="text-sm font-medium">{incident.title}</p>
                <p class="text-xs text-base-content/50">
                  {format_duration(DateTime.diff(incident.resolved_at, incident.started_at))}, resolved
                  <.relative_time at={incident.resolved_at} now={@now} />
                </p>
              </div>
              <.severity_tag severity={incident.severity} />
            </li>
          </ul>
        </section>

        <footer class="mt-10 text-center text-xs text-base-content/40">
          Status by <.link navigate={~p"/"} class="link">PulseOps</.link>
        </footer>
      </div>
    </Layouts.public>
    """
  end

  defp latest_check(services) do
    services
    |> Enum.map(& &1.last_checked_at)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      times -> Enum.max(times, DateTime)
    end
  end

  # A service that is down inside a maintenance window is not an outage anybody
  # needs to report, so the banner says so rather than shouting.
  defp headline(%{maintenance: [_ | _]}, :down), do: "Down for planned maintenance"
  defp headline(%{maintenance: [_ | _]}, :degraded), do: "Degraded during planned maintenance"
  defp headline(_assigns, overall), do: overall_headline(overall)

  defp banner_class(%{maintenance: [_ | _]}, overall) when overall in [:down, :degraded],
    do: "border-info/40 bg-info/5 text-info"

  defp banner_class(_assigns, overall), do: overall_class(overall)

  defp banner_icon(%{maintenance: [_ | _]}, overall) when overall in [:down, :degraded],
    do: "lucide-calendar-clock"

  defp banner_icon(_assigns, overall), do: overall_icon(overall)

  defp overall_headline(:healthy), do: "All systems operational"
  defp overall_headline(:degraded), do: "Some systems are degraded"
  defp overall_headline(:down), do: "We are having an outage"
  defp overall_headline(:unknown), do: "Status not yet known"

  defp overall_icon(:healthy), do: "lucide-circle-check"
  defp overall_icon(:degraded), do: "lucide-triangle-alert"
  defp overall_icon(:down), do: "lucide-circle-x"
  defp overall_icon(:unknown), do: "lucide-circle-help"

  defp overall_class(:healthy), do: "border-success/40 bg-success/5 text-success"
  defp overall_class(:degraded), do: "border-warning/40 bg-warning/5 text-warning"
  defp overall_class(:down), do: "border-error/40 bg-error/5 text-error"
  defp overall_class(:unknown), do: "border-base-300 bg-base-100"
end
