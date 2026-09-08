defmodule PulseOpsWeb.AlertRuleLive.Form do
  @moduledoc """
  Creates and edits an alert rule.

  The degraded ratio is stored as a fraction of the timeout — what the monitor
  and the incident machinery compare a check's latency against — but the form
  speaks in whole percents, converted at this boundary like ServiceLive.Form
  converts durations between milliseconds and seconds.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.MonitoringComponents
  import PulseOpsWeb.UIComponents

  alias Phoenix.HTML.Form
  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.AlertRule
  alias PulseOps.Monitoring.Service

  @impl true
  def mount(params, _session, socket) do
    {:ok, socket |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case Enum.find(Monitoring.list_alert_rules(scope), &(&1.id == String.to_integer(id))) do
      nil ->
        socket
        |> put_flash(:error, "That alert rule was not found.")
        |> push_navigate(to: alert_rules_path(scope))

      rule ->
        socket
        |> assign(:page_title, "Edit alert rule")
        |> assign(:rule, rule)
        |> assign(:service_label, service_label(rule))
        |> assign_form(Monitoring.change_alert_rule(scope, rule))
    end
  end

  defp apply_action(socket, :new, _params) do
    scope = socket.assigns.current_scope
    rule = %AlertRule{organization_id: scope.organization.id}

    socket
    |> assign(:page_title, "New alert rule")
    |> assign(:rule, rule)
    |> assign(:service_options, build_service_options(scope))
    |> assign_form(Monitoring.change_alert_rule(scope, rule))
  end

  @impl true
  def handle_event("validate", %{"alert_rule" => params}, socket) do
    changeset =
      Monitoring.change_alert_rule(
        socket.assigns.current_scope,
        socket.assigns.rule,
        to_rule_params(params)
      )

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"alert_rule" => params}, socket) do
    save_rule(socket, socket.assigns.live_action, to_rule_params(params))
  end

  defp save_rule(socket, :new, params) do
    case Monitoring.create_alert_rule(socket.assigns.current_scope, params) do
      {:ok, _rule} -> respond(socket, "Alert rule created.")
      {:error, %Ecto.Changeset{} = changeset} -> {:noreply, assign_form(socket, changeset)}
      {:error, :unauthorized} -> forbidden(socket)
    end
  end

  defp save_rule(socket, :edit, params) do
    case Monitoring.update_alert_rule(socket.assigns.current_scope, socket.assigns.rule, params) do
      {:ok, _rule} -> respond(socket, "Alert rule updated.")
      {:error, %Ecto.Changeset{} = changeset} -> {:noreply, assign_form(socket, changeset)}
      {:error, :unauthorized} -> forbidden(socket)
    end
  end

  defp respond(socket, message) do
    {:noreply,
     socket
     |> put_flash(:info, message)
     |> push_navigate(to: alert_rules_path(socket.assigns.current_scope))}
  end

  defp forbidden(socket) do
    {:noreply,
     socket
     |> put_flash(:error, "You do not have permission to manage alert rules.")
     |> push_navigate(to: alert_rules_path(socket.assigns.current_scope))}
  end

  # A nil service_id is the organization default. The select exposes it as an
  # empty value; deleted here so Ecto does not try to cast an empty string into
  # an integer. A service that already has a rule must not be offered twice.
  defp build_service_options(scope) do
    rules = Monitoring.list_alert_rules(scope)
    default_exists? = Enum.any?(rules, &is_nil(&1.service_id))
    taken = rules |> Enum.map(& &1.service_id) |> Enum.reject(&is_nil/1)

    default_option = if default_exists?, do: [], else: [{"Organization default", ""}]

    default_option ++
      Enum.map(Enum.reject(Monitoring.list_services(scope), &(&1.id in taken)), fn service ->
        {"#{service.name} · #{service.environment}", service.id}
      end)
  end

  defp service_label(%AlertRule{service: %Service{} = service}), do: service.name
  defp service_label(_rule), do: "Organization default"

  # The schema stores a fraction; the form speaks whole percents. Converting at
  # this boundary keeps the conversion in one place instead of scattering
  # divisions through the template.
  defp to_rule_params(params) do
    params
    |> Map.put_new("degraded_ratio", percent_to_ratio(params["degraded_percent"]))
    |> Map.delete("degraded_percent")
    |> normalize_service_id()
  end

  defp normalize_service_id(params) do
    case Map.get(params, "service_id") do
      "" -> Map.delete(params, "service_id")
      _ -> params
    end
  end

  defp percent_to_ratio(percent) do
    case Integer.parse(to_string(percent)) do
      {value, _rest} -> (value / 100) |> to_string()
      # Let the changeset produce the error rather than guessing a number here.
      :error -> percent
    end
  end

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp percent_value(form) do
    case Form.input_value(form, :degraded_ratio) do
      nil -> 100
      ratio when is_float(ratio) -> round(ratio * 100)
      value -> value
    end
  end

  defp severity_value(form) do
    case Form.input_value(form, :severity) do
      nil -> :medium
      # A valid atom already on the form drives the preview directly.
      severity when is_atom(severity) -> severity
      # Params carry the raw string (e.g. "high") during validation.
      severity -> Enum.find(AlertRule.severities(), :medium, &(to_string(&1) == severity))
    end
  end

  defp alert_rules_path(scope), do: ~p"/orgs/#{scope.organization.slug}/settings/alert-rules"

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
          Failed checks below these thresholds are just noise; enough of them in a row mark the
          service down and open an incident.
        </:subtitle>
      </.page_header>

      <%= if @live_action == :new and @service_options == [] do %>
        <.empty_state icon="lucide-sliders-horizontal" title="Nothing left to configure">
          <:subtitle>Every service already has its own rule.</:subtitle>
          <:actions>
            <.link navigate={alert_rules_path(@current_scope)} class="btn btn-soft btn-sm">
              Back to alert rules
            </.link>
          </:actions>
        </.empty_state>
      <% else %>
        <.form for={@form} id="alert-rule-form" phx-change="validate" phx-submit="save">
          <div class="grid gap-4 lg:grid-cols-3">
            <div class="space-y-4 lg:col-span-2">
              <.card>
                <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-base-content/60">
                  Applies to
                </h2>

                <%= if @live_action == :new do %>
                  <.input
                    field={@form[:service_id]}
                    type="select"
                    label="Service"
                    prompt="Pick a service…"
                    options={@service_options}
                  />
                  <p class="text-xs text-base-content/50">
                    Pick a service to override how it is monitored, or the organization default
                    that every service without a rule falls back on.
                  </p>
                <% else %>
                  <div class="mb-1 text-sm font-medium">Service</div>
                  <div class="rounded-lg border border-base-300 bg-base-200/50 px-3 py-2 text-sm">
                    {@service_label}
                  </div>
                  <p class="text-xs text-base-content/50">
                    A rule keeps the service it belongs to; edit it to change how it is judged.
                  </p>
                <% end %>
              </.card>

              <.card>
                <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-base-content/60">
                  When it fails
                </h2>

                <div class="grid gap-3 sm:grid-cols-2">
                  <div>
                    <.input
                      field={@form[:failure_threshold]}
                      type="number"
                      label="Failures to mark down"
                      min="1"
                      max="100"
                    />
                    <p class="mt-1 text-xs text-base-content/50">
                      Consecutive failed checks before the service is reported down.
                    </p>
                  </div>

                  <div>
                    <.input
                      field={@form[:success_threshold]}
                      type="number"
                      label="Successes to recover"
                      min="1"
                      max="100"
                    />
                    <p class="mt-1 text-xs text-base-content/50">
                      Consecutive healthy checks before a down service recovers.
                    </p>
                  </div>
                </div>

                <div class="mt-4">
                  <label class="mb-1 block text-sm font-medium" for="degraded_percent">
                    Slow checks count as degraded at
                  </label>
                  <label class="input input-bordered flex items-center gap-2">
                    <input
                      type="number"
                      id="degraded_percent"
                      name="alert_rule[degraded_percent]"
                      value={percent_value(@form)}
                      min="5"
                      max="100"
                      step="5"
                      class="grow"
                    />
                    <span class="text-sm text-base-content/50">% of the timeout</span>
                  </label>
                  <p :for={msg <- errors_for(@form, :degraded_ratio)} class="mt-1 text-sm text-error">
                    {msg}
                  </p>
                  <p class="mt-1 text-xs text-base-content/50">
                    A check that answers at or above this share of the timeout is recorded as
                    degraded instead of healthy.
                  </p>
                </div>
              </.card>
            </div>

            <div class="space-y-4">
              <.card>
                <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-base-content/60">
                  Severity
                </h2>

                <.input
                  field={@form[:severity]}
                  type="select"
                  label="Incident severity"
                  options={Enum.map(AlertRule.severities(), &{Phoenix.Naming.humanize(&1), &1})}
                />
                <div class="mt-2">
                  <.severity_tag severity={severity_value(@form)} />
                </div>
                <p class="mt-3 text-xs text-base-content/50">
                  Severity of the incidents this rule opens.
                </p>
              </.card>

              <div class="flex flex-col gap-2">
                <.button id="save-rule-button" variant="primary" phx-disable-with="Saving...">
                  Save rule
                </.button>
                <.link navigate={alert_rules_path(@current_scope)} class="btn btn-soft">
                  Cancel
                </.link>
              </div>
            </div>
          </div>
        </.form>
      <% end %>
    </Layouts.app>
    """
  end

  defp errors_for(form, field) do
    form[field]
    |> then(&if(Phoenix.Component.used_input?(&1), do: &1.errors, else: []))
    |> Enum.map(&PulseOpsWeb.CoreComponents.translate_error/1)
  end
end
