defmodule PulseOps.OrganizationsMembersTest do
  use PulseOps.DataCase, async: true

  import PulseOps.AccountsFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Organizations
  alias PulseOps.Organizations.Membership

  setup do
    owner = user_fixture()
    organization = organization_fixture(owner, %{name: "Acme", slug: "acme"})
    scope = organization_scope(owner, organization, :owner)

    %{owner: owner, organization: organization, scope: scope}
  end

  describe "list_members/1" do
    test "lists the organization's members, owners first", %{
      scope: scope,
      organization: organization,
      owner: owner
    } do
      viewer = user_fixture()
      admin = user_fixture()
      membership_fixture(organization, viewer, :viewer)
      membership_fixture(organization, admin, :admin)

      roles = Enum.map(Organizations.list_members(scope), & &1.role)
      emails = Enum.map(Organizations.list_members(scope), & &1.user.email)

      assert roles == [:owner, :admin, :viewer]
      assert owner.email in emails
      # The association is preloaded: the page shows email addresses.
      assert Enum.all?(Organizations.list_members(scope), &(&1.user != nil))
    end

    test "does not leak another organization's members", %{scope: scope} do
      other_scope = organization_scope_fixture()

      emails = Enum.map(Organizations.list_members(scope), & &1.user.email)
      refute other_scope.user.email in emails
    end
  end

  describe "get_member!/2" do
    test "raises for a membership in another organization", %{scope: scope} do
      other_scope = organization_scope_fixture()
      [membership] = Organizations.list_members(other_scope)

      assert_raise Ecto.NoResultsError, fn -> Organizations.get_member!(scope, membership.id) end
    end
  end

  describe "add_member/3" do
    test "adds an existing account", %{scope: scope} do
      newcomer = user_fixture()

      assert {:ok, membership} = Organizations.add_member(scope, newcomer.email, :member)
      assert membership.user_id == newcomer.id
      assert membership.role == :member
      assert membership.user.email == newcomer.email
    end

    test "ignores surrounding whitespace and case", %{scope: scope} do
      newcomer = user_fixture()

      assert {:ok, _membership} =
               Organizations.add_member(scope, "  #{String.upcase(newcomer.email)} ", :viewer)
    end

    test "reports an unregistered address rather than inventing an account", %{scope: scope} do
      assert Organizations.add_member(scope, "stranger@example.com", :member) ==
               {:error, :not_found}
    end

    test "refuses to add the same person twice", %{scope: scope} do
      newcomer = user_fixture()
      {:ok, _membership} = Organizations.add_member(scope, newcomer.email, :member)

      assert {:error, %Ecto.Changeset{}} =
               Organizations.add_member(scope, newcomer.email, :viewer)
    end

    test "an admin may add ordinary members", %{organization: organization} do
      admin = user_fixture()
      membership_fixture(organization, admin, :admin)
      admin_scope = organization_scope(admin, organization, :admin)
      newcomer = user_fixture()

      assert {:ok, _membership} = Organizations.add_member(admin_scope, newcomer.email, :member)
    end

    test "an admin may not create another owner", %{organization: organization} do
      admin = user_fixture()
      membership_fixture(organization, admin, :admin)
      admin_scope = organization_scope(admin, organization, :admin)
      newcomer = user_fixture()

      assert Organizations.add_member(admin_scope, newcomer.email, :owner) ==
               {:error, :owner_required}
    end

    test "a member or viewer may not add anybody", %{organization: organization} do
      for role <- [:member, :viewer] do
        person = user_fixture()
        membership_fixture(organization, person, role)
        scope = organization_scope(person, organization, role)

        assert Organizations.add_member(scope, user_fixture().email, :viewer) ==
                 {:error, :unauthorized}
      end
    end
  end

  describe "update_member_role/3" do
    test "changes the role", %{scope: scope, organization: organization} do
      person = user_fixture()
      membership = membership_fixture(organization, person, :viewer)

      assert {:ok, updated} = Organizations.update_member_role(scope, membership, :admin)
      assert updated.role == :admin
    end

    test "refuses to demote the only owner", %{
      scope: scope,
      organization: organization,
      owner: owner
    } do
      membership = Organizations.get_membership(organization, owner)

      # Demoting the last owner would leave the organization with nobody able to
      # administer it, including the person doing the demoting.
      assert Organizations.update_member_role(scope, membership, :admin) == {:error, :last_owner}
      assert Organizations.owner_count(organization.id) == 1
    end

    test "allows demoting an owner once there is a second one", %{
      scope: scope,
      organization: organization,
      owner: owner
    } do
      second = user_fixture()
      membership_fixture(organization, second, :owner)
      membership = Organizations.get_membership(organization, owner)

      assert {:ok, updated} = Organizations.update_member_role(scope, membership, :admin)
      assert updated.role == :admin
    end

    test "an admin may not change an owner's role", %{organization: organization, owner: owner} do
      admin = user_fixture()
      membership_fixture(organization, admin, :admin)
      admin_scope = organization_scope(admin, organization, :admin)
      owner_membership = Organizations.get_membership(organization, owner)

      assert Organizations.update_member_role(admin_scope, owner_membership, :member) ==
               {:error, :owner_required}
    end

    test "an admin may not promote anybody to owner", %{organization: organization} do
      admin = user_fixture()
      membership_fixture(organization, admin, :admin)
      admin_scope = organization_scope(admin, organization, :admin)

      person = user_fixture()
      membership = membership_fixture(organization, person, :member)

      assert Organizations.update_member_role(admin_scope, membership, :owner) ==
               {:error, :owner_required}
    end

    test "refuses a membership from another organization", %{scope: scope} do
      other_scope = organization_scope_fixture()
      [membership] = Organizations.list_members(other_scope)

      assert Organizations.update_member_role(scope, membership, :viewer) == {:error, :not_found}
    end

    test "a viewer may not change roles", %{organization: organization} do
      viewer = user_fixture()
      membership = membership_fixture(organization, viewer, :viewer)
      viewer_scope = organization_scope(viewer, organization, :viewer)

      assert Organizations.update_member_role(viewer_scope, membership, :owner) ==
               {:error, :unauthorized}
    end
  end

  describe "remove_member/2" do
    test "removes a member", %{scope: scope, organization: organization} do
      person = user_fixture()
      membership = membership_fixture(organization, person, :member)

      assert {:ok, _membership} = Organizations.remove_member(scope, membership)
      refute Organizations.get_membership(organization, person)
    end

    test "refuses to remove the only owner", %{
      scope: scope,
      organization: organization,
      owner: owner
    } do
      membership = Organizations.get_membership(organization, owner)

      assert Organizations.remove_member(scope, membership) == {:error, :last_owner}
      assert Organizations.get_membership(organization, owner)
    end

    test "an admin may not remove an owner", %{organization: organization, owner: owner} do
      admin = user_fixture()
      membership_fixture(organization, admin, :admin)
      admin_scope = organization_scope(admin, organization, :admin)
      owner_membership = Organizations.get_membership(organization, owner)

      assert Organizations.remove_member(admin_scope, owner_membership) ==
               {:error, :owner_required}
    end

    test "a member may not remove anybody", %{organization: organization} do
      person = user_fixture()
      membership = membership_fixture(organization, person, :member)
      person_scope = organization_scope(person, organization, :member)

      assert Organizations.remove_member(person_scope, membership) == {:error, :unauthorized}
    end
  end

  describe "update_organization/3" do
    test "renames the organization", %{scope: scope, organization: organization} do
      assert {:ok, updated} =
               Organizations.update_organization(scope, organization, %{name: "Renamed"})

      assert updated.name == "Renamed"
      # The slug is not derived again on update: existing links keep working
      # unless the slug is changed on purpose.
      assert updated.slug == "acme"
    end

    test "changes the slug when asked", %{scope: scope, organization: organization} do
      assert {:ok, updated} =
               Organizations.update_organization(scope, organization, %{slug: "acme-corp"})

      assert updated.slug == "acme-corp"
    end

    test "rejects a slug already taken", %{scope: scope, organization: organization} do
      other = organization_fixture(user_fixture(), %{name: "Taken", slug: "taken"})

      assert {:error, changeset} =
               Organizations.update_organization(scope, organization, %{slug: other.slug})

      assert errors_on(changeset)[:slug]
    end

    test "a viewer may not change organization settings", %{organization: organization} do
      viewer = user_fixture()
      membership_fixture(organization, viewer, :viewer)
      viewer_scope = organization_scope(viewer, organization, :viewer)

      assert Organizations.update_organization(viewer_scope, organization, %{name: "Nope"}) ==
               {:error, :unauthorized}
    end
  end

  describe "owner_count/1" do
    test "counts only owners", %{organization: organization} do
      membership_fixture(organization, user_fixture(), :admin)
      assert Organizations.owner_count(organization.id) == 1

      membership_fixture(organization, user_fixture(), :owner)
      assert Organizations.owner_count(organization.id) == 2
    end
  end

  describe "roles/0" do
    test "are ordered from most to least privileged" do
      assert Membership.roles() == [:owner, :admin, :member, :viewer]
    end
  end
end
