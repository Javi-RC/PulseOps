defmodule PulseOps.Monitoring.Check do
  @moduledoc """
  The recorded outcome of a single probe against a service.

  One row per probe. This is the raw history the uptime and latency figures are
  derived from.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PulseOps.Monitoring.Service

  @statuses [:healthy, :degraded, :down]

  @type t :: %__MODULE__{}

  schema "service_checks" do
    field :status, Ecto.Enum, values: @statuses
    field :http_status, :integer
    field :response_time_ms, :integer
    field :error, :string

    belongs_to :service, Service

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def statuses, do: @statuses

  @doc false
  def changeset(check, attrs) do
    check
    |> cast(attrs, [:service_id, :status, :http_status, :response_time_ms, :error])
    |> validate_required([:service_id, :status])
    # Errors come from exception messages, which can be arbitrarily long; the
    # column is bounded, so truncate rather than fail to record the check.
    |> update_change(:error, &truncate(&1, 255))
    |> foreign_key_constraint(:service_id)
  end

  defp truncate(nil, _max), do: nil
  defp truncate(text, max) when byte_size(text) <= max, do: text
  defp truncate(text, max), do: String.slice(text, 0, max)
end
