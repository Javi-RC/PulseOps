defmodule PulseOps.Organizations.Membership do
  @moduledoc """
  Joins a user to an organization and carries their role in it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PulseOps.Accounts.User
  alias PulseOps.Organizations.Organization

  @roles [:owner, :admin, :member, :viewer]

  @type t :: %__MODULE__{}

  schema "organization_members" do
    field :role, Ecto.Enum, values: @roles

    belongs_to :organization, Organization
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  The roles a membership can hold, from most to least privileged.
  """
  def roles, do: @roles

  @doc false
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:organization_id, :user_id, :role])
    |> validate_required([:organization_id, :user_id, :role])
    |> unique_constraint([:organization_id, :user_id],
      message: "is already a member of this organization"
    )
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:user_id)
  end
end
