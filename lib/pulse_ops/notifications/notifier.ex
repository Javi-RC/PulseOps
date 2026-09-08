defmodule PulseOps.Notifications.Notifier do
  @moduledoc """
  Where an organization's incident activity is sent when an incident opens or
  resolves.

  Two channels exist today:

    * `:webhook` — any URL that accepts a POST of JSON. Discord, Teams,
      Mattermost, ntfy, Gotify or a script of your own; `secret_token` is sent
      as a `Bearer` header when present.
    * `:email` — a plain recipient account owned by the organization, delivered
      through `PulseOps.Notifications.Mailer`.

  A notifier is scoped to an organization, optionally narrowed to a single
  service (when `service_id` is set it only fires for that service's incidents;
  when nil it fires for any incident in the organization). Email notifiers reach
  every user they are assigned to; webhook notifiers record the people
  responsible for the channel through the same assignments.

  Delivery is queued as an Oban job by `PulseOps.Notifications` when an incident
  changes state, so a slow receiver can never slow the monitor that spotted the
  incident.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PulseOps.Accounts.Scope
  alias PulseOps.Monitoring.Service
  alias PulseOps.Notifications.NotifierAssignment
  alias PulseOps.Organizations.Organization
  alias PulseOps.Repo

  @types [:webhook, :email]

  @type t :: %__MODULE__{}

  schema "notifiers" do
    field :name, :string
    field :type, Ecto.Enum, values: @types
    field :enabled, :boolean, default: true
    field :url, :string
    field :secret_token, :string
    field :assignee_ids, {:array, :integer}, virtual: true

    belongs_to :organization, Organization
    belongs_to :service, Service

    has_many :assignments, NotifierAssignment, on_delete: :delete_all
    has_many :assigned_users, through: [:assignments, :user]

    timestamps(type: :utc_datetime)
  end

  @doc "The available delivery channels."
  def types, do: @types

  @doc """
  The destination a channel carries: `:url` for webhooks. Email notifiers have
  no single destination field — they reach their assigned users, so nothing is
  required here.
  """
  def destination_field(:webhook), do: :url
  def destination_field(:email), do: nil

  @doc """
  Changeset for user-supplied notifier attributes. A notifier is scoped to an
  organization; the type decides which of the destination fields is required.
  """
  def changeset(notifier, attrs, %Scope{} = scope) do
    notifier
    |> cast(attrs, [:name, :type, :enabled, :url, :secret_token, :service_id, :assignee_ids])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, @types)
    |> put_change(:organization_id, scope.organization.id)
    |> validate_destinations()
    |> validate_service_scope()
    |> normalize_service_id()
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:service_id)
  end

  defp validate_destinations(changeset) do
    case get_field(changeset, :type) do
      :webhook ->
        changeset
        |> validate_required([:url])
        |> validate_format(:url, ~r/^https?:\/\/\S+$/i, message: "must be an http(s) URL")

      _other ->
        changeset
    end
  end

  # When a service is set, it must belong to the same organization as the
  # notifier, so a notifier can never point at another tenant's service.
  defp validate_service_scope(changeset) do
    service_id = get_field(changeset, :service_id)

    cond do
      is_nil(service_id) ->
        changeset

      service_in_organization?(service_id, get_field(changeset, :organization_id)) ->
        changeset

      true ->
        add_error(changeset, :service_id, "must belong to the organization")
    end
  end

  defp service_in_organization?(service_id, organization_id) do
    case Repo.get(Service, service_id) do
      %Service{organization_id: org_id} -> org_id == organization_id
      _ -> false
    end
  end

  # The "every service" option submits an empty string; read it as "not
  # narrowed" so it stays nil in the database.
  defp normalize_service_id(changeset) do
    case get_change(changeset, :service_id) do
      "" -> put_change(changeset, :service_id, nil)
      _ -> changeset
    end
  end
end
