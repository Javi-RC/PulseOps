defmodule PulseOps.Monitoring.Rollup do
  @moduledoc """
  One hour of a service's checks, pre-aggregated.

  `service_checks` grows at `86,400 / interval` rows per service per day, and
  both the dashboard's uptime figures and the service detail metrics aggregated
  over those raw rows — so the cost of a page grew with the retention window,
  which is configurable. A rollup row stands in for every check in its hour, and
  the number of rows a query touches is bounded by hours rather than by how
  often services are probed.

  ## Why latency is a histogram and not three percentiles

  Counts merge across hours by addition, so uptime over a day is exact from 24
  rollups. Percentiles do not merge: the p95 of a day is not the average of 24
  hourly p95s, and it is not the p95 of them either. Storing hourly percentiles
  would produce a number that looks authoritative and is wrong by an unknown
  amount.

  A cumulative histogram does merge by addition. `latency_le_100` is the number
  of checks in the hour that responded in 100 ms or less, so summing that column
  across hours gives the true count for the whole window. Percentiles are then
  interpolated out of the merged histogram, the way `histogram_quantile` does it.
  The error is bounded by the width of the bucket the answer lands in, and it is
  bounded in a direction you can reason about, which is the whole difference.
  """

  use Ecto.Schema

  alias PulseOps.Monitoring.Service

  # Upper bounds in milliseconds. Roughly logarithmic, and dense where a health
  # check's response time is actually interesting.
  @bounds [25, 50, 100, 250, 500, 1000, 2500, 5000]

  @type t :: %__MODULE__{}

  schema "service_check_rollups" do
    field :bucket_start, :utc_datetime

    field :total, :integer, default: 0
    field :up, :integer, default: 0
    field :degraded, :integer, default: 0
    field :down, :integer, default: 0

    field :latency_count, :integer, default: 0
    field :latency_sum, :integer, default: 0
    field :latency_max, :integer

    for bound <- @bounds do
      field :"latency_le_#{bound}", :integer, default: 0
    end

    belongs_to :service, Service

    timestamps(type: :utc_datetime)
  end

  @doc """
  The histogram's bucket upper bounds, in milliseconds.
  """
  @spec bounds() :: [pos_integer()]
  def bounds, do: @bounds

  @doc """
  The fields a rollup row carries, in the order the aggregation builds them.
  """
  @spec counter_fields() :: [atom()]
  def counter_fields do
    [:total, :up, :degraded, :down, :latency_count, :latency_sum] ++
      Enum.map(@bounds, &:"latency_le_#{&1}")
  end

  @doc """
  Estimates a percentile from a merged histogram.

  `histogram` maps each bound to the cumulative count of checks at or under it,
  and `count` is the total number of checks that recorded a response time.
  Returns nil when nothing was measured.

  Interpolates linearly inside the bucket the target rank lands in. A rank past
  the last bound cannot be interpolated — nothing is known about the shape above
  it — so the observed maximum is the honest answer there.
  """
  @spec percentile(map(), non_neg_integer(), float(), pos_integer() | nil) :: number() | nil
  def percentile(_histogram, 0, _p, _max), do: nil
  def percentile(_histogram, _count, _p, nil), do: nil

  def percentile(histogram, count, p, max) when count > 0 do
    rank = p * count

    @bounds
    |> Enum.reduce_while({0, 0}, fn bound, {lower_bound, lower_count} ->
      cumulative = Map.get(histogram, bound, 0)

      if cumulative >= rank and cumulative > lower_count do
        fraction = (rank - lower_count) / (cumulative - lower_count)
        {:halt, round(lower_bound + fraction * (bound - lower_bound))}
      else
        {:cont, {bound, cumulative}}
      end
    end)
    |> case do
      # Never reached a bucket holding the rank: it sits above the last bound,
      # where the only thing actually observed is the maximum.
      {_lower_bound, _lower_count} -> max
      value -> min(value, max)
    end
  end
end
