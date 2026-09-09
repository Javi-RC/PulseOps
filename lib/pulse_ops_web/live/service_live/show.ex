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
     |> assign(
       :can_manage?,
       Organizations.can?(socket.assigns.current_scope, :manage_services)
     )
     |> assign(:demo_target?, demo_target?(service))
     |> load_history()}
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

    socket
    |> assign(:checks, Monitoring.list_checks_for_chart(scope, service, @chart_points))
    |> assign(:metrics, Monitoring.service_metrics(scope, service))
    |> assign(:open_incident, Incidents.get_open_incident(service))
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
      <.link
        navigate={~p"/orgs/#{@current_scope.organization.slug}/services"}
        class="text-sm text-base-content/60 hover:underline"
      >
        &larr; All services
      </.link>

      <div class="mt-2 mb-6 flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold">{@service.name}</h1>
          <p class="mt-1 text-sm text-base-content/60">
            {@service.environment} ·
            <a href={@service.url} class="link" target="_blank" rel="noreferrer">{@service.url}</a>
          </p>
          <p :if={@service.description} class="mt-1 text-sm text-base-content/60">
            {@service.description}
          </p>
        </div>

        <div class="flex items-center gap-3">
          <.status_badge status={@service.status} class="text-lg" />
          <.link
            :if={@can_manage?}
            navigate={
              ~p"/orgs/#{@current_scope.organization.slug}/services/#{@service}/edit?return_to=show"
            }
            class="btn btn-sm"
          >
            Edit
          </.link>
        </div>
      </div>

      <div
        :if={@open_incident}
        class="mb-6 flex flex-wrap items-center gap-3 rounded-lg border border-base-300 p-4"
      >
        <.severity_tag severity={@open_incident.severity} />
        <div class="min-w-0 flex-1 text-sm">
          Open incident since <.relative_time at={@open_incident.started_at} />
        </div>
        <.link
          navigate={~p"/orgs/#{@current_scope.organization.slug}/incidents/#{@open_incident}"}
          class="btn btn-sm"
        >
          Open incident
        </.link>
      </div>

      <.card :if={@demo_target?} class="mb-6 border-dashed">
        <div class="flex flex-wrap items-center gap-3">
          <.icon name="lucide-flask-conical" class="size-5 text-base-content/40" />
          <div class="min-w-0 flex-1 text-sm">
            <span class="font-medium">Demo controls</span>
            <span class="text-base-content/60">
              — break this endpoint on purpose and watch an incident open by itself.
            </span>
          </div>
          <button phx-click="break_demo_service" class="btn btn-sm">Break it</button>
          <button phx-click="heal_demo_service" class="btn btn-sm">Fix it</button>
        </div>
      </.card>

      <div class="mb-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <.stat_tile
          label="Uptime (24h)"
          value={format_percent(@metrics.uptime_percent)}
          hint={"#{@metrics.total} checks"}
        />
        <.stat_tile label="p50" value={format_ms(@metrics.p50)} />
        <.stat_tile label="p95" value={format_ms(@metrics.p95)} />
        <.stat_tile label="p99" value={format_ms(@metrics.p99)} />
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
        <h2 class="mb-2 text-lg font-medium">Recent checks</h2>
        <.uptime_bar checks={@checks} />
        <p class="mt-2 text-xs text-base-content/50">
          Oldest to newest · checked every {div(@service.check_interval_ms, 1000)}s
        </p>
      </section>
    </Layouts.app>
    """
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
