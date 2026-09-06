defmodule PulseOps.OrganizationsTest do
  use PulseOps.DataCase, async: true

  import PulseOps.AccountsFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Accounts
  alias PulseOps.Accounts.Scope
  alias PulseOps.Organizations
  alias PulseOps.Organizations.Organization

  describe "create_organization/2" do
    test "creates the organization and makes the user its owner" do
      user = user_fixture()

      assert {:ok, %Organization{} = org} =
               Organizations.create_organization(user, %{name: "Acme Corp"})

      assert org.name == "Acme Corp"
      assert org.slug == "acme-corp"

      membership = Organizations.get_membership(org, user)
      assert membership.role == :owner
    end

    test "accepts an explicit slug" do
      user = user_fixture()

      assert {:ok, org} =
               Organizations.create_organization(user, %{name: "Acme Corp", slug: "acme"})

      assert org.slug == "acme"
    end

    test "rejects a duplicate slug" do
      user = user_fixture()
      organization_fixture(user, %{name: "Acme", slug: "acme"})

      assert {:error, changeset} =
               Organizations.create_organization(user, %{name: "Other", slug: "acme"})

      assert "has already been taken" in errors_on(changeset).slug
    end

    test "rejects an invalid slug" do
      user = user_fixture()

      assert {:error, changeset} =
               Organizations.create_organization(user, %{name: "Acme", slug: "Not A Slug"})

      refute changeset.valid?
      assert errors_on(changeset)[:slug]
    end

    test "writes nothing when the organization is invalid" do
      user = user_fixture()
      before = Organizations.list_organizations_for_user(user)

      assert {:error, _changeset} = Organizations.create_organization(user, %{name: "x"})

      # The membership must not survive a rolled-back organization insert.
      assert Organizations.list_organizations_for_user(user) == before
    end
  end

  describe "registration" do
    test "gives every new user a personal organization they own" do
      email = unique_user_email()
      assert {:ok, user} = Accounts.register_user(%{email: email})

      assert [organization] = Organizations.list_organizations_for_user(user)
      assert Organizations.get_membership(organization, user).role == :owner
    end

    test "de-duplicates the slug when two users share an email local part" do
      assert {:ok, first} = Accounts.register_user(%{email: "javier@example.com"})
      assert {:ok, second} = Accounts.register_user(%{email: "javier@other.com"})

      [first_org] = Organizations.list_organizations_for_user(first)
      [second_org] = Organizations.list_organizations_for_user(second)

      assert first_org.slug == "javier"
      refute second_org.slug == first_org.slug
    end
  end

  describe "fetch_for_user/2" do
    test "returns the organization and the caller's role" do
      user = user_fixture()
      org = organization_fixture(user)

      assert {:ok, found, :owner} = Organizations.fetch_for_user(org.slug, user)
      assert found.id == org.id
    end

    test "hides organizations the user does not belong to" do
      owner = user_fixture()
      outsider = user_fixture()
      org = organization_fixture(owner)

      assert Organizations.fetch_for_user(org.slug, outsider) == {:error, :not_found}
    end

    test "reports a missing organization the same way as a forbidden one" do
      user = user_fixture()
      org = organization_fixture(user_fixture())

      # Identical results: the response must not reveal whether the slug exists.
      assert Organizations.fetch_for_user("no-such-org", user) == {:error, :not_found}
      assert Organizations.fetch_for_user(org.slug, user) == {:error, :not_found}
    end

    test "honours the role recorded on the membership" do
      owner = user_fixture()
      viewer = user_fixture()
      org = organization_fixture(owner)
      membership_fixture(org, viewer, :viewer)

      assert {:ok, _org, :viewer} = Organizations.fetch_for_user(org.slug, viewer)
    end
  end

  describe "list_organizations_for_user/1" do
    test "returns only the user's own organizations" do
      user = user_fixture()
      other = user_fixture()

      mine = organization_fixture(user, %{name: "Mine"})
      theirs = organization_fixture(other, %{name: "Theirs"})

      ids = Enum.map(Organizations.list_organizations_for_user(user), & &1.id)

      assert mine.id in ids
      refute theirs.id in ids
    end
  end

  describe "can?/2" do
    test "owners and admins may manage services" do
      for role <- [:owner, :admin] do
        assert Organizations.can?(%Scope{role: role}, :manage_services)
      end
    end

    test "members and viewers may not manage services" do
      for role <- [:member, :viewer] do
        refute Organizations.can?(%Scope{role: role}, :manage_services)
      end
    end

    test "everyone but a viewer may respond to incidents" do
      for role <- [:owner, :admin, :member] do
        assert Organizations.can?(%Scope{role: role}, :respond_to_incidents)
      end

      refute Organizations.can?(%Scope{role: :viewer}, :respond_to_incidents)
    end

    test "a scope with no role can do nothing" do
      refute Organizations.can?(%Scope{role: nil}, :view)
      refute Organizations.can?(%Scope{role: nil}, :manage_services)
    end

    test "an unknown action is denied even for an owner" do
      refute Organizations.can?(%Scope{role: :owner}, :launch_missiles)
    end
  end

  describe "authorize/2" do
    test "returns :ok or {:error, :unauthorized}" do
      assert Organizations.authorize(%Scope{role: :owner}, :manage_services) == :ok

      assert Organizations.authorize(%Scope{role: :viewer}, :manage_services) ==
               {:error, :unauthorized}
    end
  end

  describe "slugify/1" do
    test "produces url-safe slugs" do
      assert Organization.slugify("Acme Corp") == "acme-corp"
      assert Organization.slugify("  Spaced   Out  ") == "spaced-out"
      assert Organization.slugify("Payments/API") == "paymentsapi"
    end
  end
end
