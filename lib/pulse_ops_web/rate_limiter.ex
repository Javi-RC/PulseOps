defmodule PulseOpsWeb.RateLimiter do
  @moduledoc """
  Fixed-window counters, in ETS, for anything that has to be slowed down
  (ADR-019).

  A window is `window_ms` long and aligned to the clock, so every key's window
  for a given length starts and ends together. That lets a burst straddling a
  boundary through at up to twice the limit — acceptable for its purpose, which
  is making guessing slow, not metering.

  The table is public so callers count without a message round trip;
  `:ets.update_counter/4` makes each hit atomic. This process only owns the
  table and sweeps windows that have ended. If it crashes the counts start over,
  which errs towards letting people in.

  Counts are per node. PulseOps runs as one node (see the README); a cluster
  would need a shared store.
  """

  use GenServer

  @table __MODULE__
  @sweep_every_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Counts one hit against `key` and says whether it is inside `limit` for the
  current window. A refusal carries how long until the window ends.
  """
  @spec hit(term(), pos_integer(), pos_integer()) :: :ok | {:deny, pos_integer()}
  def hit(key, limit, window_ms) do
    now = now_ms()
    {slot, expires_at} = slot(key, now, window_ms)
    count = :ets.update_counter(@table, slot, {2, 1}, {slot, 0, expires_at})

    if count <= limit, do: :ok, else: {:deny, expires_at - now}
  end

  @doc """
  Whether a hit would be refused, without counting one. For attempts that only
  count when they fail.
  """
  @spec check(term(), pos_integer(), pos_integer()) :: :ok | {:deny, pos_integer()}
  def check(key, limit, window_ms) do
    now = now_ms()
    {slot, expires_at} = slot(key, now, window_ms)

    case :ets.lookup(@table, slot) do
      [{^slot, count, _expires_at}] when count >= limit -> {:deny, expires_at - now}
      _below_limit -> :ok
    end
  end

  @doc """
  Drops every window that has ended.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    now = now_ms()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
  end

  @doc """
  Whether anything is being counted for `key`, in any window.
  """
  @spec tracked?(term()) :: boolean()
  def tracked?(key) do
    :ets.select_count(@table, [{{{key, :_, :_}, :_, :_}, [], [true]}]) > 0
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every_ms)

  # The window length is part of the slot, so one key used with two different
  # windows never shares a count.
  defp slot(key, now, window_ms) do
    window = Integer.floor_div(now, window_ms)
    {{key, window_ms, window}, (window + 1) * window_ms}
  end

  # Monotonic, so a wall-clock adjustment can neither reopen nor extend a window.
  defp now_ms, do: System.monotonic_time(:millisecond)
end
