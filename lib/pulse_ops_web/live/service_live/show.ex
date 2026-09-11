defmodule PulseOpsWeb.ServiceLive.Show do
  @moduledoc """
  One service: its current status, its latency over the recent checks, and the
  incidents it has caused.

  This is the only page that subscribes to a service's individual check results.
  The dashboard would re-render on every probe if it did the same.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.MonitoringComponents
  import PulseOpsWeb.UIComponents

  alias PulseOps.Incidents
  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.Service
  alias PulseOps.Organizations

  @chart_points 60

  # The windows the figures can be read over. Thirty days used to be out of the
  # question — it meant aggregating a month of raw checks per page view — and is
  # cheap now that complete hours come from rollups (ADR-010).
  @windows [{"24h", 24}, {"7d", 24 * 7}, {"30d", 24 * 30}]
  @default_window "24h"

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    service = Monitoring.get_service!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Monitoring.subscribe_services(socket.assigns.current_scope)
      Monitoring.subscribe_checks(socket.assigns.current_scope, service)
      Incidents.subscribe_incidents(socket.assigns.current_scope)
    end

    {:ok,
     socket
     |> assign(:page_title, service.name)
     |> assign(:service, service)
     |> assign(:windows, Enum.map(@windows, &elem(&1, 0)))
     |> assign(:window, @default_window)
     |> assign(
       :can_manage?,
       Organizations.can?(socket.assigns.current_scope, :manage_services)
     )
     |> assign(:demo_target?, demo_target?(service))}
  end

  # The window lives in the URL, so a 30-day view can be linked and survives a
  # reload. An unknown value falls back to the default rather than erroring: it
  # is a view preference, not something worth a 400.
  @impl true
  def handle_params(params, _uri, socket) do
    window =
      case params["window"] do
        window when is_binary(window) ->
          if(window_hours(window), do: window, else: @default_window)

        _missing ->
          @default_window
      end

    {:noreply, socket |> assign(:window, window) |> load_history()}
  end

  @impl true
  def handle_info(
        {:updated, %Service{id: id} = service},
        %{assigns: %{service: %{id: id}}} = socket
      ) do
    {:noreply, socket |> assign(:service, service) |> load_history()}
  end

  def handle_info({:deleted, %Service{id: id}}, %{assigns: %{service: %{id: id}}} = socket) do
    {:noreply,
     socket
     |> put_flash(:error, "The current service was deleted.")
     |> push_navigate(to: ~p"/orgs/#{socket.assigns.current_scope.organization.slug}/services")}
  end

  # A new probe result: refresh the plot and the figures.
  def handle_info({:check_recorded, _check}, socket), do: {:noreply, load_history(socket)}

  def handle_info({event, _payload}, socket)
      when event in [
             :created,
             :updated,
             :deleted,
             :incident_opened,
             :incident_updated,
             :incident_resolved
           ] do
    {:noreply, load_history(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # The demo controls only exist in development, and only for the service that
  # points at the endpoint whose behaviour can be changed. They call the agent
  # directly: a LiveView event needs no HTTP round trip, and the browser
  # pipeline's CSRF protection would reject a plain form post anyway.
  @impl true
  def handle_event("break_demo_service", _params, socket) do
    if socket.assigns.demo_target?, do: PulseOpsWeb.Flaky.break()
    {:noreply, put_flash(socket, :info, "The endpoint is now failing. Watch the status change.")}
  end

  def handle_event("heal_demo_service", _params, socket) do
    if socket.assigns.demo_target?, do: PulseOpsWeb.Flaky.heal()
    {:noreply, put_flash(socket, :info, "The endpoint is answering again.")}
  end

  defp demo_target?(service) do
    Application.get_env(:pulse_ops, :dev_routes, false) and
      String.contains?(service.url, "/dev/flaky")
  end

  defp load_history(socket) do
    scope = socket.assigns.current_scope
    service = socket.assigns.service
    since = DateTime.add(DateTime.utc_now(), -window_hours(socket.assigns.window) * 3600, :second)

    socket
    |> assign(:checks, Monitoring.list_checks_for_chart(scope, service, @chart_points))
    |> assign(:metrics, Monitoring.service_metrics(scope, service, since: since))
    |> assign(:open_incident, Incidents.get_open_incident(service))
    # A registry lookup, so it is cheap enough to refresh with everything else —
    # and it has to be refreshed, because a monitor can be abandoned while the
    # page is open.
    |> assign(:monitor_state, Monitoring.monitor_state(service))
  end

  defp window_hours(window) do
    Enum.find_value(@windows, fn {label, hours} -> if label == window, do: hours end)
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
      <.breadcrumb>
        <:item navigate={~p"/orgs/#{@current_scope.organization.slug}/services"}>Services</:item>
        <:item>{@service.name}</:item>
      </.breadcrumb>

      <.page_header title={@service.name}>
        <:subtitle>
          {@service.environment}
          <span class="text-base-content/30">·</span>
          <a
            href={@service.url}
            target="_blank"
            rel="noreferrer"
            class="link break-all text-base-content/60"
          >
            {@service.url}
          </a>
          <span :if={@service.description}>
            <span class="text-base-content/30">·</span> {@service.description}
          </span>
        </:subtitle>
        <:actions>
          <.status_badge
            status={@service.status}
            class="rounded-full border border-base-300 px-3 py-1"
          />
          <.button
            :if={@can_manage?}
            navigate={
              ~p"/orgs/#{@current_scope.organization.slug}/services/#{@service}/edit?return_to=show"
            }
            size="sm"
          >
            Edit
          </.button>
        </:actions>
      </.page_header>

      <div
        :if={@monitor_state == :stopped}
        id="monitor-stopped"
        class="mb-6 flex items-start gap-3 rounded-box border border-error/40 bg-error/5 p-4 text-error"
      >
        <.icon name="lucide-eye-off" class="size-5 shrink-0" />
        <div>
          <p class="font-medium">Nothing is watching this service</p>
          <p class="text-sm opacity-80">
            It is enabled, but its monitor is not running — usually because it crashed too many
            times in a row and was given up on. The status shown is the last one recorded, not a
            current one. Saving the service starts a fresh monitor.
          </p>
        </div>
      </div>

      <p
        :if={@monitor_state == :disabled}
        id="monitor-disabled"
        class="mb-6 text-sm text-base-content/60"
      >
        Monitoring is paused for this service. The figures below stop at the last check.
      </p>

      <div
        :if={@open_incident}
        class="mb-6 flex flex-wrap items-center gap-3 rounded-lg border border-base-300 p-4"
      >
        <.severity_tag severity={@open_incident.severity} />
        <div class="min-w-0 flex-1 text-sm">
          Open incident since <.relative_time at={@open_incident.started_at} />
        </div>
        <.button
          navigate={~p"/orgs/#{@current_scope.organization.slug}/incidents/#{@open_incident}"}
          size="sm"
        >
          Open incident
        </.button>
      </div>

      <.card :if={@demo_target?} class="mb-6 border-dashed">
        <div class="flex flex-wrap items-center gap-3">
          <.icon name="lucide-flask-conical" class="size-5 text-base-content/40" />
          <div class="min-w-0 flex-1 text-sm">
            <span class="font-medium">Demo controls</span>
            <.badge size="xs" class="ml-1 align-middle">Development only</.badge>
            <span class="text-base-content/60">
              — break this endpoint on purpose and watch an incident open by itself.
            </span>
          </div>
          <.button phx-click="break_demo_service" size="sm">Break it</.button>
          <.button phx-click="heal_demo_service" size="sm">Fix it</.button>
        </div>
      </.card>

      <div class="mb-3 flex justify-end">
        <.window_selector
          windows={@windows}
          selected={@window}
          href_fn={&window_route(@current_scope, @service, &1)}
        />
      </div>

      <div class="mb-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <.stat_tile
          label={"Uptime (#{@window})"}
          value={format_percent(@metrics.uptime_percent)}
          hint={"#{@metrics.total} checks"}
        />
        <.stat_tile label={"p50 (#{@window})"} value={format_ms(@metrics.p50)} />
        <.stat_tile label={"p95 (#{@window})"} value={format_ms(@metrics.p95)} />
        <.stat_tile label={"p99 (#{@window})"} value={format_ms(@metrics.p99)} />
      </div>

      <div
        :if={tls_notice(@service)}
        class={["mb-6 flex items-start gap-3 rounded-box border p-4", tls_class(@service)]}
      >
        <.icon name="lucide-shield-alert" class="size-5 shrink-0" />
        <div>
          <p class="font-medium">{tls_notice(@service)}</p>
          <p class="text-sm opacity-70">
            Nothing is wrong with the service right now — this is the one outage that announces
            itself in advance.
          </p>
        </div>
      </div>

      <section class="mb-8 rounded-lg border border-base-300 p-4">
        <.response_time_chart id={"chart-#{@service.id}"} checks={@checks} />
      </section>

      <section class="mb-8">
        <.section_heading title="Recent checks" />
        <.uptime_bar checks={@checks} />
        <p class="mt-2 text-xs text-base-content/50">
          The last {length(@checks)} probes, oldest to newest, whatever window the figures above
          use · checked every {div(@service.check_interval_ms, 1000)}s
        </p>
      </section>
    </Layouts.app>
    """
  end

  defp window_route(scope, service, window) do
    ~p"/orgs/#{scope.organization.slug}/services/#{service}?window=#{window}"
  end

  # Only says something when there is something to say: a certificate with
  # months left is not news, and a service never checked has no date to report.
  defp tls_notice(service) do
    if Monitoring.tls_expiring?(service) do
      case Monitoring.tls_days_left(service) do
        days when days < 0 -> "The TLS certificate expired #{abs(days)} days ago"
        0 -> "The TLS certificate expires today"
        days -> "The TLS certificate expires in #{days} days"
      end
    end
  end

  defp tls_class(service) do
    if Monitoring.tls_days_left(service) < 0 do
      "border-error/40 bg-error/5 text-error"
    else
      "border-warning/40 bg-warning/5 text-warning"
    end
  end
end
