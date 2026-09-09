defmodule PulseOpsWeb.Api.FallbackController do
  @moduledoc """
  Turns the tagged tuples the contexts already return into HTTP.

  The contexts answer `{:error, :unauthorized}`, `{:error, %Ecto.Changeset{}}`
  and so on whoever is asking; this is the only place that decides what those
  mean over HTTP, so a controller never has to.
  """

  use PulseOpsWeb, :controller

  alias PulseOpsWeb.Api.ErrorJSON

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:forbidden)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: "forbidden", message: "This token's role may not do that.")
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: "not_found", message: "No such resource in this organization.")
  end

  def call(conn, {:error, :already_resolved}) do
    conn
    |> put_status(:conflict)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: "already_resolved", message: "That incident is already resolved.")
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ErrorJSON)
    |> render(:invalid, changeset: changeset)
  end
end
