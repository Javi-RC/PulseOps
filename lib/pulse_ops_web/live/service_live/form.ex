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
        to_schema_params(params)
      )

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"service" => params}, socket) do
    save_service(socket, socket.assigns.live_action, to_schema_params(params))
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

  # Everything the form speaks differently from the schema is translated here,
  # in one place, rather than scattered through the template.
  defp to_schema_params(params) do
    params |> to_milliseconds() |> to_header_map()
  end

  # Headers are a textarea of `Name: value` lines, because a map is not a thing
  # an HTML form can post and a repeating-row widget is a lot of machinery for
  # something everyone already knows how to read.
  #
  # A line with no colon becomes a name with an empty value, which is a legal
  # header — and if it is not a valid header name the changeset says so, which
  # is how a line the user meant as prose gets a useful error.
  defp to_header_map(%{"request_headers_text" => text} = params) do
    headers =
      text
      |> to_string()
      |> String.split(["\r\n", "\n"])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Map.new(fn line ->
        case String.split(line, ":", parts: 2) do
          [name, value] -> {String.trim(name), String.trim(value)}
          [name] -> {String.trim(name), ""}
        end
      end)

    params
    |> Map.delete("request_headers_text")
    |> Map.put("request_headers", headers)
  end

  defp to_header_map(params), do: params

  # The schema keeps milliseconds; the form speaks seconds.
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

  # request_headers is not the field the form posts, so its errors have to be
  # surfaced next to the textarea by hand.
  defp header_errors(form) do
    Enum.flat_map(form.errors, fn
      {:request_headers, {message, _opts}} -> [message]
      _other -> []
    end)
  end

  # The stored map, back in the shape the textarea shows. Sorted so editing a
  # service does not reshuffle the lines under the cursor.
  defp headers_text(form) do
    case Form.input_value(form, :request_headers) do
      headers when is_map(headers) and map_size(headers) > 0 ->
        headers
        |> Enum.sort_by(fn {name, _value} -> name end)
        |> Enum.map_join("\n", fn {name, value} -> "#{name}: #{value}" end)

      _none ->
        ""
    end
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

              <div class="mt-4">
                <.input
                  field={@form[:http_method]}
                  type="select"
                  label="Method"
                  options={Enum.map(Service.http_methods(), &{String.upcase(to_string(&1)), &1})}
                />
              </div>

              <div class="mt-4">
                <.input
                  type="textarea"
                  name="service[request_headers_text]"
                  value={headers_text(@form)}
                  label="Request headers"
                  rows="3"
                  placeholder="Authorization: Bearer ..."
                />
                <p class="mt-1 text-xs text-base-content/50">
                  One per line, as <code>Name: value</code>. Stored as written, so a token here
                  sits in the database in plain text.
                </p>
                <p :for={message <- header_errors(@form)} class="mt-1 text-sm text-error">
                  {message}
                </p>
              </div>

              <div class="mt-4">
                <.input
                  field={@form[:request_body]}
                  type="textarea"
                  label="Request body"
                  rows="2"
                />
                <p class="mt-1 text-xs text-base-content/50">
                  Only sent with POST.
                </p>
              </div>

              <div class="mt-4">
                <.input
                  field={@form[:expected_status]}
                  type="number"
                  label="Expected status"
                  placeholder="any 2xx"
                />
                <p class="mt-1 text-xs text-base-content/50">
                  Leave empty to accept any 2xx. Set it to watch an endpoint whose healthy answer
                  is something else — a 204, or a 401 that proves it is alive.
                </p>
              </div>

              <div class="mt-4">
                <.input
                  field={@form[:body_assertion]}
                  type="text"
                  label="Body must contain"
                  placeholder={~s("status":"ok")}
                />
                <p class="mt-1 text-xs text-base-content/50">
                  The only way to catch a service that is up, answering 200, and saying in its
                  payload that it is not well.
                </p>
              </div>

              <div class="mt-4">
                <.input field={@form[:public]} type="checkbox" label="Show on the status page" />
                <p class="mt-1 text-xs text-base-content/50">
                  Only matters once the organization publishes a status page. The name, status and
                  uptime are shown; the URL never is.
                </p>
              </div>

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
