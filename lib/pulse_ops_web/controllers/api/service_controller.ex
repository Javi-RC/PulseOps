defmodule PulseOpsWeb.Api.ServiceController do
  @moduledoc """
  Services over HTTP.

  Every action calls the same `PulseOps.Monitoring` function the LiveViews call,
  with the scope the token produced. The tenant filter and the role check are
  already inside those functions, so there is nothing to enforce here — which is
  the point of building the API on a scope rather than beside the domain.
  """

  use PulseOpsWeb, :controller

  alias PulseOps.Monitoring

  action_fallback PulseOpsWeb.Api.FallbackController

  def index(conn, _params) do
    render(conn, :index, services: Monitoring.list_services(conn.assigns.current_scope))
  end

  def show(conn, %{"id" => id}) do
    with {:ok, service} <- fetch(conn, id) do
      render(conn, :show, service: service)
    end
  end

  def create(conn, params) do
    with {:ok, service} <- Monitoring.create_service(conn.assigns.current_scope, attrs(params)) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/v1/services/#{service.id}")
      |> render(:show, service: service)
    end
  end

  def update(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope

    with {:ok, service} <- fetch(conn, id),
         {:ok, updated} <- Monitoring.update_service(scope, service, attrs(params)) do
      render(conn, :show, service: updated)
    end
  end

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    with {:ok, service} <- fetch(conn, id),
         {:ok, _deleted} <- Monitoring.delete_service(scope, service) do
      send_resp(conn, :no_content, "")
    end
  end

  # get_service!/2 raises for a missing id or another tenant's, which is right
  # for a LiveView and wrong for an API that has to answer 404 either way.
  defp fetch(conn, id) do
    {:ok, Monitoring.get_service!(conn.assigns.current_scope, id)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :not_found}
  end

  # The API takes a flat JSON object; the changesets take a map of attributes.
  # Dropping the routing key here keeps "id" from ever being cast as a field.
  defp attrs(params), do: Map.drop(params, ["id"])
end
