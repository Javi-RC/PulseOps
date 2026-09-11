defmodule PulseOpsWeb.MaintenanceLive.Index do
  @moduledoc """
  Scheduling maintenance windows, and seeing which are running or coming.

  A window does not stop the probes. Checks keep being made and recorded, the
  dashboard keeps telling the truth, and what stops is the paging — which is the
  part that wakes people up for a deploy somebody planned.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.UIComponents

  alias PulseOps.Maintenance
  alias PulseOps.Maintenance.Window
  alias PulseOps.Monitoring
  alias PulseOps.Organizations

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:page_title, "Maintenance")
     |> assign(:can_manage?, Organizations.can?(scope, :manage_services))
     |> assign(:services, Monitoring.list_services(scope))
     |> assign(:now, DateTime.utc_now())
     |> assign_form(Maintenance.change_window(scope, %Window{}, default_attrs()))
     |> load_windows()}
  end

  @impl true
  def handle_event("validate", %{"window" => params}, socket) do
    changeset = Maintenance.change_window(socket.assigns.current_scope, %Window{}, params)

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"window" => params}, socket) do
    case Maintenance.create_window(socket.assigns.current_scope, params) do
      {:ok, window} ->
        {:noreply,
         socket
         |> put_flash(:info, "Maintenance scheduled: #{window.reason}.")
         |> assign_form(
           Maintenance.change_window(socket.assigns.current_scope, %Window{}, default_attrs())
         )
         |> load_windows()}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to do that.")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    case Maintenance.delete_window(socket.assigns.current_scope, String.to_integer(id)) do
      {:ok, window} ->
        {:noreply,
         socket
         |> put_flash(:info, "Cancelled: #{window.reason}.")
         |> load_windows()}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to do that.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That window no longer exists.")}
    end
  end

  defp load_windows(socket) do
    socket
    |> assign(:windows, Maintenance.list_current_windows(socket.assigns.current_scope))
    |> assign(:now, DateTime.utc_now())
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset, as: :window))

  # A window most often starts now and runs for an hour, which is what a deploy
  # looks like. Prefilling it means the common case is one click.
  defp default_attrs do
    now = DateTime.utc_now(:second)

    %{
      "starts_at" => for_input(now),
      "ends_at" => for_input(DateTime.add(now, 3600, :second))
    }
  end

  defp for_input(datetime), do: Calendar.strftime(datetime, "%Y-%m-%dT%H:%M")

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
      <.page_header title="Maintenance">
        <:subtitle>
          Planned work, so a deploy does not page anybody. Checks keep running and the history
          stays honest; only the incidents are held back.
        </:subtitle>
      </.page_header>

      <.card :if={@can_manage?} class="mb-6 max-w-2xl">
        <.form for={@form} id="window-form" phx-change="validate" phx-submit="save" class="space-y-4">
          <.input field={@form[:reason]} type="text" label="What is happening" required />

          <div class="grid gap-4 sm:grid-cols-2">
            <.input field={@form[:starts_at]} type="datetime-local" label="From (UTC)" required />
            <.input field={@form[:ends_at]} type="datetime-local" label="Until (UTC)" required />
          </div>

          <.input
            field={@form[:service_id]}
            type="select"
            label="Scope"
            options={[{"Every service in the organization", ""} | service_options(@services)]}
          />

          <.button variant="primary" phx-disable-with="Scheduling...">Schedule</.button>
        </.form>
      </.card>

      <.empty_state
        :if={@windows == []}
        id="maintenance-empty"
        icon="lucide-calendar-clock"
        title="Nothing scheduled"
      >
        <:subtitle>
          <%= if @can_manage? do %>
            Schedule a window above before a deploy, and nobody is paged while it runs.
          <% else %>
            Incidents open and notify as usual. An owner or admin can hold them back during
            planned work.
          <% end %>
        </:subtitle>
      </.empty_state>

      <.list_card :if={@windows != []} id="maintenance-windows">
        <:item :for={window <- @windows} class="flex flex-wrap items-center justify-between gap-3">
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <span class="font-medium">{window.reason}</span>
              <span class={["badge badge-sm", state_class(Window.state(window, @now))]}>
                {state_label(Window.state(window, @now))}
              </span>
            </div>
            <p class="mt-0.5 text-sm text-base-content/60">
              {scope_label(window)} · {format_range(window)}
            </p>
          </div>

          <.button
            :if={@can_manage?}
            phx-click="cancel"
            phx-value-id={window.id}
            data-confirm={cancel_confirmation(Window.state(window, @now))}
            data-confirm-label="Cancel window"
            variant="ghost"
            size="sm"
          >
            Cancel
          </.button>
        </:item>
      </.list_card>
    </Layouts.app>
    """
  end

  defp service_options(services) do
    Enum.map(services, &{"#{&1.name} · #{&1.environment}", &1.id})
  end

  defp scope_label(%{service: %{name: name}}), do: name
  defp scope_label(_window), do: "Every service"

  defp state_label(:active), do: "Running"
  defp state_label(:scheduled), do: "Scheduled"
  defp state_label(:finished), do: "Finished"

  defp state_class(:active), do: "badge-warning"
  defp state_class(:scheduled), do: "badge-ghost"
  defp state_class(:finished), do: "badge-ghost"

  defp cancel_confirmation(:active),
    do: "This window is running. Cancelling it means incidents can open again straight away."

  defp cancel_confirmation(_state), do: nil

  defp format_range(window) do
    "#{Calendar.strftime(window.starts_at, "%d %b %H:%M")} – " <>
      "#{Calendar.strftime(window.ends_at, "%d %b %H:%M")} UTC"
  end
end
