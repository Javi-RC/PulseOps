defmodule PulseOps.OrganizationsFixtures do
  @moduledoc """
  Test fixtures for `PulseOps.Organizations`.
  """

  alias PulseOps.Accounts.Scope
  alias PulseOps.Organizations
  alias PulseOps.Organizations.Membership
  alias PulseOps.Repo

  def unique_organization_name, do: "Org #{System.unique_integer([:positive])}"

  @doc """
  Creates an organization owned by the given user.
  """
  def organization_fixture(user, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{name: unique_organization_name()})
    {:ok, organization} = Organizations.create_organization(user, attrs)
    organization
  end

  @doc """
  Adds a user to an organization with the given role.
  """
  def membership_fixture(organization, user, role) do
    %Membership{}
    |> Membership.changeset(%{
      organization_id: organization.id,
      user_id: user.id,
      role: role
    })
    |> Repo.insert!()
  end

  @doc """
  Builds a scope narrowed to an organization, as `on_mount :require_organization`
  would produce it.
  """
  def organization_scope(user, organization, role \\ :owner) do
    user
    |> Scope.for_user()
    |> Scope.put_organization(organization, role)
  end
end
