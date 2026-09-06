defmodule PulseOps.Monitoring.Supervisor do
  @moduledoc """
  Everything the monitors need, in the order they need it.

  The registry and the task supervisor must be up before any monitor starts, and
  the bootstrapper starts monitors, so it goes last.
  """

  use Supervisor

  alias PulseOps.Monitoring.Bootstrapper
  alias PulseOps.Monitoring.MonitorSupervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: PulseOps.Monitoring.Registry},
      {Task.Supervisor, name: PulseOps.Monitoring.TaskSupervisor},
      MonitorSupervisor,
      Bootstrapper
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
