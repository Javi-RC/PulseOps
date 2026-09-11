defmodule PulseOps.OrganizationsInvitationsTest do
  use PulseOps.DataCase, async: true

  import PulseOps.AccountsFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Organizations
  alias PulseOps.Organizations.Invitation
  alias PulseOps.Organizations.Membership

  setup do
    %{scope: organization_scope_fixture()}
  end

  defp invite(scope, email \\ "newcomer@example.com", role \\ :member) do
    {:ok, invitation, token} = Organizations.invite_member(scope, email, role)
    {invitation, token}
  end

  defp expire(invitation) do
    invitation
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -1, :day))
    |> Repo.update!()
  end

  describe "invite_member/3" do
    test "invites somebody who has no account here", %{scope: scope} do
      {invitation, token} = invite(scope)

      assert invitation.email == "newcomer@example.com"
      assert invitation.role == :member
      assert invitation.invited_by_id == scope.user.id
      # Only the hash is kept; the token lives in the email.
      assert invitation.hashed_token == Invitation.hash(token)
    end

    test "normalizes the address, so case cannot duplicate an invitation", %{scope: scope} do
      {invitation, _token} = invite(scope, "  NewComer@Example.COM  ")

      assert invitation.email == "newcomer@example.com"
    end

    test "re-inviting replaces the pending link rather than leaving two", %{scope: scope} do
      {_first, first_token} = invite(scope)
      {_second, second_token} = invite(scope)

      assert Organizations.fetch_invitation(first_token) == {:error, :invalid_invitation}
      assert {:ok, _invitation} = Organizations.fetch_invitation(second_token)
      assert length(Organizations.list_pending_invitations(scope)) == 1
    end

    test "refuses somebody who is already a member", %{scope: scope} do
      assert Organizations.invite_member(scope, scope.user.email, :member) ==
               {:error, :already_a_member}
    end

    test "rejects an address that is not one", %{scope: scope} do
      assert {:error, changeset} = Organizations.invite_member(scope, "not-an-address", :member)
      assert errors_on(changeset).email != []
    end

    test "an admin cannot invite an owner", %{scope: scope} do
      admin = %{scope | role: :admin}

      assert Organizations.invite_member(admin, "newcomer@example.com", :owner) ==
               {:error, :owner_required}

      assert {:ok, _invitation, _token} =
               Organizations.invite_member(admin, "newcomer@example.com", :admin)
    end

    test "a member cannot invite at all", %{scope: scope} do
      assert Organizations.invite_member(%{scope | role: :member}, "a@example.com", :viewer) ==
               {:error, :unauthorized}
    end
  end

  describe "fetch_invitation/1" do
    test "finds a pending one", %{scope: scope} do
      {invitation, token} = invite(scope)

      assert {:ok, found} = Organizations.fetch_invitation(token)
      assert found.id == invitation.id
      assert found.organization.id == scope.organization.id
    end

    test "an expired, unknown or withdrawn token are one answer", %{scope: scope} do
      {invitation, token} = invite(scope)

      # Telling them apart would report whether an address had ever been invited.
      assert Organizations.fetch_invitation("nonsense") == {:error, :invalid_invitation}
      assert Organizations.fetch_invitation(nil) == {:error, :invalid_invitation}

      expire(invitation)
      assert Organizations.fetch_invitation(token) == {:error, :invalid_invitation}
    end

    test "a withdrawn invitation stops working", %{scope: scope} do
      {invitation, token} = invite(scope)

      {:ok, _deleted} = Organizations.revoke_invitation(scope, invitation.id)

      assert Organizations.fetch_invitation(token) == {:error, :invalid_invitation}
    end
  end

  describe "accept_invitation/1" do
    test "registers somebody who has never been here and adds them", %{scope: scope} do
      {_invitation, token} = invite(scope, "newcomer@example.com", :member)

      assert {:ok, user, membership} = Organizations.accept_invitation(token)

      assert user.email == "newcomer@example.com"
      # Opening the link proved they hold the mailbox, which is the same proof
      # registration asks for.
      assert user.confirmed_at
      assert membership.organization_id == scope.organization.id
      assert membership.role == :member
    end

    test "adds an existing account without making a second one", %{scope: scope} do
      existing = user_fixture()
      {_invitation, token} = invite(scope, existing.email, :admin)

      assert {:ok, user, membership} = Organizations.accept_invitation(token)

      assert user.id == existing.id
      assert membership.role == :admin
    end

    test "is single use", %{scope: scope} do
      {_invitation, token} = invite(scope)

      assert {:ok, _user, _membership} = Organizations.accept_invitation(token)
      assert Organizations.accept_invitation(token) == {:error, :invalid_invitation}
    end

    test "an expired invitation cannot be redeemed", %{scope: scope} do
      {invitation, token} = invite(scope)
      expire(invitation)

      assert Organizations.accept_invitation(token) == {:error, :invalid_invitation}

      # Nobody was added, and no account was created for the invited address.
      refute Repo.exists?(from u in PulseOps.Accounts.User, where: u.email == ^invitation.email)
    end

    test "someone added by hand in the meantime is simply let in", %{scope: scope} do
      existing = user_fixture()
      {_invitation, token} = invite(scope, existing.email, :member)

      # The invitation was sent, then somebody added them through the members
      # page before it was opened. That is not an error.
      {:ok, _membership} = Organizations.add_member(scope, existing.email, :viewer)

      assert {:ok, user, membership} = Organizations.accept_invitation(token)
      assert user.id == existing.id
      # The membership they already had, not a second one.
      assert membership.role == :viewer

      assert Repo.aggregate(
               from(m in Membership,
                 where: m.organization_id == ^scope.organization.id and m.user_id == ^user.id
               ),
               :count
             ) == 1

      assert Organizations.accept_invitation(token) == {:error, :invalid_invitation}
    end

    test "a new user gets their own personal organization too", %{scope: scope} do
      {_invitation, token} = invite(scope, "newcomer@example.com")

      {:ok, user, _membership} = Organizations.accept_invitation(token)

      # Two: the personal one registration creates, and the one they were
      # invited to.
      assert length(Organizations.list_organizations_for_user(user)) == 2
    end
  end

  describe "list_pending_invitations/1 and revoke_invitation/2" do
    test "lists only this organization's, and only pending ones", %{scope: scope} do
      {_invitation, token} = invite(scope, "one@example.com")
      invite(scope, "two@example.com")

      other = organization_scope_fixture()
      Organizations.invite_member(other, "three@example.com", :member)

      assert length(Organizations.list_pending_invitations(scope)) == 2

      {:ok, _user, _membership} = Organizations.accept_invitation(token)

      assert Enum.map(Organizations.list_pending_invitations(scope), & &1.email) ==
               ["two@example.com"]
    end

    test "cannot withdraw another organization's invitation", %{scope: scope} do
      other = organization_scope_fixture()
      {:ok, theirs, _token} = Organizations.invite_member(other, "a@example.com", :member)

      assert Organizations.revoke_invitation(scope, theirs.id) == {:error, :not_found}
    end

    test "a member cannot withdraw one", %{scope: scope} do
      {invitation, _token} = invite(scope)

      assert Organizations.revoke_invitation(%{scope | role: :member}, invitation.id) ==
               {:error, :unauthorized}
    end
  end
end
