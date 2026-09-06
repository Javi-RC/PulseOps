defmodule PulseOps.Incidents.Incident do
  @moduledoc """
  A period during which a service was not healthy.

  Opened automatically when a monitor reports a service down, and resolved
  automatically when it recovers. In between, people move it through the
  workflow and record what caused it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PulseOps.Accounts.User
  alias PulseOps.Incidents.IncidentEvent
  alias PulseOps.Monitoring.Service
  alias PulseOps.Organizations.Organization

  @severities [:low, :medium, :high, :critical]
  @statuses [:open, :investigating, :identified, :monitoring, :resolved]

  @type t :: %__MODULE__{}

  schema "incidents" do
    field :title, :string
    field :severity, Ecto.Enum, values: @severities
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :cause, :string
    field :started_at, :utc_datetime
    field :resolved_at, :utc_datetime

    belongs_to :service, Service
    belongs_to :organization, Organization
    belongs_to :resolved_by, User

    has_many :events, IncidentEvent, preload_order: [asc: :occurred_at]

    timestamps(type: :utc_datetime)
  end

  def severities, do: @severities
  def statuses, do: @statuses

  @doc """
  The statuses a person can move an unresolved incident to. Resolving is a
  separate operation because it also stamps who did it and when.
  """
  def workflow_statuses, do: @statuses -- [:resolved]

  @doc false
  def open_changeset(incident, attrs) do
    incident
    |> cast(attrs, [:service_id, :organization_id, :title, :severity, :started_at])
    |> validate_required([:service_id, :organization_id, :title, :severity, :started_at])
    |> put_change(:status, :open)
    |> unique_constraint(:service_id,
      name: :incidents_one_open_per_service,
      message: "already has an open incident"
    )
  end

  @doc false
  def workflow_changeset(incident, attrs) do
    incident
    |> cast(attrs, [:status, :cause, :severity])
    |> validate_required([:status])
    |> validate_inclusion(:status, workflow_statuses(),
      message: "cannot be set directly; resolve the incident instead"
    )
  end

  @doc false
  def resolve_changeset(incident, attrs) do
    incident
    |> cast(attrs, [:cause, :resolved_by_id])
    |> put_change(:status, :resolved)
    |> put_change(:resolved_at, DateTime.utc_now(:second))
  end

  @doc """
  How long the incident lasted, in seconds; for an open incident, how long it has
  been going.
  """
  def duration_seconds(%__MODULE__{started_at: started_at, resolved_at: resolved_at}) do
    DateTime.diff(resolved_at || DateTime.utc_now(:second), started_at)
  end

  @doc """
  Whether the incident is still open.
  """
  def open?(%__MODULE__{resolved_at: nil}), do: true
  def open?(%__MODULE__{}), do: false
end
