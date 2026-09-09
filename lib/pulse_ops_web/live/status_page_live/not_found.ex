defmodule PulseOpsWeb.StatusPageLive.NotFound do
  @moduledoc """
  Raised when a status page slug does not resolve to a published organization.

  An organization that exists but has not published, and one that never existed,
  both raise this — so the page cannot be used to enumerate who has an account.
  """

  defexception message: "no status page here", plug_status: 404
end
