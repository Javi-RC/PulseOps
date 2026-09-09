defmodule PulseOps.Organizations do
  @moduledoc """
  Organizations are the tenant boundary: every other resource in the system
  hangs off one, and access is decided by the caller's membership role.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias PulseOps.Accounts.Scope
  alias PulseOps.Accounts.User
  alias PulseOps.Organizations.Invitation
  alias PulseOps.Organizations.InvitationNotifier
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

  ## Members

  @doc """
  Everyone in the scoped organization, owners first, then alphabetically.
  """
  def list_members(%Scope{} = scope) do
    Repo.all(
      from m in Membership,
        where: m.organization_id == ^scope.organization.id,
        join: u in assoc(m, :user),
        order_by: [asc: u.email],
        preload: [user: u]
    )
    # Role rank is an ordering of an enum, not of a column; sorting it in SQL
    # would mean a CASE expression for no gain on a list this size.
    |> Enum.sort_by(&{role_rank(&1.role), &1.user.email})
  end

  defp role_rank(role), do: Enum.find_index(Membership.roles(), &(&1 == role))

  @doc """
  Fetches a membership belonging to the scoped organization.
  """
  def get_member!(%Scope{} = scope, id) do
    Membership
    |> where([m], m.id == ^id and m.organization_id == ^scope.organization.id)
    |> preload(:user)
    |> Repo.one!()
  end

  @doc """
  Adds an already registered user to the organization.

  Returns `{:error, :not_found}` when nobody is registered with that address.
  Sending an invitation to a stranger needs its own token and email flow, which
  is not built yet — this is deliberately the smaller thing.
  """
  def add_member(%Scope{} = scope, email, role) do
    with :ok <- authorize(scope, :manage_organization),
         :ok <- authorize_role_assignment(scope, role),
         %User{} = user <- Repo.get_by(User, email: String.downcase(String.trim(email))) do
      %Membership{}
      |> Membership.changeset(%{
        organization_id: scope.organization.id,
        user_id: user.id,
        role: role
      })
      |> Repo.insert()
      |> case do
        {:ok, membership} -> {:ok, Repo.preload(membership, :user)}
        {:error, changeset} -> {:error, changeset}
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Changes a member's role.
  """
  def update_member_role(%Scope{} = scope, %Membership{} = membership, role) do
    with :ok <- authorize(scope, :manage_organization),
         :ok <- ensure_same_organization(scope, membership),
         :ok <- authorize_role_assignment(scope, role),
         :ok <- authorize_target(scope, membership),
         :ok <- ensure_not_last_owner(membership, role) do
      membership
      |> Membership.changeset(%{role: role})
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, Repo.preload(updated, :user)}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc """
  Removes a member from the organization.
  """
  def remove_member(%Scope{} = scope, %Membership{} = membership) do
    with :ok <- authorize(scope, :manage_organization),
         :ok <- ensure_same_organization(scope, membership),
         :ok <- authorize_target(scope, membership),
         :ok <- ensure_not_last_owner(membership, nil) do
      Repo.delete(membership)
    end
  end

  @doc """
  Renames an organization or changes its slug.
  """
  def update_organization(%Scope{} = scope, %Organization{} = organization, attrs) do
    true = organization.id == scope.organization.id

    with :ok <- authorize(scope, :manage_organization) do
      organization
      |> Organization.changeset(attrs)
      |> Repo.update()
    end
  end

  @doc """
  How many owners the organization has.
  """
  def owner_count(organization_id) do
    Repo.aggregate(
      from(m in Membership, where: m.organization_id == ^organization_id and m.role == :owner),
      :count
    )
  end

  # An organization with no owner cannot be administered by anybody, including
  # the person who just locked themselves out of it.
  defp ensure_not_last_owner(%Membership{role: :owner} = membership, new_role)
       when new_role != :owner do
    if owner_count(membership.organization_id) <= 1 do
      {:error, :last_owner}
    else
      :ok
    end
  end

  defp ensure_not_last_owner(_membership, _new_role), do: :ok

  # An admin manages members, but promoting somebody to owner — or editing an
  # existing owner — is an owner's decision.

  ## Invitations

  @doc """
  Invites an address to the organization, whether or not it has an account here.

  Replaces any invitation already waiting for that address, so re-inviting
  somebody does not leave two live links. Returns `{:ok, invitation, token}`;
  the token is the secret in the emailed link and is never stored.

  `url_fun` turns the token into the link to put in the email. The caller
  supplies it because building a URL is the web layer's job, not the domain's —
  the same reason `Accounts.deliver_login_instructions/2` takes one.
  """
  @spec invite_member(Scope.t(), String.t(), atom(), (String.t() -> String.t()) | nil) ::
          {:ok, Invitation.t(), String.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :unauthorized | :owner_required | :already_a_member}
  def invite_member(%Scope{} = scope, email, role, url_fun \\ nil) do
    normalized = Invitation.normalize_email(email)

    with :ok <- authorize(scope, :manage_organization),
         :ok <- authorize_role_assignment(scope, role),
         :ok <- ensure_not_a_member(scope, normalized) do
      {token, changeset} =
        Invitation.build(scope.organization, scope.user, %{email: normalized, role: role})

      Multi.new()
      |> Multi.delete_all(:previous, pending_for(scope.organization.id, normalized))
      |> Multi.insert(:invitation, changeset)
      |> Repo.transaction()
      |> case do
        {:ok, %{invitation: invitation}} ->
          deliver(invitation, token, url_fun)
          {:ok, invitation, token}

        {:error, :invitation, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  # No url_fun means nobody asked for an email — which is how the context tests
  # exercise the rest without a mailbox.
  defp deliver(_invitation, _token, nil), do: :ok

  defp deliver(invitation, token, url_fun) do
    invitation
    |> Repo.preload([:organization, :invited_by])
    |> InvitationNotifier.deliver_invitation(url_fun.(token))
  end

  @doc """
  Invitations for the scoped organization that have not been accepted, newest
  first.
  """
  @spec list_pending_invitations(Scope.t()) :: [Invitation.t()]
  def list_pending_invitations(%Scope{} = scope) do
    Repo.all(
      from i in Invitation,
        where: i.organization_id == ^scope.organization.id and is_nil(i.accepted_at),
        order_by: [desc: i.inserted_at],
        preload: [:invited_by]
    )
  end

  @doc """
  Withdraws an invitation, which makes its link stop working.
  """
  @spec revoke_invitation(Scope.t(), integer()) ::
          {:ok, Invitation.t()} | {:error, :not_found | :unauthorized}
  def revoke_invitation(%Scope{} = scope, id) do
    with :ok <- authorize(scope, :manage_organization) do
      case Repo.get_by(Invitation, id: id, organization_id: scope.organization.id) do
        nil -> {:error, :not_found}
        invitation -> Repo.delete(invitation)
      end
    end
  end

  @doc """
  The invitation a token redeems, if it is still good.

  An expired, accepted, withdrawn or unknown token are one answer: the page that
  shows this cannot say which, or it would report whether an address had ever
  been invited.
  """
  @spec fetch_invitation(String.t()) :: {:ok, Invitation.t()} | {:error, :invalid_invitation}
  def fetch_invitation(token) when is_binary(token) do
    hashed = Invitation.hash(token)

    case Repo.one(
           from i in Invitation,
             where: i.hashed_token == ^hashed,
             preload: [:organization, :invited_by]
         ) do
      nil ->
        {:error, :invalid_invitation}

      invitation ->
        if Invitation.pending?(invitation),
          do: {:ok, invitation},
          else: {:error, :invalid_invitation}
    end
  end

  def fetch_invitation(_other), do: {:error, :invalid_invitation}

  @doc """
  Redeems an invitation: registers the person if this is their first time here,
  adds the membership, and marks the invitation used.

  Returns `{:ok, user, membership}`. The caller signs the user in — holding the
  link proved control of the mailbox, which is exactly the proof the magic-link
  login accepts, so an invitation is a login that also grants a membership.

  Single use: the whole thing runs in one transaction and the invitation is
  stamped inside it, so two clicks cannot produce two memberships.
  """
  @spec accept_invitation(String.t()) ::
          {:ok, User.t(), Membership.t()} | {:error, :invalid_invitation} | {:error, term()}
  def accept_invitation(token) do
    with {:ok, invitation} <- fetch_invitation(token) do
      Multi.new()
      |> Multi.run(:user, fn _repo, _changes -> find_or_register(invitation.email) end)
      |> Multi.insert(:membership, fn %{user: user} ->
        Membership.changeset(%Membership{}, %{
          organization_id: invitation.organization_id,
          user_id: user.id,
          role: invitation.role
        })
      end)
      |> Multi.update(
        :invitation,
        Ecto.Changeset.change(invitation, accepted_at: DateTime.utc_now(:second))
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{user: user, membership: membership}} ->
          {:ok, user, Repo.preload(membership, :organization)}

        # Already a member — the person was added by hand between the invitation
        # being sent and being opened. Nothing is wrong with that, so the
        # invitation is spent and they are let in.
        {:error, :membership, _changeset, %{user: user}} ->
          spend(invitation)

          membership =
            Membership
            |> Repo.get_by(organization_id: invitation.organization_id, user_id: user.id)
            |> Repo.preload(:organization)

          {:ok, user, membership}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  defp find_or_register(email) do
    case Repo.get_by(User, email: email) do
      %User{} = user -> {:ok, confirm(user)}
      nil -> register_invited_user(email)
    end
  end

  # A new account, confirmed on the spot: they proved they hold the mailbox by
  # opening the link, which is the same proof registration asks for. They get a
  # personal organization too, like anybody who signs up unaided.
  defp register_invited_user(email) do
    case PulseOps.Accounts.register_user(%{email: email}) do
      {:ok, user} -> {:ok, confirm(user)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp confirm(%User{confirmed_at: nil} = user), do: Repo.update!(User.confirm_changeset(user))
  defp confirm(%User{} = user), do: user

  defp spend(invitation) do
    invitation
    |> Ecto.Changeset.change(accepted_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp pending_for(organization_id, email) do
    from i in Invitation,
      where: i.organization_id == ^organization_id and i.email == ^email and is_nil(i.accepted_at)
  end

  defp ensure_not_a_member(%Scope{} = scope, email) do
    already =
      Repo.exists?(
        from m in Membership,
          join: u in User,
          on: u.id == m.user_id,
          where: m.organization_id == ^scope.organization.id and u.email == ^email
      )

    if already, do: {:error, :already_a_member}, else: :ok
  end

  defp authorize_role_assignment(%Scope{role: :owner}, _role), do: :ok
  defp authorize_role_assignment(_scope, :owner), do: {:error, :owner_required}
  defp authorize_role_assignment(_scope, _role), do: :ok

  defp authorize_target(%Scope{role: :owner}, _membership), do: :ok
  defp authorize_target(_scope, %Membership{role: :owner}), do: {:error, :owner_required}
  defp authorize_target(_scope, _membership), do: :ok

  defp ensure_same_organization(%Scope{} = scope, %Membership{} = membership) do
    if membership.organization_id == scope.organization.id do
      :ok
    else
      {:error, :not_found}
    end
  end
end
