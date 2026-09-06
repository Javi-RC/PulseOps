defmodule PulseOps.Organizations.Organization do
  @moduledoc """
  A tenant. Every service, check and incident belongs to exactly one.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PulseOps.Organizations.Membership

  @type t :: %__MODULE__{}

  schema "organizations" do
    field :name, :string
    field :slug, :string

    has_many :memberships, Membership
    has_many :users, through: [:memberships, :user]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:name, :slug])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 80)
    |> put_slug()
    |> validate_required([:slug])
    |> validate_format(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
      message: "must contain only lowercase letters, numbers and hyphens"
    )
    |> validate_length(:slug, min: 2, max: 60)
    |> unsafe_validate_unique(:slug, PulseOps.Repo)
    |> unique_constraint(:slug)
  end

  # A slug can be supplied explicitly; otherwise it is derived from the name so
  # that registration never has to ask the user for one.
  defp put_slug(changeset) do
    case get_field(changeset, :slug) do
      nil ->
        case get_field(changeset, :name) do
          nil -> changeset
          name -> put_change(changeset, :slug, slugify(name))
        end

      _slug ->
        changeset
    end
  end

  @doc """
  Turns arbitrary text into a URL-safe slug.
  """
  def slugify(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/[^a-zA-Z0-9\s-]/u, "")
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s-]+/, "-")
  end
end
