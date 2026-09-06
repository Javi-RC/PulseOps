defmodule PulseOpsWeb.PageController do
  @moduledoc """
  The landing page. A logged-in user goes straight to their dashboard — the
  marketing page is not what they came back for.
  """

  use PulseOpsWeb, :controller

  alias PulseOpsWeb.UserAuth

  def home(conn, _params) do
    case conn.assigns[:current_scope] do
      %{user: %{} = user} -> redirect(conn, to: UserAuth.organization_path(user))
      _otherwise -> render(conn, :home)
    end
  end
end
