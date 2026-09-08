defmodule PulseOpsWeb.AlertRuleLive.Index do
  @moduledoc """
  Lists the alert rules of an organization: the default every service falls
  back on, plus the per-service overrides. Deleting a rule puts the affected
  service back on the organization default.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.MonitoringComponents
  import PulseOpsWeb.UIComponents

  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.AlertRule
  alias PulseOps.Organizations

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Alert rules") |> load_rules()}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Enum.find(socket.assigns.rules, &(&1.id == String.to_integer(id))) do
      nil ->
        {:noreply, socket}

      rule ->
        case Monitoring.delete_alert_rule(scope, rule) do
          {:ok, _rule} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Rule removed; the service falls back on the organization default."
             )
             |> load_rules()}

          {:error, :unauthorized} ->
            {:noreply, put_flash(socket, :error, "You do not have permission to do that.")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "That rule could not be removed.")}
        end
    end
  end

  defp load_rules(socket) do
    scope = socket.assigns.current_scope
    rules = Monitoring.list_alert_rules(scope)

    socket
    |> assign(:rules, rules)
    |> assign(:default_rule, Enum.find(rules, &is_nil(&1.service_id)) || AlertRule.default())
    |> assign(:service_rules, Enum.reject(rules, &is_nil(&1.service_id)))
    |> assign(:can_manage?, Organizations.can?(scope, :manage_organization))
  end

  defp percent(nil), do: "—"
  defp percent(ratio), do: "#{round(ratio * 100)}%"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      organizations={@organizations}
      current_path={@current_path}
    >
      <.page_header title="Alert rules">
        <:subtitle>
          How many failed checks mark a service down, how quickly it may recover, and how the
          incident that follows is classified.
        </:subtitle>
        <:actions>
          <.link
            :if={@can_manage?}
            id="new-rule-link"
            navigate={~p"/orgs/#{@current_scope.organization.slug}/settings/alert-rules/new"}
            class="btn btn-primary btn-sm"
          >
            <.icon name="lucide-plus" class="size-4" /> New rule
          </.link>
        </:actions>
      </.page_header>

      <.card id="default-rule-card" class="mb-6">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div class="min-w-0">
            <p class="font-medium">Organization default</p>
            <p class="mt-0.5 text-sm text-base-content/50">
              Apply when a service has no rule of its own.
            </p>
          </div>

          <div class="flex flex-col items-end gap-3 sm:flex-row sm:items-center">
            <div class="flex flex-wrap gap-x-6 gap-y-2 text-sm">
              <div>
                <div class="text-xs uppercase tracking-wide text-base-content/50">
                  Failures to mark down
                </div>
                <div class="mt-0.5 font-semibold">{@default_rule.failure_threshold}</div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-base-content/50">
                  Successes to recover
                </div>
                <div class="mt-0.5 font-semibold">{@default_rule.success_threshold}</div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-base-content/50">
                  Degraded at
                </div>
                <div class="mt-0.5 font-semibold">{percent(@default_rule.degraded_ratio)}</div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-base-content/50">
                  Incident severity
                </div>
                <div class="mt-1"><.severity_tag severity={@default_rule.severity} /></div>
              </div>
            </div>

            <div class="flex items-center gap-2">
              <%= if is_nil(@default_rule.id) do %>
                <%= if @can_manage? do %>
                  <.link
                    id="configure-defaults-link"
                    navigate={~p"/orgs/#{@current_scope.organization.slug}/settings/alert-rules/new"}
                    class="btn btn-soft btn-sm"
                  >
                    Configure defaults
                  </.link>
                <% else %>
                  <span class="flex items-center gap-1 text-xs text-base-content/50">
                    <.icon name="lucide-info" class="size-4" /> Using the built-in defaults
                  </span>
                <% end %>
              <% else %>
                <%= if @can_manage? do %>
                  <.link
                    id="edit-default-rule-link"
                    navigate={
                      ~p"/orgs/#{@current_scope.organization.slug}/settings/alert-rules/#{@default_rule.id}/edit"
                    }
                    class="btn btn-soft btn-sm"
                  >
                    Edit
                  </.link>
                <% end %>
              <% end %>
            </div>
          </div>
        </div>
      </.card>

      <section>
        <div class="mb-3 flex items-end justify-between gap-4">
          <div>
            <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
              Per-service rules
            </h2>
            <p class="text-xs text-base-content/50">Overrides that apply to one service only.</p>
          </div>
        </div>

        <%= if @service_rules == [] do %>
          <.empty_state icon="lucide-sliders-horizontal" title="No per-service rules yet">
            <:subtitle>Every service follows the organization default.</:subtitle>
            <:actions>
              <.link
                :if={@can_manage?}
                navigate={~p"/orgs/#{@current_scope.organization.slug}/settings/alert-rules/new"}
                class="btn btn-soft btn-sm"
              >
                Add a rule
              </.link>
            </:actions>
          </.empty_state>
        <% else %>
          <.card id="service-rules" padded={false} class="divide-y divide-base-200">
            <div
              :for={rule <- @service_rules}
              id={"rule-#{rule.id}"}
              class="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3"
            >
              <.severity_tag severity={rule.severity} />
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2">
                  <p class="truncate text-sm font-medium">{rule.service.name}</p>
                  <span class="text-xs capitalize text-base-content/50">
                    {rule.service.environment}
                  </span>
                </div>
                <p class="mt-0.5 text-xs text-base-content/50">
                  {rule.failure_threshold} failures · {rule.success_threshold} successes to
                  recover · degraded at {percent(rule.degraded_ratio)}
                </p>
              </div>
              <%= if @can_manage? do %>
                <div class="flex items-center gap-1">
                  <.link
                    navigate={
                      ~p"/orgs/#{@current_scope.organization.slug}/settings/alert-rules/#{rule.id}/edit"
                    }
                    class="btn btn-ghost btn-sm"
                  >
                    Edit
                  </.link>
                  <button
                    type="button"
                    phx-click="delete"
                    phx-value-id={rule.id}
                    data-confirm={"Remove the rule for #{rule.service.name}? It will fall back on the organization default."}
                    class="btn btn-ghost btn-sm text-error"
                    aria-label={"Delete rule for #{rule.service.name}"}
                  >
                    <.icon name="lucide-trash" class="size-4" />
                  </button>
                </div>
              <% end %>
            </div>
          </.card>
        <% end %>
      </section>
    </Layouts.app>
    """
  end
end
