defmodule PulseOpsWeb.ServiceLive.Form do
  @moduledoc """
  Creates and edits a service.

  Intervals are stored in milliseconds because that is what the monitor's timers
  take, but nobody thinks in milliseconds: the form asks for seconds and
  converts on the way in and out.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.UIComponents

  alias Phoenix.HTML.Form
  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.Service

  @duration_fields %{
    "check_interval_seconds" => "check_interval_ms",
    "timeout_seconds" => "timeout_ms"
  }

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:return_to, return_to(params["return_to"]))
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp return_to("show"), do: "show"
  defp return_to(_), do: "index"

  defp apply_action(socket, :edit, %{"id" => id}) do
    service = Monitoring.get_service!(socket.assigns.current_scope, id)

    socket
    |> assign(:page_title, "Edit service")
    |> assign(:service, service)
    |> assign_form(Monitoring.change_service(socket.assigns.current_scope, service))
  end

  defp apply_action(socket, :new, _params) do
    service = %Service{organization_id: socket.assigns.current_scope.organization.id}

    socket
    |> assign(:page_title, "New service")
    |> assign(:service, service)
    |> assign_form(Monitoring.change_service(socket.assigns.current_scope, service))
  end

  @impl true
  def handle_event("validate", %{"service" => params}, socket) do
    changeset =
      Monitoring.change_service(
        socket.assigns.current_scope,
        socket.assigns.service,
        to_milliseconds(params)
      )

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"service" => params}, socket) do
    save_service(socket, socket.assigns.live_action, to_milliseconds(params))
  end

  defp save_service(socket, :edit, params) do
    socket.assigns.current_scope
    |> Monitoring.update_service(socket.assigns.service, params)
    |> respond(socket, "Service updated")
  end

  defp save_service(socket, :new, params) do
    socket.assigns.current_scope
    |> Monitoring.create_service(params)
    |> respond(socket, "Service created")
  end

  defp respond({:ok, service}, socket, message) do
    {:noreply,
     socket
     |> put_flash(:info, message)
     |> push_navigate(
       to: return_path(socket.assigns.current_scope, socket.assigns.return_to, service)
     )}
  end

  defp respond({:error, %Ecto.Changeset{} = changeset}, socket, _message) do
    {:noreply, assign_form(socket, changeset)}
  end

  defp respond({:error, :unauthorized}, socket, _message) do
    {:noreply,
     socket
     |> put_flash(:error, "You do not have permission to manage services.")
     |> push_navigate(to: ~p"/orgs/#{socket.assigns.current_scope.organization.slug}/services")}
  end

  # The schema keeps milliseconds; the form speaks seconds. Converting at this
  # boundary keeps the unit conversion in one place instead of scattering
  # divisions through the template.
  defp to_milliseconds(params) do
    Enum.reduce(@duration_fields, params, fn {from, to}, acc ->
      case Map.fetch(acc, from) do
        {:ok, value} -> acc |> Map.delete(from) |> Map.put(to, seconds_to_ms(value))
        :error -> acc
      end
    end)
  end

  defp seconds_to_ms(value) do
    case Integer.parse(to_string(value)) do
      {seconds, _rest} -> seconds * 1000
      # Let the changeset produce the error rather than guessing a number here.
      :error -> value
    end
  end

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp seconds_value(form, field, default) do
    case Form.input_value(form, field) do
      nil -> default
      "" -> default
      value when is_integer(value) -> div(value, 1000)
      value -> value
    end
  end

  defp return_path(scope, "index", _service), do: ~p"/orgs/#{scope.organization.slug}/services"

  defp return_path(scope, "show", service),
    do: ~p"/orgs/#{scope.organization.slug}/services/#{service}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      organizations={@organizations}
      current_path={@current_path}
    >
      <.page_header title={@page_title}>
        <:subtitle>
          PulseOps probes the URL on a schedule and opens an incident when it stops answering.
        </:subtitle>
      </.page_header>

      <.form for={@form} id="service-form" phx-change="validate" phx-submit="save">
        <div class="grid gap-4 lg:grid-cols-3">
          <div class="lg:col-span-2 space-y-4">
            <.card>
              <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-base-content/60">
                What it is
              </h2>

              <div class="space-y-3">
                <.input field={@form[:name]} type="text" label="Name" placeholder="Payments API" />
                <.input
                  field={@form[:description]}
                  type="textarea"
                  label="Description"
                  placeholder="What breaks when this goes down."
                />
                <.input
                  field={@form[:environment]}
                  type="select"
                  label="Environment"
                  options={Enum.map(Service.environments(), &{Phoenix.Naming.humanize(&1), &1})}
                />
              </div>
            </.card>

            <.card>
              <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-base-content/60">
                How it is checked
              </h2>

              <div class="space-y-3">
                <.input
                  field={@form[:url]}
                  type="url"
                  label="Health check URL"
                  placeholder="https://api.example.com/health"
                />

                <div class="grid gap-3 sm:grid-cols-2">
                  <div>
                    <label class="mb-1 block text-sm font-medium" for="check_interval_seconds">
                      Check every
                    </label>
                    <label class="input input-bordered flex items-center gap-2">
                      <input
                        type="number"
                        id="check_interval_seconds"
                        name="service[check_interval_seconds]"
                        value={seconds_value(@form, :check_interval_ms, 30)}
                        min="10"
                        max="3600"
                        class="grow"
                      />
                      <span class="text-sm text-base-content/50">seconds</span>
                    </label>
                    <p
                      :for={msg <- errors_for(@form, :check_interval_ms)}
                      class="mt-1 text-sm text-error"
                    >
                      {msg}
                    </p>
                    <p class="mt-1 text-xs text-base-content/50">Between 10 seconds and 1 hour.</p>
                  </div>

                  <div>
                    <label class="mb-1 block text-sm font-medium" for="timeout_seconds">
                      Give up after
                    </label>
                    <label class="input input-bordered flex items-center gap-2">
                      <input
                        type="number"
                        id="timeout_seconds"
                        name="service[timeout_seconds]"
                        value={seconds_value(@form, :timeout_ms, 5)}
                        min="1"
                        max="30"
                        class="grow"
                      />
                      <span class="text-sm text-base-content/50">seconds</span>
                    </label>
                    <p :for={msg <- errors_for(@form, :timeout_ms)} class="mt-1 text-sm text-error">
                      {msg}
                    </p>
                    <p class="mt-1 text-xs text-base-content/50">
                      Must be shorter than the interval.
                    </p>
                  </div>
                </div>
              </div>
            </.card>
          </div>

          <div class="space-y-4">
            <.card>
              <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-base-content/60">
                Monitoring
              </h2>

              <.input
                field={@form[:enabled]}
                type="checkbox"
                label="Actively monitored"
              />
              <p class="mt-1 text-xs text-base-content/50">
                Turning this off stops the supervised process for this service. Its history is kept.
              </p>

              <%!-- Status and last checked belong to the monitor, not to this
                    form, so they are deliberately absent. --%>
            </.card>

            <div class="flex flex-col gap-2">
              <.button variant="primary" phx-disable-with="Saving...">
                Save service
              </.button>
              <.link navigate={return_path(@current_scope, @return_to, @service)} class="btn btn-soft">
                Cancel
              </.link>
            </div>
          </div>
        </div>
      </.form>
    </Layouts.app>
    """
  end

  defp errors_for(form, field) do
    form[field]
    |> then(&if(Phoenix.Component.used_input?(&1), do: &1.errors, else: []))
    |> Enum.map(&PulseOpsWeb.CoreComponents.translate_error/1)
  end
end
