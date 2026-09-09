defmodule PulseOps.Incidents.IncidentEvent do
  @moduledoc """
  One entry on an incident's timeline.

  `user_id` is null for the entries the system writes itself, which is what
  distinguishes "the monitor saw this" from "somebody did this".
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PulseOps.Accounts.User
  alias PulseOps.Incidents.Incident

  @types [
    :detected,
    :opened,
    :reopened,
    :acknowledged,
    :escalated,
    :status_changed,
    :note,
    :resolved,
    :recovered
  ]

  @type t :: %__MODULE__{}

  schema "incident_events" do
    field :type, Ecto.Enum, values: @types
    field :description, :string
    field :occurred_at, :utc_datetime_usec

    belongs_to :incident, Incident
    belongs_to :user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def types, do: @types

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:incident_id, :user_id, :type, :description, :occurred_at])
    |> validate_required([:incident_id, :type, :description])
    |> put_occurred_at()
    |> foreign_key_constraint(:incident_id)
  end

  defp put_occurred_at(changeset) do
    case get_field(changeset, :occurred_at) do
      nil -> put_change(changeset, :occurred_at, DateTime.utc_now())
      _set -> changeset
    end
  end

  @doc """
  Whether the event was written by the system rather than by a person.
  """
  def automatic?(%__MODULE__{user_id: nil}), do: true
  def automatic?(%__MODULE__{}), do: false
end
