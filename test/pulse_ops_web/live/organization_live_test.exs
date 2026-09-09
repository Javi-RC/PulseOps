defmodule PulseOpsWeb.OrganizationLiveTest do
  use PulseOpsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PulseOps.AccountsFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Organizations
  alias PulseOps.Organizations.Membership
  alias PulseOps.Repo

  setup :register_and_log_in_user_with_org

  describe "creating an organization" do
    test "creates one and lands in it", %{conn: conn, user: user} do
      {:ok, live, _html} = live(conn, ~p"/orgs/new")

      assert {:ok, _live, html} =
               live
               |> form("form", organization: %{name: "Acme Corp"})
               |> render_submit()
               |> follow_redirect(conn, ~p"/orgs/acme-corp")

      assert html =~ "Acme Corp"
      assert Enum.any?(Organizations.list_organizations_for_user(user), &(&1.slug == "acme-corp"))
    end

    test "makes the creator its owner", %{conn: conn, user: user} do
      {:ok, live, _html} = live(conn, ~p"/orgs/new")

      live |> form("form", organization: %{name: "Acme Corp"}) |> render_submit()

      organization = Organizations.get_organization_by_slug("acme-corp")
      assert Organizations.get_membership(organization, user).role == :owner
    end

    test "reports a slug already in use", %{conn: conn} do
      organization_fixture(user_fixture(), %{name: "Taken", slug: "taken"})

      {:ok, live, _html} = live(conn, ~p"/orgs/new")

      html =
        live
        |> form("form", organization: %{name: "Anything", slug: "taken"})
        |> render_submit()

      assert html =~ "has already been taken"
    end
  end

  describe "publishing the status page" do
    test "the toggle publishes it and offers the link", %{conn: conn, scope: scope} do
      {:ok, live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}/settings")
      refute html =~ "View the page"

      html =
        live
        |> form("#status-page-form",
          organization: %{status_page_enabled: "true", status_page_headline: "We watch things"}
        )
        |> render_submit()

      assert html =~ "Status page published"
      assert html =~ "View the page"

      organization = Repo.reload!(scope.organization)
      assert organization.status_page_enabled
      assert organization.status_page_headline == "We watch things"
    end

    test "turning it off takes it down", %{conn: conn, scope: scope} do
      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/settings")

      live
      |> form("#status-page-form", organization: %{status_page_enabled: "true"})
      |> render_submit()

      html =
        live
        |> form("#status-page-form", organization: %{status_page_enabled: "false"})
        |> render_submit()

      assert html =~ "Status page taken down"
      refute Repo.reload!(scope.organization).status_page_enabled
    end

    test "the toggle cannot be used to rename the organization", %{conn: conn, scope: scope} do
      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/settings")

      # A crafted submit carrying fields this control has no business changing.
      live
      |> render_submit("save_status_page", %{
        "organization" => %{
          "status_page_enabled" => "true",
          "name" => "Hijacked",
          "slug" => "hijacked"
        }
      })

      organization = Repo.reload!(scope.organization)
      assert organization.status_page_enabled
      refute organization.name == "Hijacked"
      refute organization.slug == "hijacked"
    end

    test "a viewer cannot publish it", %{conn: conn, scope: scope, user: user} do
      # Demoted before mounting, because the scope is built at mount: a role
      # change mid-session does not reach a socket that is already open.
      demote_to_viewer(scope, user)

      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/settings")

      html =
        live
        |> form("#status-page-form", organization: %{status_page_enabled: "true"})
        |> render_submit()

      assert html =~ "do not have permission"
      refute Repo.reload!(scope.organization).status_page_enabled
    end
  end

  describe "organization settings" do
    test "renames the organization", %{conn: conn, scope: scope} do
      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/settings")

      live
      |> form("#organization-form",
        organization: %{name: "Renamed", slug: scope.organization.slug}
      )
      |> render_submit()

      assert Repo.reload!(scope.organization).name == "Renamed"
    end

    test "warns that changing the URL breaks existing links", %{conn: conn, scope: scope} do
      {:ok, _live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}/settings")

      assert html =~ "Existing links and"
    end

    test "is not reachable by somebody who cannot manage the organization", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      demote_to_viewer(scope, user)

      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/settings")

      html =
        live
        |> form("#organization-form",
          organization: %{name: "Nope", slug: scope.organization.slug}
        )
        |> render_submit()

      assert html =~ "do not have permission"
      refute Repo.reload!(scope.organization).name == "Nope"
    end
  end

  describe "members" do
    test "lists the people in the organization", %{conn: conn, scope: scope, user: user} do
      colleague = user_fixture()
      membership_fixture(scope.organization, colleague, :member)

      {:ok, _live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}/members")

      assert html =~ user.email
      assert html =~ colleague.email
    end

    test "documents what each role can do", %{conn: conn, scope: scope} do
      {:ok, _live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}/members")

      assert html =~ "What each role can do"
      assert html =~ "Manage services"
      assert html =~ "Respond to incidents"
    end

    test "adds an existing account", %{conn: conn, scope: scope} do
      colleague = user_fixture()

      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/members")

      html =
        live
        |> form("form[phx-submit=add]", member: %{email: colleague.email, role: "member"})
        |> render_submit()

      assert html =~ colleague.email
      assert Organizations.get_membership(scope.organization, colleague).role == :member
    end

    test "says so when the address has no account", %{conn: conn, scope: scope} do
      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/members")

      html =
        live
        |> form("form[phx-submit=add]", member: %{email: "nobody@example.com", role: "member"})
        |> render_submit()

      assert html =~ "No account is registered with that email address"
    end

    test "changes a role", %{conn: conn, scope: scope} do
      colleague = user_fixture()
      membership = membership_fixture(scope.organization, colleague, :viewer)

      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/members")

      live
      |> element(~s{#member-#{membership.id} form[phx-change=set_role]})
      |> render_change(%{"member_id" => membership.id, "role" => "admin"})

      assert Repo.reload!(membership).role == :admin
    end

    test "removes somebody", %{conn: conn, scope: scope} do
      colleague = user_fixture()
      membership = membership_fixture(scope.organization, colleague, :member)

      {:ok, live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/members")

      live |> element(~s{button[phx-value-id="#{membership.id}"]}) |> render_click()

      refute Organizations.get_membership(scope.organization, colleague)
    end

    test "will not let the only owner remove themselves", %{conn: conn, scope: scope, user: user} do
      membership = Organizations.get_membership(scope.organization, user)

      {:ok, _live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}/members")

      # The control is disabled rather than failing after the fact.
      assert html =~ ~s(id="member-#{membership.id}")
      assert Organizations.owner_count(scope.organization.id) == 1
    end

    test "a viewer sees the roster but gets no controls", %{conn: conn, scope: scope, user: user} do
      colleague = user_fixture()
      membership_fixture(scope.organization, colleague, :member)
      demote_to_viewer(scope, user)

      {:ok, _live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}/members")

      assert html =~ colleague.email
      refute html =~ "Add member"
      refute html =~ "phx-click=\"remove\""
    end

    test "does not show another organization's members", %{conn: conn, scope: scope} do
      other_scope = organization_scope_fixture()

      {:ok, _live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}/members")

      refute html =~ other_scope.user.email
    end
  end

  defp demote_to_viewer(scope, user) do
    Repo.get_by!(Membership, organization_id: scope.organization.id, user_id: user.id)
    |> Ecto.Changeset.change(role: :viewer)
    |> Repo.update!()
  end
end
