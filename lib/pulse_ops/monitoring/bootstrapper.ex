defmodule PulseOps.Monitoring.Bootstrapper do
  @moduledoc """
  Starts a monitor for every enabled service when the application boots.

  Runs its work in `handle_continue/2` so a slow or unavailable database delays
  monitoring rather than the whole application startup.

  Services are read a page at a time, keyed on id. Loading them all at once held
  every enabled service row — request headers and all — in this process's heap
  for the whole start-up, in a process that does nothing afterwards and so is
  never collected. Pages keep that bounded by the page size, not by the size of
  the installation.
  """

  use GenServer

  require Logger

  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.MonitorSupervisor

  @page_size 500

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a monitor for every enabled service, reading them `:page_size` at a
  time. Returns how many monitors were started; where monitors are switched off,
  starts nothing and returns 0.
  """
  @spec start_monitors(keyword()) :: non_neg_integer()
  def start_monitors(opts \\ []) do
    if MonitorSupervisor.enabled?() do
      start_page(0, Keyword.get(opts, :page_size, @page_size), 0)
    else
      0
    end
  end

  defp start_page(after_id, page_size, started) do
    services = Monitoring.list_enabled_services(after: after_id, limit: page_size)

    started =
      services
      |> Enum.map(&MonitorSupervisor.start_monitor/1)
      |> Enum.count(&match?({:ok, pid} when is_pid(pid), &1))
      |> Kernel.+(started)

    # A short page is the last one, so it needs no query to find out.
    if length(services) < page_size do
      started
    else
      start_page(List.last(services).id, page_size, started)
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{}, {:continue, :start_monitors}}

  @impl true
  def handle_continue(:start_monitors, state) do
    if MonitorSupervisor.enabled?() do
      Logger.info("started #{start_monitors()} service monitors")
    end

    {:noreply, state}
  end
end
