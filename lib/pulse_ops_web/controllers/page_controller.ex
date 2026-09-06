defmodule PulseOpsWeb.PageController do
  use PulseOpsWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
