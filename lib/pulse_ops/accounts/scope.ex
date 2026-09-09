defmodule PulseOps.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `PulseOps.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use in authorization checks,
  or to ensure specific code paths can only be accessed for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
  """

  alias PulseOps.Accounts.User
  alias PulseOps.Organizations.Organization

  @type t :: %__MODULE__{}

  defstruct user: nil, organization: nil, role: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc """
  A scope for an anonymous visitor to an organization's public status page.

  It carries the organization so the existing read functions filter by tenant
  exactly as they do for a signed-in user, and carries no user and no role, so
  `Organizations.can?/2` denies every action — a visitor can be shown things and
  can do nothing. That is the whole difference between this and a real session,
  and it is enforced by the same code path rather than by a parallel one.
  """
  def for_public_organization(%Organization{} = organization) do
    %__MODULE__{user: nil, organization: organization, role: nil}
  end

  @doc """
  Narrows the scope to one organization and the caller's role in it.

  Contexts filter every query by `scope.organization.id`, so a scope without an
  organization cannot reach tenant data at all.
  """
  def put_organization(%__MODULE__{} = scope, %Organization{} = organization, role) do
    %{scope | organization: organization, role: role}
  end
end
