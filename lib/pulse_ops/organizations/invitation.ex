defmodule PulseOps.Organizations.Invitation do
  @moduledoc """
  An offer to join an organization, sent to an address that may not have an
  account here yet.

  ## The link is a credential

  Holding it is what lets somebody join, so it is treated like every other token
  in this schema: generated from strong random bytes, stored only as a hash,
  single use, and expiring. It is emailed to one address, and control of that
  mailbox is the whole proof — the same proof the magic-link login already
  accepts. That is why accepting can create the account and sign the person in:
  it is a login that also grants a membership, not a second, weaker path in.

  What it must not become is a link that acts on its own. A `GET` is followed by
  mail scanners and link prefetchers, so the invitation page only *offers* to
  accept; accepting is a `POST`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PulseOps.Accounts.User
  alias PulseOps.Organizations.Membership
  alias PulseOps.Organizations.Organization

  @hash_algorithm :sha256
  @rand_size 32

  # Long enough to survive a weekend and a holiday Monday; short enough that a
  # forgotten invitation in an old mailbox is not a way in a year later.
  @validity_days 7

  @type t :: %__MODULE__{}

  schema "organization_invitations" do
    field :email, :string
    field :role, Ecto.Enum, values: Membership.roles()
    field :hashed_token, :binary
    field :expires_at, :utc_datetime
    field :accepted_at, :utc_datetime

    belongs_to :organization, Organization
    belongs_to :invited_by, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds an invitation and the token that redeems it.

  Returns `{token, changeset}`. The token is never stored and appears only in
  the email.
  """
  @spec build(Organization.t(), User.t(), map()) :: {String.t(), Ecto.Changeset.t()}
  def build(%Organization{} = organization, %User{} = inviter, attrs) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(@rand_size), padding: false)

    changeset =
      %__MODULE__{}
      |> cast(attrs, [:email, :role])
      |> update_change(:email, &normalize_email/1)
      |> validate_required([:email, :role])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/,
        message: "must be a valid email address"
      )
      |> validate_length(:email, max: 160)
      |> validate_inclusion(:role, Membership.roles())
      |> put_change(:organization_id, organization.id)
      |> put_change(:invited_by_id, inviter.id)
      |> put_change(:hashed_token, hash(token))
      |> put_change(:expires_at, DateTime.add(DateTime.utc_now(:second), @validity_days, :day))
      |> unique_constraint(:email,
        name: :organization_invitations_one_pending_per_email,
        message: "already has an invitation waiting"
      )
      |> unique_constraint(:hashed_token)

    {token, changeset}
  end

  @doc """
  The hash a presented token would be stored under.
  """
  @spec hash(String.t()) :: binary()
  def hash(token) when is_binary(token), do: :crypto.hash(@hash_algorithm, token)

  @doc """
  Whether the invitation can still be accepted.
  """
  @spec pending?(t(), DateTime.t()) :: boolean()
  def pending?(invitation, now \\ DateTime.utc_now())

  def pending?(%__MODULE__{accepted_at: nil, expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  def pending?(%__MODULE__{}, _now), do: false

  @doc """
  How long an invitation stays valid, in days.
  """
  @spec validity_days() :: pos_integer()
  def validity_days, do: @validity_days

  @doc """
  Lower-cased and trimmed, the way `users.email` is compared.
  """
  @spec normalize_email(String.t()) :: String.t()
  def normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  def normalize_email(other), do: other
end
