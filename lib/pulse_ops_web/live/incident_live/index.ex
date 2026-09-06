defmodule PulseOpsWeb.IncidentLive.Index do
  @moduledoc """
  Every incident in the organization, newest first.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.MonitoringComponents

  alias PulseOps.Incidents
  alias PulseOps.Incidents.Incident

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Incidents.subscribe_incidents(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "Incidents")
     |> load_incidents()}
  end

  @impl true
  def handle_info({event, _incident}, socket)
      when event in [:incident_opened, :incident_updated, :incident_resolved] do
    {:noreply, load_incidents(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_incidents(socket) do
    assign(socket, :incidents, Incidents.list_incidents(socket.assigns.current_scope))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Incidents
        <:subtitle>Opened and resolved automatically by the monitors.</:subtitle>
      </.header>

      <p
        :if={@incidents == []}
        class="mt-6 rounded-lg border border-base-300 p-8 text-center text-base-content/60"
      >
        No incidents recorded yet.
      </p>

      <ul
        :if={@incidents != []}
        class="mt-6 divide-y divide-base-300 rounded-lg border border-base-300"
      >
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
              {incident.service.name} · started <.relative_time at={incident.started_at} />
            </div>
          </div>

          <div class="text-sm tabular-nums text-base-content/60">
            {format_duration(Incident.duration_seconds(incident))}
          </div>

          <div class="w-28 text-sm">
            <span :if={Incident.open?(incident)} class="font-medium">
              {incident_status_label(incident.status)}
            </span>
            <span :if={not Incident.open?(incident)} class="text-base-content/50">Resolved</span>
          </div>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
