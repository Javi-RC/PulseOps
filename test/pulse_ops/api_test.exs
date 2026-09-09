defmodule PulseOps.ApiTest do
  use PulseOps.DataCase, async: true

  import PulseOps.OrganizationsFixtures

  alias PulseOps.Api
  alias PulseOps.Api.Token
  alias PulseOps.Organizations.Membership

  setup do
    %{scope: organization_scope_fixture()}
  end

  defp create(scope, name \\ "CI") do
    {:ok, plaintext, token} = Api.create_token(scope, %{name: name})
    {plaintext, token}
  end

  defp set_role(scope, role) do
    Repo.get_by!(Membership, organization_id: scope.organization.id, user_id: scope.user.id)
    |> Ecto.Changeset.change(role: role)
    |> Repo.update!()
  end

  describe "create_token/2" do
    test "returns the plaintext once and stores only a hash", %{scope: scope} do
      {plaintext, token} = create(scope)

      assert String.starts_with?(plaintext, Token.scheme() <> "_")
      assert token.hashed_token == Token.hash(plaintext)

      # The row cannot be turned back into the token, only recognised.
      refute String.contains?(Base.encode64(token.hashed_token), plaintext)
      assert String.starts_with?(plaintext, token.prefix)
      assert String.length(token.prefix) < String.length(plaintext)
    end

    test "two tokens are never the same", %{scope: scope} do
      {one, _} = create(scope, "One")
      {two, _} = create(scope, "Two")

      refute one == two
    end

    test "names have to be distinct within an organization", %{scope: scope} do
      create(scope, "CI")

      assert {:error, changeset} = Api.create_token(scope, %{name: "CI"})
      assert errors_on(changeset).name != []
    end

    test "another organization may use the same name", %{scope: scope} do
      create(scope, "CI")
      other = organization_scope_fixture()

      assert {:ok, _plaintext, _token} = Api.create_token(other, %{name: "CI"})
    end

    test "a member cannot mint one", %{scope: scope} do
      assert Api.create_token(%{scope | role: :member}, %{name: "CI"}) == {:error, :unauthorized}
    end
  end

  describe "scope_for_token/1" do
    test "produces a scope narrowed to the organization", %{scope: scope} do
      {plaintext, _token} = create(scope)

      assert {:ok, api_scope} = Api.scope_for_token(plaintext)
      assert api_scope.organization.id == scope.organization.id
      assert api_scope.user.id == scope.user.id
      assert api_scope.role == :owner
    end

    test "rejects an unknown, malformed or absent token" do
      assert Api.scope_for_token("pops_nonsense") == {:error, :invalid_token}
      assert Api.scope_for_token("") == {:error, :invalid_token}
      assert Api.scope_for_token(nil) == {:error, :invalid_token}
    end

    test "rejects a revoked token", %{scope: scope} do
      {plaintext, token} = create(scope)
      assert {:ok, _scope} = Api.scope_for_token(plaintext)

      {:ok, _revoked} = Api.revoke_token(scope, token.id)

      assert Api.scope_for_token(plaintext) == {:error, :invalid_token}
    end

    test "the role follows the owner's membership, not the token", %{scope: scope} do
      {plaintext, _token} = create(scope)

      set_role(scope, :viewer)

      # The token was minted by an owner and is now a viewer's token, because a
      # token borrows an identity rather than having one.
      assert {:ok, api_scope} = Api.scope_for_token(plaintext)
      assert api_scope.role == :viewer
    end

    test "removing the owner from the organization disarms their tokens", %{scope: scope} do
      {plaintext, _token} = create(scope)

      Repo.get_by!(Membership,
        organization_id: scope.organization.id,
        user_id: scope.user.id
      )
      |> Repo.delete!()

      assert Api.scope_for_token(plaintext) == {:error, :invalid_token}
    end

    test "records when a token was last used", %{scope: scope} do
      {plaintext, token} = create(scope)
      assert token.last_used_at == nil

      {:ok, _scope} = Api.scope_for_token(plaintext)

      assert Repo.reload!(token).last_used_at
    end
  end

  describe "list_tokens/1 and revoke_token/2" do
    test "lists only this organization's tokens", %{scope: scope} do
      create(scope, "Mine")
      other = organization_scope_fixture()
      Api.create_token(other, %{name: "Theirs"})

      assert Enum.map(Api.list_tokens(scope), & &1.name) == ["Mine"]
    end

    test "revoking keeps the row, so a leaked token stays identifiable", %{scope: scope} do
      {_plaintext, token} = create(scope)

      assert {:ok, revoked} = Api.revoke_token(scope, token.id)
      assert revoked.revoked_at
      assert Repo.get(Token, token.id)
    end

    test "cannot revoke another organization's token", %{scope: scope} do
      other = organization_scope_fixture()
      {:ok, _plaintext, theirs} = Api.create_token(other, %{name: "Theirs"})

      assert Api.revoke_token(scope, theirs.id) == {:error, :not_found}
      refute Repo.get!(Token, theirs.id).revoked_at
    end

    test "a member cannot revoke", %{scope: scope} do
      {_plaintext, token} = create(scope)

      assert Api.revoke_token(%{scope | role: :member}, token.id) == {:error, :unauthorized}
    end
  end
end
