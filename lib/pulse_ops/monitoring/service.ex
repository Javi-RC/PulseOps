defmodule PulseOps.Monitoring.Service do
  @moduledoc """
  A monitored endpoint. Each enabled service is watched by its own supervised
  process, which probes `url` every `check_interval_ms`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PulseOps.Organizations.Organization

  @environments [:production, :staging, :development]
  @statuses [:unknown, :healthy, :degraded, :down]

  # A check that fires faster than every 10s is a load test, not monitoring; an
  # interval beyond an hour stops being useful for incident detection.
  @min_interval_ms 10_000
  @max_interval_ms 3_600_000
  @min_timeout_ms 1_000
  @max_timeout_ms 30_000

  @type t :: %__MODULE__{}

  schema "services" do
    field :name, :string
    field :description, :string
    field :environment, Ecto.Enum, values: @environments, default: :production
    field :url, :string
    field :check_interval_ms, :integer, default: 60_000
    field :timeout_ms, :integer, default: 5_000
    field :enabled, :boolean, default: true
    field :status, Ecto.Enum, values: @statuses, default: :unknown
    field :last_checked_at, :utc_datetime

    belongs_to :organization, Organization

    timestamps(type: :utc_datetime)
  end

  def environments, do: @environments
  def statuses, do: @statuses

  @doc """
  Changeset for user-supplied service attributes.

  `status` and `last_checked_at` are deliberately not castable here: they are
  owned by the monitor process, not by the form.
  """
  def changeset(service, attrs, organization_scope) do
    service
    |> cast(attrs, [
      :name,
      :description,
      :environment,
      :url,
      :check_interval_ms,
      :timeout_ms,
      :enabled
    ])
    |> validate_required([:name, :environment, :url, :check_interval_ms, :timeout_ms])
    |> validate_length(:name, min: 2, max: 80)
    |> validate_url(:url)
    |> validate_number(:check_interval_ms,
      greater_than_or_equal_to: @min_interval_ms,
      less_than_or_equal_to: @max_interval_ms
    )
    |> validate_number(:timeout_ms,
      greater_than_or_equal_to: @min_timeout_ms,
      less_than_or_equal_to: @max_timeout_ms
    )
    |> validate_timeout_fits_interval()
    |> put_change(:organization_id, organization_scope.organization.id)
    # Reported against :name rather than the composite default, so the form shows
    # the error under the field the user can actually change.
    |> unique_constraint(:name,
      name: :services_organization_id_name_index,
      message: "a service with this name already exists"
    )
    |> foreign_key_constraint(:organization_id)
  end

  @doc """
  Changeset used by the monitor to record the outcome of a check.

  Kept separate from `changeset/3` so that a probe result can never be smuggled
  in through a user-facing form, and vice versa.
  """
  def status_changeset(service, attrs) do
    service
    |> cast(attrs, [:status, :last_checked_at])
    |> validate_required([:status])
  end

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case URI.parse(value) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _otherwise ->
          [{field, "must be a valid http or https URL"}]
      end
    end)
  end

  # A request still in flight when the next one is due would overlap with it and
  # make the failure counters meaningless.
  defp validate_timeout_fits_interval(changeset) do
    interval = get_field(changeset, :check_interval_ms)
    timeout = get_field(changeset, :timeout_ms)

    if is_integer(interval) and is_integer(timeout) and timeout >= interval do
      add_error(changeset, :timeout_ms, "must be shorter than the check interval")
    else
      changeset
    end
  end
end
