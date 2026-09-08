defmodule PulseOps.Notifications.Notifier do
  @moduledoc """
  Where an organization's incident activity is sent when an incident opens or
  resolves.

  Two channels exist today:

    * `:webhook` — any URL that accepts a POST of JSON. Discord, Teams,
      Mattermost, ntfy, Gotify or a script of your own; `secret_token` is sent
      as a `Bearer` header when present.
    * `:email` — a plain recipient address, delivered through `PulseOps.Mailer`.

  A notifier is just configuration. Delivery is queued as an Oban job by
  `PulseOps.Notifications` when an incident changes state, so a slow receiver
  can never slow the monitor that spotted the incident.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PulseOps.Accounts.Scope
  alias PulseOps.Organizations.Organization

  @types [:webhook, :email]

  @type t :: %__MODULE__{}

  schema "notifiers" do
    field :name, :string
    field :type, Ecto.Enum, values: @types
    field :enabled, :boolean, default: true
    field :url, :string
    field :secret_token, :string
    field :recipient, :string

    belongs_to :organization, Organization

    timestamps(type: :utc_datetime)
  end

  @doc "The available delivery channels."
  def types, do: @types

  @doc """
  Whether a channel carries its own destination field that must be present.
  """
  def destination_field(:webhook), do: :url
  def destination_field(:email), do: :recipient

  @doc """
  Changeset for user-supplied notifier attributes. A notifier is scoped to an
  organization; the type decides which of the destination fields is required.
  """
  def changeset(notifier, attrs, %Scope{} = scope) do
    notifier
    |> cast(attrs, [:name, :type, :enabled, :url, :secret_token, :recipient])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, @types)
    |> validate_destinations()
    |> put_change(:organization_id, scope.organization.id)
    |> foreign_key_constraint(:organization_id)
  end

  defp validate_destinations(changeset) do
    case get_field(changeset, :type) do
      :webhook ->
        changeset
        |> validate_required([:url])
        |> validate_format(:url, ~r/^https?:\/\/\S+$/i, message: "must be an http(s) URL")

      :email ->
        changeset
        |> validate_required([:recipient])
        |> validate_format(:recipient, ~r/^[^\s@]+@[^\s@]+$/,
          message: "must be a valid email address"
        )

      _other ->
        changeset
    end
  end
end
