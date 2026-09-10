defmodule PulseOpsWeb.IncidentLive.Show do
  @moduledoc """
  One incident, its timeline, and the controls for working through it.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.MonitoringComponents

  alias PulseOps.Incidents
  alias PulseOps.Incidents.Incident
  alias PulseOps.Organizations

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Incidents.subscribe_incidents(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "Incident")
     |> assign(:note, "")
     |> load_incident(id)}
  end

  @impl true
  def handle_info({event, incident}, socket)
      when event in [:incident_updated, :incident_resolved] do
    if incident.id == socket.assigns.incident.id do
      {:noreply, load_incident(socket, incident.id)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("set_status", %{"status" => status}, socket) do
    socket.assigns.current_scope
    |> Incidents.update_incident(socket.assigns.incident, %{status: status})
    |> respond(socket, "Status updated")
  end

  def handle_event("save_cause", %{"cause" => cause}, socket) do
    socket.assigns.current_scope
    |> Incidents.update_incident(socket.assigns.incident, %{
      status: socket.assigns.incident.status,
      cause: cause
    })
    |> respond(socket, "Root cause saved")
  end

  def handle_event("add_note", %{"note" => ""}, socket), do: {:noreply, socket}

  def handle_event("add_note", %{"note" => note}, socket) do
    case Incidents.add_note(socket.assigns.current_scope, socket.assigns.incident, note) do
      {:ok, _event} ->
        {:noreply,
         socket
         |> assign(:note, "")
         |> load_incident(socket.assigns.incident.id)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("resolve", _params, socket) do
    socket.assigns.current_scope
    |> Incidents.resolve_incident(socket.assigns.incident)
    |> respond(socket, "Incident resolved")
  end

  def handle_event("acknowledge", _params, socket) do
    socket.assigns.current_scope
    |> Incidents.acknowledge_incident(socket.assigns.incident)
    |> respond(socket, "Acknowledged. This will not escalate.")
  end

  defp acknowledger(%{acknowledged_by: %{email: email}}), do: email
  defp acknowledger(_incident), do: "somebody"

  defp respond({:ok, incident}, socket, message) do
    {:noreply,
     socket
     |> put_flash(:info, message)
     |> load_incident(incident.id)}
  end

  defp respond({:error, reason}, socket, _message) do
    {:noreply, put_flash(socket, :error, error_message(reason))}
  end

  defp error_message(:unauthorized), do: "You do not have permission to do that."
  defp error_message(:already_resolved), do: "This incident is already resolved."
  defp error_message(%Ecto.Changeset{}), do: "That change could not be saved."

  defp load_incident(socket, id) do
    incident = Incidents.get_incident!(socket.assigns.current_scope, id)

    socket
    |> assign(:incident, incident)
    |> assign(
      :can_respond?,
      Organizations.can?(socket.assigns.current_scope, :respond_to_incidents)
    )
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
        navigate={~p"/orgs/#{@current_scope.organization.slug}/incidents"}
        class="text-sm text-base-content/60 hover:underline"
      >
        &larr; All incidents
      </.link>

      <div class="mt-2 mb-6 flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold">{@incident.title}</h1>
          <p class="mt-1 text-sm text-base-content/60">
            {@incident.service.name} · started <.relative_time at={@incident.started_at} />
          </p>
        </div>
        <.severity_tag severity={@incident.severity} />
      </div>

      <div class="mb-8 grid gap-3 sm:grid-cols-3">
        <.stat_tile label="Status" value={incident_status_label(@incident.status)} />
        <.stat_tile label="Duration" value={format_duration(Incident.duration_seconds(@incident))} />
        <.stat_tile
          label="Resolved by"
          value={resolver(@incident)}
          hint={@incident.resolved_at && format_time(@incident.resolved_at)}
        />
      </div>

      <div :if={@can_respond? and Incident.open?(@incident)} class="mb-8 space-y-4">
        <div>
          <div class="mb-2 text-sm font-medium">Move to</div>
          <div class="flex flex-wrap gap-2">
            <button
              :for={status <- workflow_statuses()}
              phx-click="set_status"
              phx-value-status={status}
              disabled={status == @incident.status}
              class={[
                "btn btn-sm",
                status == @incident.status && "btn-active btn-primary"
              ]}
            >
              {incident_status_label(status)}
            </button>
          </div>
        </div>

        <form phx-submit="save_cause">
          <label class="mb-1 block text-sm font-medium" for="cause">Root cause</label>
          <textarea
            id="cause"
            name="cause"
            rows="3"
            class="textarea textarea-bordered w-full"
            placeholder="Database connection pool exhausted."
          >{@incident.cause}</textarea>
          <button class="btn btn-sm mt-2">Save root cause</button>
        </form>

        <form phx-submit="add_note" class="flex gap-2">
          <input
            type="text"
            name="note"
            value={@note}
            placeholder="Add a note to the timeline"
            class="input input-bordered flex-1"
          />
          <button class="btn btn-sm">Add note</button>
        </form>

        <div class="flex flex-wrap gap-2">
          <button
            :if={is_nil(@incident.acknowledged_at)}
            phx-click="acknowledge"
            class="btn btn-sm"
          >
            <.icon name="lucide-hand" class="size-4" /> Acknowledge
          </button>

          <button phx-click="resolve" class="btn btn-primary btn-sm">Resolve incident</button>
        </div>

        <p :if={@incident.acknowledged_at} class="mt-2 text-xs text-base-content/50">
          Acknowledged by {acknowledger(@incident)}, so it will not escalate.
        </p>
      </div>

      <div :if={@incident.cause && not (@can_respond? and Incident.open?(@incident))} class="mb-8">
        <h2 class="mb-2 text-lg font-medium">Root cause</h2>
        <p class="rounded-lg border border-base-300 p-4 text-sm">{@incident.cause}</p>
      </div>

      <section>
        <h2 class="mb-3 text-lg font-medium">Timeline</h2>
        <ol class="space-y-3">
          <li :for={event <- @incident.events} class="flex gap-3">
            <div class="w-20 shrink-0 pt-0.5 text-xs tabular-nums text-base-content/50">
              {format_time(event.occurred_at)}
            </div>
            <div class="min-w-0 flex-1">
              <div class="text-sm">{event.description}</div>
              <div class="text-xs text-base-content/50">
                <%= if event.user do %>
                  {event.user.email}
                <% else %>
                  <%!-- No author means the monitor wrote it, not a person. --%>
                  Detected automatically
                <% end %>
              </div>
            </div>
          </li>
        </ol>
      </section>
    </Layouts.app>
    """
  end

  defp resolver(%Incident{resolved_at: nil}), do: "Still open"
  defp resolver(%Incident{resolved_by: nil}), do: "Recovered on its own"
  defp resolver(%Incident{resolved_by: user}), do: user.email
end
