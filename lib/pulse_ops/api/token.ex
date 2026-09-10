defmodule PulseOps.Api.Token do
  @moduledoc """
  A credential that lets a program act on an organization's behalf.

  ## What is stored

  The hash, and nothing else. The token itself exists for exactly as long as the
  response that created it — it is shown once and cannot be recovered, only
  replaced. That is deliberately unlike `notifiers.secret_token`, which is
  encrypted rather than hashed because it has to be *sent* on every delivery; a
  token here only ever has to be *recognised*, and recognising something needs
  no more than its hash.

  A short `prefix` is kept in the clear so two tokens can be told apart in a
  list. It is not enough to replay.

  ## Whose permissions it carries

  A token has no permissions of its own. It names the person who created it, and
  the role comes from that person's membership **at request time**. So a token
  can never outrank its owner, and removing somebody from an organization
  disarms every token they made without anything having to remember to.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PulseOps.Accounts.User
  alias PulseOps.Organizations.Organization

  @hash_algorithm :sha256
  @rand_size 32

  # Identifies a PulseOps token on sight, so one pasted into a log or a
  # repository can be recognised and revoked by whoever finds it.
  @scheme "pops"
  @prefix_length 8

  @type t :: %__MODULE__{}

  schema "api_tokens" do
    field :name, :string
    field :hashed_token, :binary
    field :prefix, :string
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :organization, Organization
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a token and the row that recognises it.

  Returns `{plaintext, changeset}`. The plaintext is the only copy there will
  ever be.
  """
  @spec build(Organization.t(), User.t(), map()) :: {String.t(), Ecto.Changeset.t()}
  def build(%Organization{} = organization, %User{} = user, attrs) do
    plaintext =
      @scheme <> "_" <> Base.url_encode64(:crypto.strong_rand_bytes(@rand_size), padding: false)

    changeset =
      %__MODULE__{}
      |> cast(attrs, [:name])
      |> validate_required([:name])
      |> validate_length(:name, min: 2, max: 80)
      |> put_change(:organization_id, organization.id)
      |> put_change(:user_id, user.id)
      |> put_change(:hashed_token, hash(plaintext))
      |> put_change(
        :prefix,
        String.slice(plaintext, 0, String.length(@scheme) + 1 + @prefix_length)
      )
      |> unique_constraint(:name,
        name: :api_tokens_organization_id_name_index,
        message: "is already used by another token in this organization"
      )
      |> unique_constraint(:hashed_token)

    {plaintext, changeset}
  end

  @doc """
  The hash a presented token would be stored under.
  """
  @spec hash(String.t()) :: binary()
  def hash(plaintext) when is_binary(plaintext) do
    :crypto.hash(@hash_algorithm, plaintext)
  end

  @doc """
  Whether the token is still usable.
  """
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{revoked_at: nil}), do: true
  def active?(%__MODULE__{}), do: false

  @doc """
  The prefix every token starts with, for documentation and for tests.
  """
  @spec scheme() :: String.t()
  def scheme, do: @scheme
end
