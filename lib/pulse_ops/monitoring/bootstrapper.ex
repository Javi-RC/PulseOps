defmodule PulseOps.Monitoring.Bootstrapper do
  @moduledoc """
  Starts a monitor for every enabled service when the application boots.

  Runs its work in `handle_continue/2` so a slow or unavailable database delays
  monitoring rather than the whole application startup.
  """

  use GenServer

  require Logger

  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.MonitorSupervisor

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: {:ok, %{}, {:continue, :start_monitors}}

  @impl true
  def handle_continue(:start_monitors, state) do
    if MonitorSupervisor.enabled?() do
      started =
        Monitoring.list_enabled_services()
        |> Enum.map(&MonitorSupervisor.start_monitor/1)
        |> Enum.count(&match?({:ok, pid} when is_pid(pid), &1))

      Logger.info("started #{started} service monitors")
    end

    {:noreply, state}
  end
end
