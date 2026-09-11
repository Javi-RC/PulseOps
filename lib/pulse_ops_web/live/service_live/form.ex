defmodule PulseOpsWeb.ServiceLive.Form do
  @moduledoc """
  Creates and edits a service.

  Intervals are stored in milliseconds because that is what the monitor's timers
  take, but nobody thinks in milliseconds: the form asks for seconds and
  converts on the way in and out.

  The form runs in the order someone setting up a check thinks in: what the
  endpoint is, how often to look at it, who gets to see it. How the request is
  shaped — method, headers, body, what counts as a healthy answer — is folded
  away, because most health endpoints need none of it. It opens by itself when
  the service already uses any of it, or when one of those fields has an error,
  so nothing configured or broken is ever out of sight.

  "Test connection" probes the URL once, before anything is saved, through the
  same client and the same options the monitor uses. Whether the URL answers at
  all is the biggest doubt when adding a service, and waiting for the first
  scheduled check is the slowest way to find out.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.MonitoringComponents, only: [format_ms: 1]
  import PulseOpsWeb.UIComponents

  alias Phoenix.HTML.Form
  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.HealthCheck.Result
  alias PulseOps.Monitoring.Service

  @duration_fields %{
    "check_interval_seconds" => "check_interval_ms",
    "timeout_seconds" => "timeout_ms"
  }

  @advanced_fields [
    :http_method,
    :request_headers,
    :request_body,
    :expected_status,
    :body_assertion
  ]

  # Everything that shapes the request a test sends. An error in any of them
  # means the test would not be testing what will be saved.
  @probe_fields [:url, :timeout_ms | @advanced_fields]

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:return_to, return_to(params["return_to"]))
     |> assign(:connection_test, nil)
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp return_to("show"), do: "show"
  defp return_to(_), do: "index"

  defp apply_action(socket, :edit, %{"id" => id}) do
    service = Monitoring.get_service!(socket.assigns.current_scope, id)

    socket
    |> assign(:page_title, "Edit service")
    |> assign(:service, service)
    |> assign(:show_advanced, uses_advanced?(service))
    |> assign_form(Monitoring.change_service(socket.assigns.current_scope, service))
  end

  defp apply_action(socket, :new, _params) do
    service = %Service{organization_id: socket.assigns.current_scope.organization.id}

    socket
    |> assign(:page_title, "New service")
    |> assign(:service, service)
    |> assign(:show_advanced, false)
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
      |> Map.put(:action, :validate)

    {:noreply, socket |> assign_form(changeset) |> reveal_advanced_errors(changeset)}
  end

  def handle_event("save", %{"service" => params}, socket) do
    save_service(socket, socket.assigns.live_action, to_schema_params(params))
  end

  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, update(socket, :show_advanced, &(not &1))}
  end

  def handle_event("test_connection", _params, socket) do
    changeset = socket.assigns.form.source
    service = Ecto.Changeset.apply_changes(changeset)
    scope = socket.assigns.current_scope

    if Keyword.take(changeset.errors, @probe_fields) == [] do
      {:noreply,
       socket
       |> assign(:connection_test, %{url: service.url, outcome: :running})
       |> start_async(:test_connection, fn -> Monitoring.test_service(scope, service) end)}
    else
      shown = Map.put(changeset, :action, :validate)

      {:noreply,
       socket
       |> assign_form(shown)
       |> reveal_advanced_errors(shown)
       |> assign(:connection_test, %{
         url: service.url,
         outcome:
           {:invalid, "Fix the highlighted fields first, so the test sends what you will save."}
       })}
    end
  end

  @impl true
  def handle_async(:test_connection, {:ok, outcome}, socket) do
    {:noreply, update(socket, :connection_test, &%{&1 | outcome: outcome})}
  end

  def handle_async(:test_connection, {:exit, _reason}, socket) do
    {:noreply,
     update(
       socket,
       :connection_test,
       &%{&1 | outcome: {:error, %Result{error: "the test did not finish"}}}
     )}
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
    {:noreply, socket |> assign_form(changeset) |> reveal_advanced_errors(changeset)}
  end

  defp respond({:error, :unauthorized}, socket, _message) do
    {:noreply,
     socket
     |> put_flash(:error, "You do not have permission to manage services.")
     |> push_navigate(to: ~p"/orgs/#{socket.assigns.current_scope.organization.slug}/services")}
  end

  # Open when the service already relies on any of it, so nothing configured is
  # ever out of sight.
  defp uses_advanced?(%Service{} = service) do
    service.http_method not in [nil, :get] or
      map_size(service.request_headers || %{}) > 0 or
      present?(service.request_body) or
      not is_nil(service.expected_status) or
      present?(service.body_assertion)
  end

  # An error in a folded field would otherwise be an error nobody can see.
  defp reveal_advanced_errors(socket, %Ecto.Changeset{action: action, errors: errors})
       when not is_nil(action) do
    if Enum.any?(errors, fn {field, _error} -> field in @advanced_fields end) do
      assign(socket, :show_advanced, true)
    else
      socket
    end
  end

  defp reveal_advanced_errors(socket, _changeset), do: socket

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

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

  # What the folded section is set to, so it can stay folded without hiding it.
  defp advanced_summary(form) do
    [
      method_summary(Form.input_value(form, :http_method)),
      headers_summary(Form.input_value(form, :request_headers)),
      status_summary(Form.input_value(form, :expected_status)),
      body_summary(Form.input_value(form, :body_assertion))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp method_summary(nil), do: "GET"
  defp method_summary(method), do: method |> to_string() |> String.upcase()

  defp headers_summary(headers) when is_map(headers) and map_size(headers) == 1, do: "1 header"

  defp headers_summary(headers) when is_map(headers) and map_size(headers) > 1,
    do: "#{map_size(headers)} headers"

  defp headers_summary(_none), do: nil

  defp status_summary(blank) when blank in [nil, ""], do: "any 2xx"
  defp status_summary(expected), do: "expects #{expected}"

  defp body_summary(assertion) when is_binary(assertion) do
    if present?(assertion), do: "checks the body"
  end

  defp body_summary(_none), do: nil

  # A result belongs to the URL it tested. Once the field says something else,
  # showing it would vouch for a URL nobody tried.
  defp current_test(nil, _form), do: nil

  defp current_test(%{url: url, outcome: outcome}, form) do
    if to_string(url) == to_string(Form.input_value(form, :url)), do: outcome
  end

  defp running?(%{outcome: :running}), do: true
  defp running?(_connection_test), do: false

  defp failure_detail(%Result{error: error, response_time_ms: ms}) when is_integer(ms),
    do: "#{upcase_first(error || "it failed")}, after #{format_ms(ms)}."

  defp failure_detail(%Result{error: error}), do: "#{upcase_first(error || "it failed")}."

  # String.capitalize/1 would also lowercase the rest, turning "HTTP" into "Http".
  defp upcase_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp upcase_first(other), do: other

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
      open_incident_count={@open_incident_count}
    >
      <.breadcrumb>
        <:item navigate={~p"/orgs/#{@current_scope.organization.slug}/services"}>Services</:item>
        <:item>{if @live_action == :new, do: "New", else: @service.name}</:item>
      </.breadcrumb>

      <.page_header title={@page_title}>
        <:subtitle>
          PulseOps probes the URL on a schedule and opens an incident when it stops answering.
        </:subtitle>
      </.page_header>

      <.form
        for={@form}
        id="service-form"
        phx-change="validate"
        phx-submit="save"
        class="max-w-3xl space-y-4"
      >
        <.card>
          <.section_heading title="Endpoint" />

          <div class="space-y-3">
            <.input field={@form[:name]} type="text" label="Name" placeholder="Payments API" />

            <div>
              <.input
                field={@form[:url]}
                type="url"
                label="Health check URL"
                placeholder="https://api.example.com/health"
              />
              <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
                <.button
                  type="button"
                  id="test-connection"
                  phx-click="test_connection"
                  size="sm"
                  disabled={running?(@connection_test)}
                >
                  <.icon name="lucide-plug-zap" class="size-4" />
                  {if running?(@connection_test), do: "Testing…", else: "Test connection"}
                </.button>
                <span class="text-xs text-base-content/50">
                  Sends one request now, exactly as the monitor would. Nothing is saved.
                </span>
              </div>

              <.connection_result outcome={current_test(@connection_test, @form)} />
            </div>

            <.input
              field={@form[:environment]}
              type="select"
              label="Environment"
              options={Enum.map(Service.environments(), &{Phoenix.Naming.humanize(&1), &1})}
            />
            <.input
              field={@form[:description]}
              type="textarea"
              label="Description"
              rows="2"
              placeholder="What breaks when this goes down."
            />
          </div>
        </.card>

        <.card>
          <.section_heading title="Schedule" />

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
              <.field_error field={@form[:check_interval_ms]} />
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
              <.field_error field={@form[:timeout_ms]} />
              <p class="mt-1 text-xs text-base-content/50">Must be shorter than the interval.</p>
            </div>
          </div>
        </.card>

        <.card>
          <.section_heading title="Visibility" />

          <.input field={@form[:enabled]} type="checkbox" label="Actively monitored" />
          <p class="-mt-1 mb-3 text-xs text-base-content/50">
            Turning this off stops the supervised process for this service. Its history is kept.
          </p>

          <.input field={@form[:public]} type="checkbox" label="Show on the status page" />
          <p class="-mt-1 text-xs text-base-content/50">
            Only matters once the organization publishes a status page. The name, status and
            uptime are shown; the URL never is.
          </p>
        </.card>

        <.card padded={false}>
          <button
            type="button"
            id="advanced-toggle"
            phx-click="toggle_advanced"
            aria-expanded={to_string(@show_advanced)}
            aria-controls="advanced-settings"
            class="flex w-full items-center justify-between gap-3 rounded-box px-4 py-3 text-left hover:bg-base-200/50 sm:px-5"
          >
            <span class="min-w-0">
              <span class="block text-sm font-semibold uppercase tracking-wide text-base-content/60">
                Request and response
              </span>
              <span class="mt-0.5 block truncate text-xs text-base-content/50">
                {advanced_summary(@form)}
              </span>
            </span>
            <.icon
              name="lucide-chevron-down"
              class={
                if(@show_advanced,
                  do: "size-4 shrink-0 rotate-180 transition-transform",
                  else: "size-4 shrink-0 transition-transform"
                )
              }
            />
          </button>

          <%!-- Hidden rather than removed: the fields keep posting, so folding the
                section never quietly drops what a service is configured with. --%>
          <div
            id="advanced-settings"
            class={[
              "space-y-4 border-t border-base-300 px-4 pb-4 pt-3 sm:px-5",
              not @show_advanced && "hidden"
            ]}
          >
            <p class="text-xs text-base-content/50">
              Most health endpoints need none of this: a GET that answers 2xx is a pass.
            </p>

            <div class="grid gap-3 sm:grid-cols-2">
              <.input
                field={@form[:http_method]}
                type="select"
                label="Method"
                options={Enum.map(Service.http_methods(), &{String.upcase(to_string(&1)), &1})}
              />
              <div>
                <.input
                  field={@form[:expected_status]}
                  type="number"
                  label="Expected status"
                  placeholder="any 2xx"
                />
                <p class="-mt-1 text-xs text-base-content/50">
                  Empty accepts any 2xx. Set it for a healthy answer that is something else — a
                  204, or a 401 that proves it is alive.
                </p>
              </div>
            </div>

            <div>
              <.input
                type="textarea"
                name="service[request_headers_text]"
                value={headers_text(@form)}
                label="Request headers"
                rows="3"
                placeholder="Authorization: Bearer ..."
              />
              <p class="-mt-1 text-xs text-base-content/50">
                One per line, as <code>Name: value</code>.
              </p>
              <p class="mt-1 flex items-start gap-1.5 text-xs text-base-content/70">
                <.icon name="lucide-lock-open" class="mt-px size-3.5 shrink-0 text-warning" />
                Stored as written: a token here is kept in the database in plain text. Prefer one
                that can only read the health endpoint.
              </p>
              <p :for={message <- header_errors(@form)} class="mt-1 text-sm text-error">
                {message}
              </p>
            </div>

            <div>
              <.input field={@form[:request_body]} type="textarea" label="Request body" rows="2" />
              <p class="-mt-1 text-xs text-base-content/50">Only sent with POST.</p>
            </div>

            <div>
              <.input
                field={@form[:body_assertion]}
                type="text"
                label="Body must contain"
                placeholder={~s("status":"ok")}
              />
              <p class="-mt-1 text-xs text-base-content/50">
                The only way to catch a service that is up, answering 200, and saying in its
                payload that it is not well.
              </p>
            </div>
          </div>
        </.card>

        <%!-- Status and last checked belong to the monitor, not to this form, so
              they are deliberately absent. --%>

        <div class="flex flex-wrap items-center justify-end gap-2">
          <.button navigate={return_path(@current_scope, @return_to, @service)}>Cancel</.button>
          <.button id="save-service" variant="primary" phx-disable-with="Saving...">
            {if @live_action == :new, do: "Create service", else: "Save changes"}
          </.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end

  attr :outcome, :any, required: true

  defp connection_result(assigns) do
    ~H"""
    <div id="connection-test" role="status" aria-live="polite">
      <%= case @outcome do %>
        <% nil -> %>
        <% :running -> %>
          <p class="mt-2 flex items-center gap-2 text-sm text-base-content/60">
            <span class="loading loading-spinner loading-xs"></span> Waiting for an answer…
          </p>
        <% {:ok, %Result{} = result} -> %>
          <div class="mt-2 flex items-start gap-2 rounded-lg border border-success/40 bg-success/5 px-3 py-2 text-sm">
            <.icon name="lucide-circle-check" class="mt-0.5 size-4 shrink-0 text-success" />
            <p>
              <span class="font-medium">It answers.</span>
              HTTP {result.http_status} in {format_ms(result.response_time_ms)}, which passes the check.
            </p>
          </div>
        <% {:error, %Result{} = result} -> %>
          <div class="mt-2 flex items-start gap-2 rounded-lg border border-error/40 bg-error/5 px-3 py-2 text-sm">
            <.icon name="lucide-circle-x" class="mt-0.5 size-4 shrink-0 text-error" />
            <p>
              <span class="font-medium">This check would fail.</span>
              {failure_detail(result)}
            </p>
          </div>
        <% {:error, :unauthorized} -> %>
          <p class="mt-2 text-sm text-error">You do not have permission to test services.</p>
        <% {:invalid, message} -> %>
          <p class="mt-2 flex items-start gap-2 text-sm text-base-content/70">
            <.icon name="lucide-triangle-alert" class="mt-0.5 size-4 shrink-0 text-warning" />
            {message}
          </p>
      <% end %>
    </div>
    """
  end
end
