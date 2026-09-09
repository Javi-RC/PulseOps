defmodule PulseOps.Api do
  @moduledoc """
  Organization API tokens: creating them, listing them, revoking them, and
  turning a presented one back into a `%Scope{}`.

  The scope is the whole point. Every context function in this application
  already takes a scope and does its own authorization against it, so a token
  that produces one reuses the entire domain — every tenant filter, every role
  check — without a single rule being restated for the API. The alternative,
  a parallel set of "api_" functions, is how the two halves drift apart and one
  of them ends up missing a check.
  """

  import Ecto.Query, warn: false

  alias PulseOps.Accounts.Scope
  alias PulseOps.Api.Token
  alias PulseOps.Organizations
  alias PulseOps.Organizations.Membership
  alias PulseOps.Repo

  @doc """
  Creates a token for the scoped organization, acting as the scoped user.

  Returns `{:ok, plaintext, token}`. The plaintext is never stored and cannot be
  shown again.
  """
  @spec create_token(Scope.t(), map()) ::
          {:ok, String.t(), Token.t()} | {:error, Ecto.Changeset.t()} | {:error, :unauthorized}
  def create_token(%Scope{} = scope, attrs) do
    with :ok <- Organizations.authorize(scope, :manage_organization) do
      {plaintext, changeset} = Token.build(scope.organization, scope.user, attrs)

      case Repo.insert(changeset) do
        {:ok, token} -> {:ok, plaintext, token}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc """
  Tokens belonging to the scoped organization, newest first.
  """
  @spec list_tokens(Scope.t()) :: [Token.t()]
  def list_tokens(%Scope{} = scope) do
    Repo.all(
      from t in Token,
        where: t.organization_id == ^scope.organization.id,
        order_by: [desc: t.inserted_at],
        preload: [:user]
    )
  end

  @doc """
  Revokes a token. Kept rather than deleted, so a token that turns up in a log
  later can still be identified as one that was already dealt with.
  """
  @spec revoke_token(Scope.t(), integer()) ::
          {:ok, Token.t()} | {:error, :not_found} | {:error, :unauthorized}
  def revoke_token(%Scope{} = scope, id) do
    with :ok <- Organizations.authorize(scope, :manage_organization) do
      case Repo.get_by(Token, id: id, organization_id: scope.organization.id) do
        nil ->
          {:error, :not_found}

        token ->
          token
          |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second))
          |> Repo.update()
      end
    end
  end

  @doc """
  Turns a presented token into the scope it acts under.

  The role is read from the owner's membership **now**, not from anything stored
  on the token, so a token can never outrank its owner and loses its powers the
  moment they lose theirs.
  """
  @spec scope_for_token(String.t()) :: {:ok, Scope.t()} | {:error, :invalid_token}
  def scope_for_token(plaintext) when is_binary(plaintext) do
    hashed = Token.hash(plaintext)

    query =
      from t in Token,
        join: m in Membership,
        on: m.organization_id == t.organization_id and m.user_id == t.user_id,
        where: t.hashed_token == ^hashed and is_nil(t.revoked_at),
        preload: [:organization, :user],
        select: {t, m.role}

    case Repo.one(query) do
      nil ->
        {:error, :invalid_token}

      {token, role} ->
        touch(token)

        {:ok,
         token.user
         |> Scope.for_user()
         |> Scope.put_organization(token.organization, role)}
    end
  end

  def scope_for_token(_other), do: {:error, :invalid_token}

  # Best effort, and deliberately not part of the request's success: a write
  # that fails here must not turn a valid request into an error.
  defp touch(token) do
    now = DateTime.utc_now(:second)

    Repo.update_all(
      from(t in Token, where: t.id == ^token.id),
      set: [last_used_at: now]
    )

    :ok
  end
end
