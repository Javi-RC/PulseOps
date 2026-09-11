defmodule PulseOpsWeb.ApiTokenLiveTest do
  use PulseOpsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PulseOps.Api
  alias PulseOps.Api.Token
  alias PulseOps.Organizations.Membership
  alias PulseOps.Repo

  setup :register_and_log_in_user_with_org

  defp tokens_path(scope), do: ~p"/orgs/#{scope.organization.slug}/settings/api-tokens"

  defp demote(scope, user, role) do
    Repo.get_by!(Membership, organization_id: scope.organization.id, user_id: user.id)
    |> Ecto.Changeset.change(role: role)
    |> Repo.update!()
  end

  test "invites the user to make one when there are none", %{conn: conn, scope: scope} do
    {:ok, _live, html} = live(conn, tokens_path(scope))

    assert html =~ "No tokens yet"
  end

  test "tells a viewer with no tokens who can make one", %{conn: conn, scope: scope, user: user} do
    demote(scope, user, :viewer)

    {:ok, live, _html} = live(conn, tokens_path(scope))

    assert has_element?(live, "#api-tokens-empty", "An owner or admin")
  end

  test "creating one shows it exactly once", %{conn: conn, scope: scope} do
    {:ok, live, _html} = live(conn, tokens_path(scope))

    html =
      live |> form("#api-token-form", token: %{name: "CI pipeline"}) |> render_submit()

    assert html =~ "CI pipeline is ready"
    assert [plaintext] = Regex.run(~r/#{Token.scheme()}_[A-Za-z0-9_-]+/, html)

    # Dismissing it is the end of it: the page cannot show it again, because
    # only the hash was kept.
    html = live |> element("button", "Done") |> render_click()
    refute html =~ plaintext

    assert html =~ "CI pipeline"
    refute render(live) =~ plaintext
  end

  test "the token it showed actually works", %{conn: conn, scope: scope} do
    {:ok, live, _html} = live(conn, tokens_path(scope))

    html = live |> form("#api-token-form", token: %{name: "CI"}) |> render_submit()
    [plaintext] = Regex.run(~r/#{Token.scheme()}_[A-Za-z0-9_-]+/, html)

    assert {:ok, api_scope} = Api.scope_for_token(plaintext)
    assert api_scope.organization.id == scope.organization.id
  end

  test "reports a duplicate name instead of minting a second token", %{
    conn: conn,
    scope: scope
  } do
    {:ok, _plaintext, _token} = Api.create_token(scope, %{name: "CI"})

    {:ok, live, _html} = live(conn, tokens_path(scope))

    html = live |> form("#api-token-form", token: %{name: "CI"}) |> render_submit()

    assert html =~ "already used by another token"
    assert length(Api.list_tokens(scope)) == 1
  end

  test "revoking marks it and stops it working", %{conn: conn, scope: scope} do
    {:ok, plaintext, token} = Api.create_token(scope, %{name: "Doomed"})

    {:ok, live, html} = live(conn, tokens_path(scope))
    refute html =~ "Revoked"

    html = live |> element(~s(button[phx-value-id="#{token.id}"])) |> render_click()

    assert html =~ "Doomed revoked"
    assert html =~ "Revoked"
    assert Api.scope_for_token(plaintext) == {:error, :invalid_token}
  end

  test "shows a prefix but never a whole token", %{conn: conn, scope: scope} do
    {:ok, plaintext, token} = Api.create_token(scope, %{name: "CI"})

    {:ok, _live, html} = live(conn, tokens_path(scope))

    assert html =~ token.prefix
    refute html =~ plaintext
  end

  test "a viewer sees the tokens but cannot mint or revoke one", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    {:ok, _plaintext, token} = Api.create_token(scope, %{name: "CI"})
    demote(scope, user, :viewer)

    {:ok, _live, html} = live(conn, tokens_path(scope))

    assert html =~ "CI"
    refute html =~ "api-token-form"
    refute html =~ "phx-value-id=\"#{token.id}\""
  end
end
