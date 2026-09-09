defmodule PulseOpsWeb.Api.IncidentController do
  @moduledoc """
  Incidents over HTTP.

  Moving one through the workflow and resolving it are separate actions for the
  same reason they are separate context functions: resolving also stamps who did
  it and when, and the workflow changeset deliberately refuses to set `resolved`.
  """

  use PulseOpsWeb, :controller

  alias PulseOps.Incidents

  action_fallback PulseOpsWeb.Api.FallbackController

  def index(conn, params) do
    opts = limit_option(params)

    render(conn, :index, incidents: Incidents.list_incidents(conn.assigns.current_scope, opts))
  end

  def show(conn, %{"id" => id}) do
    with {:ok, incident} <- fetch(conn, id) do
      render(conn, :show, incident: incident)
    end
  end

  def update(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope

    with {:ok, incident} <- fetch(conn, id),
         {:ok, updated} <- Incidents.update_incident(scope, incident, attrs(params)) do
      render(conn, :show, incident: updated)
    end
  end

  def resolve(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope

    with {:ok, incident} <- fetch(conn, id),
         {:ok, resolved} <- Incidents.resolve_incident(scope, incident, attrs(params)) do
      render(conn, :show, incident: resolved)
    end
  end

  defp fetch(conn, id) do
    {:ok, Incidents.get_incident!(conn.assigns.current_scope, id)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp limit_option(%{"limit" => limit}) do
    case Integer.parse(to_string(limit)) do
      {value, _rest} when value > 0 -> [limit: min(value, 200)]
      _otherwise -> []
    end
  end

  defp limit_option(_params), do: []

  defp attrs(params), do: Map.drop(params, ["id"])
end
