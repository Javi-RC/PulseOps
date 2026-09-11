defmodule PulseOpsWeb.IncidentLive.Index do
  @moduledoc """
  Every incident in the organization, newest first, a page at a time.

  The list used to be the fifty most recent and nothing else, which is fine
  until an organization has had fifty-one — at which point the oldest one
  silently stops existing as far as this page is concerned. Page and filter
  both live in the URL, so a view of "resolved, page 3" can be linked and
  survives a reload.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.MonitoringComponents
  import PulseOpsWeb.UIComponents

  alias PulseOps.Incidents
  alias PulseOps.Incidents.Incident

  @per_page 25
  @filters ~w(all open resolved)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Incidents.subscribe_incidents(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "Incidents")
     |> assign(:filters, @filters)}
  end

  # Nonsense in the URL falls back to the first page of everything rather than
  # erroring: these are view preferences, not requests worth refusing.
  @impl true
  def handle_params(params, _uri, socket) do
    filter = if params["filter"] in @filters, do: params["filter"], else: "all"

    page =
      case Integer.parse(to_string(params["page"])) do
        {page, ""} when page > 0 -> page
        _otherwise -> 1
      end

    {:noreply, socket |> assign(filter: filter, page: page) |> load_incidents()}
  end

  # A broadcast refreshes the page being looked at, rather than jumping back to
  # the first one underneath whoever is reading page three.
  @impl true
  def handle_info({event, _incident}, socket)
      when event in [:incident_opened, :incident_updated, :incident_resolved] do
    {:noreply, load_incidents(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_incidents(socket) do
    %{entries: entries, has_more?: has_more?} =
      Incidents.page_incidents(socket.assigns.current_scope,
        page: socket.assigns.page,
        per_page: @per_page,
        status: String.to_existing_atom(socket.assigns.filter)
      )

    assign(socket, incidents: entries, has_more?: has_more?)
  end

  # Not called `path/3`: the verified-routes import already defines one, and
  # inside HEEx the import wins, so a private helper of that name is silently
  # the wrong function.
  defp incidents_path(scope, filter, page) do
    ~p"/orgs/#{scope.organization.slug}/incidents?#{[filter: filter, page: page]}"
  end

  # Where an open incident stands, or that it is over.
  defp incident_phase(incident) do
    if Incident.open?(incident), do: incident_status_label(incident.status), else: "Resolved"
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
      <.page_header title="Incidents">
        <:subtitle>Opened and resolved automatically by the monitors.</:subtitle>
      </.page_header>

      <nav
        id="incident-filters"
        class="mt-6 inline-flex items-center gap-1 rounded-box border border-base-300 bg-base-200/50 p-1"
        aria-label="Filter incidents"
      >
        <.link
          :for={filter <- @filters}
          patch={incidents_path(@current_scope, filter, 1)}
          class={[
            "rounded-sm px-3 py-1.5 text-sm font-medium transition-all",
            filter == @filter && "bg-base-100 shadow-sm text-base-content",
            filter != @filter && "text-base-content/60 hover:text-base-content/80"
          ]}
          aria-current={filter == @filter && "true"}
        >
          {String.capitalize(filter)}
        </.link>
      </nav>

      <p
        :if={@incidents == [] and @page == 1}
        class="mt-6 rounded-lg border border-base-300 p-8 text-center text-base-content/60"
      >
        {empty_message(@filter)}
      </p>

      <p
        :if={@incidents == [] and @page > 1}
        class="mt-6 rounded-lg border border-base-300 p-8 text-center text-base-content/60"
      >
        There is nothing on this page.
        <.link patch={incidents_path(@current_scope, @filter, 1)} class="link">
          Back to the first page
        </.link>
      </p>

      <ul
        :if={@incidents != []}
        id="incidents"
        class="mt-6 divide-y divide-base-300 rounded-lg border border-base-300"
      >
        <%!-- On a phone the duration and status fold under the title instead of
              wrapping onto a ragged second row of their own. --%>
        <li
          :for={incident <- @incidents}
          class="flex items-start gap-3 px-4 py-3 transition-colors hover:bg-base-200/50 sm:items-center sm:gap-4"
        >
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
            <div class="mt-1 text-xs text-base-content/60 sm:hidden">
              <span class="tabular-nums">{format_duration(Incident.duration_seconds(incident))}</span>
              · {incident_phase(incident)}
            </div>
          </div>

          <div class="text-sm tabular-nums text-base-content/60 max-sm:hidden">
            {format_duration(Incident.duration_seconds(incident))}
          </div>

          <div class="w-28 text-sm max-sm:hidden">
            <span :if={Incident.open?(incident)} class="font-medium">
              {incident_phase(incident)}
            </span>
            <span :if={not Incident.open?(incident)} class="text-base-content/50">Resolved</span>
          </div>
        </li>
      </ul>

      <nav
        :if={@page > 1 or @has_more?}
        id="incident-pagination"
        class="mt-4 flex items-center justify-between"
        aria-label="Pagination"
      >
        <.button
          :if={@page > 1}
          patch={incidents_path(@current_scope, @filter, @page - 1)}
          size="sm"
          rel="prev"
        >
          &larr; Newer
        </.button>
        <span :if={@page == 1}></span>

        <span class="text-sm text-base-content/60">Page {@page}</span>

        <.button
          :if={@has_more?}
          patch={incidents_path(@current_scope, @filter, @page + 1)}
          size="sm"
          rel="next"
        >
          Older &rarr;
        </.button>
        <span :if={not @has_more?}></span>
      </nav>
    </Layouts.app>
    """
  end

  defp empty_message("open"), do: "Nothing is open right now."
  defp empty_message("resolved"), do: "No incident has been resolved yet."
  defp empty_message(_all), do: "No incidents recorded yet."
end
