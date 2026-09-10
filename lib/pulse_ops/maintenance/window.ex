defmodule PulseOps.Maintenance.Window do
  @moduledoc """
  A period during which a service is expected to misbehave.

  Checks are still made and still recorded — the history stays honest, and the
  dashboard still shows what is actually happening. What a window suppresses is
  the *consequence*: no incident opens, so nobody is paged for a deploy somebody
  scheduled.

  A null `service_id` covers the whole organization, the same shape
  `alert_rules` uses for its default.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias PulseOps.Accounts.Scope
  alias PulseOps.Accounts.User
  alias PulseOps.Monitoring.Service
  alias PulseOps.Organizations.Organization
  alias PulseOps.Repo

  # A window is a promise that somebody is watching. Beyond a month it is not a
  # maintenance window, it is a service nobody wants to hear about, and the way
  # to say that is to disable the service.
  @max_days 31

  @type t :: %__MODULE__{}

  schema "maintenance_windows" do
    field :reason, :string
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime

    belongs_to :organization, Organization
    belongs_to :service, Service
    belongs_to :created_by, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  The longest a window may run, in days.
  """
  @spec max_days() :: pos_integer()
  def max_days, do: @max_days

  @doc false
  def changeset(window, attrs, %Scope{} = scope) do
    window
    |> cast(attrs, [:reason, :starts_at, :ends_at, :service_id])
    |> validate_required([:reason, :starts_at, :ends_at])
    |> validate_length(:reason, min: 2, max: 200)
    |> put_change(:organization_id, scope.organization.id)
    |> validate_ends_after_start()
    |> validate_duration()
    |> validate_service_scope()
    |> check_constraint(:ends_at,
      name: :maintenance_windows_end_after_start,
      message: "must be after the start"
    )
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:service_id)
  end

  defp validate_ends_after_start(changeset) do
    starts_at = get_field(changeset, :starts_at)
    ends_at = get_field(changeset, :ends_at)

    if starts_at && ends_at && DateTime.compare(ends_at, starts_at) != :gt do
      add_error(changeset, :ends_at, "must be after the start")
    else
      changeset
    end
  end

  defp validate_duration(changeset) do
    starts_at = get_field(changeset, :starts_at)
    ends_at = get_field(changeset, :ends_at)

    if starts_at && ends_at && DateTime.diff(ends_at, starts_at, :day) > @max_days do
      add_error(changeset, :ends_at, "cannot be more than #{@max_days} days after the start")
    else
      changeset
    end
  end

  # The same check `AlertRule` and `Notifier` make: a window aimed at another
  # tenant's service would silence their alerts, which is worse than the
  # denial of service an unvalidated alert rule caused (F3).
  defp validate_service_scope(changeset) do
    service_id = get_field(changeset, :service_id)
    organization_id = get_field(changeset, :organization_id)

    cond do
      is_nil(service_id) ->
        changeset

      service_in_organization?(service_id, organization_id) ->
        changeset

      true ->
        add_error(changeset, :service_id, "must belong to the organization")
    end
  end

  defp service_in_organization?(service_id, organization_id) do
    Repo.exists?(
      from(s in Service, where: s.id == ^service_id and s.organization_id == ^organization_id)
    )
  end

  @doc """
  Whether the window covers a moment in time.
  """
  @spec covers?(t(), DateTime.t()) :: boolean()
  def covers?(%__MODULE__{starts_at: starts_at, ends_at: ends_at}, at) do
    DateTime.compare(at, starts_at) != :lt and DateTime.compare(at, ends_at) == :lt
  end

  @doc """
  Where the window sits relative to now, for display.
  """
  @spec state(t(), DateTime.t()) :: :scheduled | :active | :finished
  def state(window, now \\ DateTime.utc_now())

  def state(%__MODULE__{} = window, now) do
    cond do
      covers?(window, now) -> :active
      DateTime.compare(now, window.starts_at) == :lt -> :scheduled
      true -> :finished
    end
  end
end
