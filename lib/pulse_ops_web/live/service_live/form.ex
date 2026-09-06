defmodule PulseOpsWeb.ServiceLive.Form do
  use PulseOpsWeb, :live_view

  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.Service

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {@page_title}
        <:subtitle>Use this form to manage service records in your database.</:subtitle>
      </.header>

      <.form for={@form} id="service-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:name]} type="text" label="Name" />
        <.input field={@form[:description]} type="textarea" label="Description" />
        <.input
          field={@form[:environment]}
          type="select"
          label="Environment"
          options={Enum.map(Service.environments(), &{Phoenix.Naming.humanize(&1), &1})}
        />
        <.input field={@form[:url]} type="url" label="Health check URL" />
        <.input
          field={@form[:check_interval_ms]}
          type="number"
          label="Check interval (ms)"
          step="1000"
        />
        <.input field={@form[:timeout_ms]} type="number" label="Timeout (ms)" step="500" />
        <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
        <%!-- Status and last_checked_at are owned by the monitor process, so they
              are deliberately absent from this form. --%>
        <footer>
          <.button phx-disable-with="Saving..." variant="primary">Save Service</.button>
          <.button navigate={return_path(@current_scope, @return_to, @service)}>Cancel</.button>
        </footer>
      </.form>
    </Layouts.app>
    """
  end

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
    |> assign(:page_title, "Edit Service")
    |> assign(:service, service)
    |> assign(:form, to_form(Monitoring.change_service(socket.assigns.current_scope, service)))
  end

  defp apply_action(socket, :new, _params) do
    service = %Service{organization_id: socket.assigns.current_scope.organization.id}

    socket
    |> assign(:page_title, "New Service")
    |> assign(:service, service)
    |> assign(:form, to_form(Monitoring.change_service(socket.assigns.current_scope, service)))
  end

  @impl true
  def handle_event("validate", %{"service" => service_params}, socket) do
    changeset =
      Monitoring.change_service(
        socket.assigns.current_scope,
        socket.assigns.service,
        service_params
      )

    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"service" => service_params}, socket) do
    save_service(socket, socket.assigns.live_action, service_params)
  end

  defp save_service(socket, :edit, service_params) do
    case Monitoring.update_service(
           socket.assigns.current_scope,
           socket.assigns.service,
           service_params
         ) do
      {:ok, service} ->
        {:noreply,
         socket
         |> put_flash(:info, "Service updated successfully")
         |> push_navigate(
           to: return_path(socket.assigns.current_scope, socket.assigns.return_to, service)
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, "You do not have permission to manage services.")
         |> push_navigate(
           to: ~p"/orgs/#{socket.assigns.current_scope.organization.slug}/services"
         )}
    end
  end

  defp save_service(socket, :new, service_params) do
    case Monitoring.create_service(socket.assigns.current_scope, service_params) do
      {:ok, service} ->
        {:noreply,
         socket
         |> put_flash(:info, "Service created successfully")
         |> push_navigate(
           to: return_path(socket.assigns.current_scope, socket.assigns.return_to, service)
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, "You do not have permission to manage services.")
         |> push_navigate(
           to: ~p"/orgs/#{socket.assigns.current_scope.organization.slug}/services"
         )}
    end
  end

  defp return_path(scope, "index", _service), do: ~p"/orgs/#{scope.organization.slug}/services"

  defp return_path(scope, "show", service),
    do: ~p"/orgs/#{scope.organization.slug}/services/#{service}"
end
