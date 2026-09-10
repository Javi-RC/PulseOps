defmodule PulseOps.Links do
  @moduledoc """
  Links to PulseOps pages that the domain has to hand out — in a webhook
  payload, in an email — from places with no request to build them from.

  The base comes from `config :pulse_ops, :public_url`, not from the endpoint:
  the web layer depends on the domain, never the other way round
  (`PulseOps.BoundaryTest`). In production both are derived from
  `PHX_HOST` in `config/runtime.exs`, so they cannot disagree.

  The paths are written out rather than taken from the router for the same
  reason. They are the public shape of a link that has already been sent to
  people, which is not something to change casually anyway.
  """

  alias PulseOps.Incidents.Incident

  @doc """
  The page for an incident, or nil when its organization is not loaded.
  """
  @spec incident_url(Incident.t()) :: String.t() | nil
  def incident_url(%Incident{organization: %{slug: slug}, id: id}) when is_binary(slug) do
    base_url() <> "/orgs/#{slug}/incidents/#{id}"
  end

  def incident_url(%Incident{}), do: nil

  @doc """
  Where this installation is reached, without a trailing slash.
  """
  @spec base_url() :: String.t()
  def base_url do
    :pulse_ops
    |> Application.fetch_env!(:public_url)
    |> String.trim_trailing("/")
  end
end
