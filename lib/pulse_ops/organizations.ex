defmodule PulseOps.Organizations do
  @moduledoc """
  Organizations are the tenant boundary: every other resource in the system
  hangs off one, and access is decided by the caller's membership role.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias PulseOps.Accounts.Scope
  alias PulseOps.Accounts.User
  alias PulseOps.Organizations.Membership
  alias PulseOps.Organizations.Organization
  alias PulseOps.Repo

  @doc """
  Lists the organizations the user belongs to, alphabetically.
  """
  def list_organizations_for_user(%User{id: user_id}) do
    Repo.all(
      from o in Organization,
        join: m in Membership,
        on: m.organization_id == o.id,
        where: m.user_id == ^user_id,
        order_by: o.name
    )
  end

  @doc """
  Fetches an organization by slug. Returns nil when there is no match.
  """
  def get_organization_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Organization, slug: slug)
  end

  @doc """
  Fetches the user's membership in an organization, or nil.
  """
  def get_membership(%Organization{id: org_id}, %User{id: user_id}) do
    Repo.get_by(Membership, organization_id: org_id, user_id: user_id)
  end

  @doc """
  Loads an organization by slug together with the user's role in it.

  Returns `{:error, :not_found}` both when the organization does not exist and
  when the user is not a member, so that the caller cannot use this to probe
  which slugs are taken.
  """
  def fetch_for_user(slug, %User{} = user) when is_binary(slug) do
    case get_organization_by_slug(slug) do
      nil ->
        {:error, :not_found}

      organization ->
        case get_membership(organization, user) do
          nil -> {:error, :not_found}
          membership -> {:ok, organization, membership.role}
        end
    end
  end

  @doc """
  Creates an organization and makes the given user its owner.

  Both rows are written in one transaction: an organization with no members
  would be unreachable.
  """
  def create_organization(%User{} = user, attrs) do
    Multi.new()
    |> Multi.insert(:organization, Organization.changeset(%Organization{}, attrs))
    |> Multi.insert(:membership, fn %{organization: organization} ->
      Membership.changeset(%Membership{}, %{
        organization_id: organization.id,
        user_id: user.id,
        role: :owner
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{organization: organization}} -> {:ok, organization}
      {:error, :organization, changeset, _changes} -> {:error, changeset}
      {:error, :membership, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Builds the personal organization for a freshly registered user, as part of the
  caller's transaction.

  New users would otherwise land on an empty account with nothing they are
  allowed to do. The slug is derived from the email local part and de-duplicated
  with a numeric suffix, since two people can register `javier@` on different
  domains.
  """
  def create_personal_organization_multi(multi, user_key) do
    multi
    |> Multi.insert(:personal_organization, fn changes ->
      user = Map.fetch!(changes, user_key)
      name = user.email |> String.split("@") |> List.first()

      Organization.changeset(%Organization{}, %{
        name: name,
        slug: unique_slug(Organization.slugify(name))
      })
    end)
    |> Multi.insert(:personal_membership, fn changes ->
      user = Map.fetch!(changes, user_key)

      Membership.changeset(%Membership{}, %{
        organization_id: changes.personal_organization.id,
        user_id: user.id,
        role: :owner
      })
    end)
  end

  defp unique_slug(base) do
    base = if base == "", do: "org", else: base

    if Repo.exists?(from o in Organization, where: o.slug == ^base) do
      # Not race-free on its own; the unique index is the actual guarantee and
      # registration retries are cheap.
      "#{base}-#{System.unique_integer([:positive])}"
    else
      base
    end
  end

  @doc """
  Changeset for organization forms.
  """
  def change_organization(%Organization{} = organization, attrs \\ %{}) do
    Organization.changeset(organization, attrs)
  end

  ## Authorization

  @writers [:owner, :admin]
  @responders [:owner, :admin, :member]

  @doc """
  Whether the scope's role permits an action.

  Authorization lives here rather than in the templates: hiding a button does
  not stop a crafted request.
  """
  def can?(scope, action)

  def can?(%Scope{role: role}, :manage_services), do: role in @writers
  def can?(%Scope{role: role}, :manage_organization), do: role in @writers
  def can?(%Scope{role: role}, :respond_to_incidents), do: role in @responders
  def can?(%Scope{role: role}, :view), do: role in Membership.roles()
  def can?(_scope, _action), do: false

  @doc """
  Same as `can?/2` but returns a tagged tuple, for use in `with` chains.
  """
  def authorize(scope, action) do
    if can?(scope, action), do: :ok, else: {:error, :unauthorized}
  end
end
