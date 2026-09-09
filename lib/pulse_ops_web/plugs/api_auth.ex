defmodule PulseOpsWeb.Plugs.ApiAuth do
  @moduledoc """
  Turns a bearer token into `conn.assigns.current_scope`.

  From there every API controller calls the same context functions the LiveViews
  call, and the tenant filtering and role checks that already live in those
  contexts apply unchanged. Nothing about authorization is restated here.

  A missing, malformed, unknown or revoked token are all one answer: 401 with no
  detail. Distinguishing them would say whether a token had ever existed.
  """

  import Plug.Conn

  alias PulseOps.Api

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, presented} <- bearer_token(conn),
         {:ok, scope} <- Api.scope_for_token(presented) do
      assign(conn, :current_scope, scope)
    else
      _otherwise -> unauthorized(conn)
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> presented] when byte_size(presented) > 0 -> {:ok, presented}
      _otherwise -> :error
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      401,
      Jason.encode!(%{
        error: %{
          code: "unauthorized",
          message: "Provide a valid organization token as `Authorization: Bearer <token>`."
        }
      })
    )
    |> halt()
  end
end
