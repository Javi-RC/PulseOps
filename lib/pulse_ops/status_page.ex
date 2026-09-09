defmodule PulseOps.StatusPage do
  @moduledoc """
  Read-only view of an organization for people who are not signed in.

  Everywhere else in this application a context function takes a `%Scope{}` and
  filters by `scope.organization.id`, and the caller had to get through
  `on_mount :require_organization` to hold one. This module is the deliberate
  exception: anybody with the URL can call it. Keeping that exception in a
  module of its own means it is one file to review rather than a scattering of
  `public_`-prefixed functions sitting next to scoped ones.

  Two rules hold everything here together:

    * **Opt in, twice.** An organization publishes nothing until
      `status_page_enabled` is set, and a service appears only while its own
      `public` flag is set.

    * **The queries select the safe columns by name.** A service's `url` is the
      whole point of an SSRF guard existing and is often an internal hostname;
      an incident's `cause` and its timeline are written by staff for staff.
      None of them are fetched at all, so no template can render one by
      accident and no future change to a template can start leaking one.
  """

  import Ecto.Query, warn: false

  alias PulseOps.Accounts.Scope
  alias PulseOps.Incidents.Incident
  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.Service
  alias PulseOps.Organizations.Organization
  alias PulseOps.Repo

  @doc """
  The organization published under this slug, or nil.

  An organization that has not enabled its status page is indistinguishable from
  one that does not exist, so the page cannot be used to discover who has an
  account here.
  """
  @spec get_organization(String.t()) :: Organization.t() | nil
  def get_organization(slug) when is_binary(slug) do
    Repo.one(
      from o in Organization,
        where: o.slug == ^slug and o.status_page_enabled == true,
        select: %Organization{
          id: o.id,
          name: o.name,
          slug: o.slug,
          status_page_enabled: o.status_page_enabled,
          status_page_headline: o.status_page_headline
        }
    )
  end

  def get_organization(_other), do: nil

  @doc """
  Everything the public page renders, in one call.
  """
  @spec overview(Organization.t()) :: map()
  def overview(%Organization{} = organization) do
    services = list_public_services(organization)
    ids = Enum.map(services, & &1.id)
    scope = Scope.for_public_organization(organization)

    %{
      services: services,
      uptime: Map.take(Monitoring.uptime_by_service(scope), ids),
      history: Map.take(Monitoring.recent_checks_by_service(scope), ids),
      active_incidents: list_incidents(organization, ids, :active),
      past_incidents: list_incidents(organization, ids, :past),
      overall: overall_status(services)
    }
  end

  @doc """
  Subscribes to the same topics the signed-in dashboard uses, so a public page
  updates live over the connection it already has.
  """
  @spec subscribe(Organization.t()) :: :ok
  def subscribe(%Organization{} = organization) do
    scope = Scope.for_public_organization(organization)
    Monitoring.subscribe_services(scope)
    PulseOps.Incidents.subscribe_incidents(scope)
    :ok
  end

  # Explicit columns: url, check_interval_ms and timeout_ms are never fetched.
  defp list_public_services(%Organization{id: organization_id}) do
    from(s in Service,
      where: s.organization_id == ^organization_id,
      where: s.public == true and s.enabled == true,
      order_by: [asc: s.name],
      select: %{
        id: s.id,
        name: s.name,
        description: s.description,
        environment: s.environment,
        status: s.status,
        last_checked_at: s.last_checked_at
      }
    )
    |> Repo.all()
  end

  # Likewise: no cause, no resolver, no timeline. A status page says what broke
  # and for how long, not what staff wrote to each other about it.
  defp list_incidents(_organization, [], _which), do: []

  defp list_incidents(%Organization{id: organization_id}, service_ids, which) do
    from(i in Incident,
      where: i.organization_id == ^organization_id,
      where: i.service_id in ^service_ids,
      order_by: [desc: i.started_at],
      select: %{
        id: i.id,
        service_id: i.service_id,
        title: i.title,
        severity: i.severity,
        status: i.status,
        started_at: i.started_at,
        resolved_at: i.resolved_at
      }
    )
    |> filter_incidents(which)
    |> Repo.all()
  end

  defp filter_incidents(query, :active), do: where(query, [i], is_nil(i.resolved_at))

  defp filter_incidents(query, :past) do
    query
    |> where([i], not is_nil(i.resolved_at))
    |> limit(20)
  end

  defp overall_status([]), do: :unknown

  defp overall_status(services) do
    statuses = MapSet.new(services, & &1.status)

    cond do
      MapSet.member?(statuses, :down) -> :down
      MapSet.member?(statuses, :degraded) -> :degraded
      MapSet.member?(statuses, :healthy) -> :healthy
      true -> :unknown
    end
  end
end
