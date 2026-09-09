defmodule PulseOpsWeb.InvitationLiveTest do
  use PulseOpsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PulseOps.AccountsFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Organizations
  alias PulseOps.Organizations.Invitation
  alias PulseOps.Repo

  setup do
    scope = organization_scope_fixture()
    {:ok, invitation, token} = Organizations.invite_member(scope, "newcomer@example.com", :member)
    %{scope: scope, invitation: invitation, token: token}
  end

  # Backdates an invitation and returns a token that would have matched it, so
  # the page can be asked about an expired one.
  defp expire_and_reissue(invitation) do
    token = "expired-token-for-#{invitation.id}"

    invitation
    |> Ecto.Changeset.change(
      hashed_token: Invitation.hash(token),
      expires_at: DateTime.add(DateTime.utc_now(:second), -1, :day)
    )
    |> Repo.update!()

    token
  end

  describe "the invitation page" do
    test "tells a stranger who invited them and to what", %{
      conn: conn,
      scope: scope,
      token: token
    } do
      # No session of any kind: the person may have no account here at all.
      {:ok, _live, html} = live(conn, ~p"/invitations/#{token}")

      assert html =~ scope.organization.name
      assert html =~ "newcomer@example.com"
      assert html =~ scope.user.email
      assert html =~ "Accept invitation"
    end

    test "an unknown and an expired token get the same answer", %{
      conn: conn,
      invitation: invitation
    } do
      {:ok, _live, unknown} = live(conn, ~p"/invitations/never-issued")

      expired_token = expire_and_reissue(invitation)
      {:ok, _live, expired} = live(conn, ~p"/invitations/#{expired_token}")

      assert unknown =~ "cannot be used"
      # Identical copy either way: a page that said "expired" for one and
      # "no such invitation" for the other would report whether an address had
      # ever been invited.
      assert expired =~ "cannot be used"
      refute expired =~ "Accept invitation"
      refute unknown =~ "Accept invitation"
    end

    test "an accepted invitation stops showing the offer", %{conn: conn, token: token} do
      {:ok, _user, _membership} = Organizations.accept_invitation(token)

      {:ok, _live, html} = live(conn, ~p"/invitations/#{token}")

      assert html =~ "cannot be used"
      refute html =~ "Accept invitation"
    end
  end

  describe "accepting" do
    test "a GET does not accept anything", %{conn: conn, scope: scope, token: token} do
      # Mail scanners and link prefetchers follow links. If merely fetching the
      # page joined the organization, people would be joining organizations
      # whose email they never opened.
      {:ok, _live, _html} = live(conn, ~p"/invitations/#{token}")

      assert Organizations.list_pending_invitations(scope) != []
      assert length(Organizations.list_members(scope)) == 1
    end

    test "the post creates the account, adds them, and signs them in", %{
      conn: conn,
      scope: scope,
      token: token
    } do
      conn = post(conn, ~p"/invitations/#{token}/accept")

      assert redirected_to(conn) == ~p"/orgs/#{scope.organization.slug}"
      assert get_session(conn, :user_token)

      emails = Enum.map(Organizations.list_members(scope), & &1.user.email)
      assert "newcomer@example.com" in emails
      assert Organizations.list_pending_invitations(scope) == []
    end

    test "an existing account is added rather than duplicated", %{conn: conn, scope: scope} do
      existing = user_fixture()

      {:ok, _invitation, token} =
        Organizations.invite_member(scope, existing.email, :admin)

      conn = post(conn, ~p"/invitations/#{token}/accept")

      assert redirected_to(conn) == ~p"/orgs/#{scope.organization.slug}"

      membership = Organizations.get_membership(scope.organization, existing)
      assert membership.role == :admin
    end

    test "the link works once", %{conn: conn, token: token} do
      conn |> post(~p"/invitations/#{token}/accept")

      second = build_conn() |> post(~p"/invitations/#{token}/accept")

      assert redirected_to(second) == ~p"/"
      assert Phoenix.Flash.get(second.assigns.flash, :error) =~ "cannot be used"
    end

    test "an unknown token is refused", %{conn: conn} do
      conn = post(conn, ~p"/invitations/never-issued/accept")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "cannot be used"
    end
  end
end
