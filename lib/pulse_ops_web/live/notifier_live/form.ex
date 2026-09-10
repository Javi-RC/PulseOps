defmodule PulseOpsWeb.NotifierLive.Form do
  @moduledoc """
  Creates and edits a notification channel. The channel type decides which
  destination field is shown and required: a URL for webhooks and, for email,
  the organization users it reaches. A notifier may be narrowed to a single
  service, so incidents elsewhere never trigger it.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.UIComponents

  alias Phoenix.HTML.Form
  alias PulseOps.Monitoring
  alias PulseOps.Notifications
  alias PulseOps.Notifications.Notifier

  @impl true
  def mount(params, _session, socket) do
    {:ok, socket |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case Notifications.get_notifier(scope, id) do
      nil ->
        socket
        |> put_flash(:error, "That notifier was not found.")
        |> push_navigate(to: notifiers_path(scope))

      notifier ->
        socket
        |> assign(:page_title, "Edit notifier")
        |> assign(:notifier, notifier)
        |> assign_choices()
        |> assign_form(Notifications.change_notifier(scope, notifier))
    end
  end

  defp apply_action(socket, :new, _params) do
    scope = socket.assigns.current_scope
    notifier = %Notifier{organization_id: scope.organization.id, type: :webhook}

    socket
    |> assign(:page_title, "New notifier")
    |> assign(:notifier, notifier)
    |> assign_choices()
    |> assign_form(Notifications.change_notifier(scope, notifier))
  end

  @impl true
  def handle_event("validate", %{"notifier" => params}, socket) do
    changeset =
      Notifications.change_notifier(
        socket.assigns.current_scope,
        socket.assigns.notifier,
        normalize(params)
      )

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"notifier" => params}, socket) do
    save_notifier(socket, socket.assigns.live_action, normalize(params))
  end

  defp save_notifier(socket, :new, params) do
    case Notifications.create_notifier(socket.assigns.current_scope, params) do
      {:ok, _notifier} -> respond(socket, "Notifier created.")
      {:error, %Ecto.Changeset{} = changeset} -> {:noreply, assign_form(socket, changeset)}
      {:error, :unauthorized} -> forbidden(socket)
    end
  end

  defp save_notifier(socket, :edit, params) do
    case Notifications.update_notifier(
           socket.assigns.current_scope,
           socket.assigns.notifier,
           params
         ) do
      {:ok, _notifier} -> respond(socket, "Notifier updated.")
      {:error, %Ecto.Changeset{} = changeset} -> {:noreply, assign_form(socket, changeset)}
      {:error, :unauthorized} -> forbidden(socket)
    end
  end

  defp respond(socket, message) do
    {:noreply,
     socket
     |> put_flash(:info, message)
     |> push_navigate(to: notifiers_path(socket.assigns.current_scope))}
  end

  defp forbidden(socket) do
    {:noreply,
     socket
     |> put_flash(:error, "You do not have permission to manage notifications.")
     |> push_navigate(to: notifiers_path(socket.assigns.current_scope))}
  end

  defp assign_choices(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      services: Monitoring.list_services(scope),
      assignees: Notifications.assignee_options(scope)
    )
  end

  # An unchecked checkbox submits nothing, so the changeset would never see the
  # toggle turned off. Falling back to "false" keeps the boolean honest in both
  # directions.
  defp normalize(params) do
    params
    |> Map.put_new("enabled", "false")
    |> Map.put_new("escalation_only", "false")
  end

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset))
  end

  # "webhook" is the default for a fresh form, and the values the Ecto.Enum has
  # already turned into atoms while editing.
  defp channel_type(form) do
    case Form.input_value(form, :type) do
      nil -> :webhook
      "email" -> :email
      "webhook" -> :webhook
      :email -> :email
      _other -> :webhook
    end
  end

  defp notifiers_path(scope), do: ~p"/orgs/#{scope.organization.slug}/settings/notifiers"

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
          Incidents are announced to the people and receivers assigned to a notifier when
          they open and when they resolve. Pause a notifier to keep it around without
          hearing from it.
        </:subtitle>
      </.page_header>

      <.form for={@form} id="notifier-form" phx-change="validate" phx-submit="save">
        <div class="grid gap-4 lg:grid-cols-3">
          <div class="space-y-4 lg:col-span-2">
            <.card>
              <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-base-content/60">
                Channel
              </h2>

              <.input field={@form[:name]} type="text" label="Name" required />
              <.input
                field={@form[:type]}
                type="select"
                label="Type"
                options={Enum.map(Notifier.types(), &{Phoenix.Naming.humanize(&1), &1})}
              />

              <div class="mt-4">
                <.input
                  field={@form[:service_id]}
                  type="select"
                  label="Scope"
                  prompt="Every service in the organization"
                  options={Enum.map(@services, &{&1.name, &1.id})}
                />
                <p class="mt-1 text-xs text-base-content/50">
                  Leave on "Every service" to fire for any incident, or pick one service to be
                  told only about it.
                </p>
              </div>

              <%= if channel_type(@form) == :webhook do %>
                <div class="mt-4">
                  <.input
                    field={@form[:url]}
                    type="url"
                    label="Webhook URL"
                    placeholder="https://hooks.example.com/…"
                    required
                  />
                  <p class="mt-1 text-xs text-base-content/50">
                    The endpoint is POSTed a JSON document about each incident. Discord, Teams,
                    Mattermost, ntfy and most automation tools accept one of their own.
                  </p>
                </div>
                <div class="mt-4">
                  <%!-- value="" on purpose: the core input would otherwise fill a
                       password field from the form, putting the stored token in
                       the page source. --%>
                  <.input
                    field={@form[:secret_token]}
                    type="password"
                    label="Secret token"
                    autocomplete="new-password"
                    value=""
                    placeholder={@notifier.secret_token && "Leave blank to keep the current token"}
                  />
                  <p :if={is_nil(@notifier.secret_token)} class="mt-1 text-xs text-base-content/50">
                    Optional. Sent as a Bearer token in the Authorization header.
                  </p>
                  <p :if={@notifier.secret_token} class="mt-1 text-xs text-base-content/50">
                    A token is set. It is never shown again; type a new one to replace it.
                  </p>
                  <div :if={@notifier.secret_token} class="mt-2">
                    <.input
                      field={@form[:clear_secret_token]}
                      type="checkbox"
                      label="Remove the token"
                    />
                  </div>
                </div>
              <% end %>
            </.card>

            <.card>
              <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-base-content/60">
                People
              </h2>
              <.input
                field={@form[:assignee_ids]}
                type="select"
                multiple
                label="Assigned members"
                options={@assignees}
              />
              <p class="mt-1 text-xs text-base-content/50">
                Email notifiers send a copy to every member selected here. Webhooks treat the
                selection as the people responsible for the channel.
              </p>

              <div class="mt-5">
                <.input
                  field={@form[:enabled]}
                  type="checkbox"
                  label="Enabled"
                />
                <p class="mt-1 text-xs text-base-content/50">
                  When off, the notifier is kept but nothing is sent to it.
                </p>
              </div>

              <div class="mt-4">
                <.input
                  field={@form[:escalation_only]}
                  type="checkbox"
                  label="Only for escalations"
                />
                <p class="mt-1 text-xs text-base-content/50">
                  Stays quiet for ordinary incidents. Told only when a critical one has gone
                  unacknowledged — which is the point of having a second line.
                </p>
              </div>
            </.card>
          </div>

          <div class="space-y-4">
            <.card>
              <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-base-content/60">
                What arrives
              </h2>
              <ul class="space-y-2 text-sm text-base-content/70">
                <li class="flex items-start gap-2">
                  <.icon name="lucide-triangle-alert" class="mt-0.5 size-4 shrink-0 text-error" />
                  Incident opened — severity, status, service and a link.
                </li>
                <li class="flex items-start gap-2">
                  <.icon name="lucide-check-circle" class="mt-0.5 size-4 shrink-0 text-success" />
                  Incident resolved — how long it lasted and the cause, when set.
                </li>
              </ul>
            </.card>

            <div class="flex flex-col gap-2">
              <.button id="save-notifier-button" variant="primary" phx-disable-with="Saving...">
                Save notifier
              </.button>
              <.link navigate={notifiers_path(@current_scope)} class="btn btn-soft">
                Cancel
              </.link>
            </div>
          </div>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
