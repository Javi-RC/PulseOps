defmodule PulseOps.Monitoring.MonitorContainer do
  @moduledoc """
  The supervisor for exactly one service's monitor.

  ## Why a monitor has a supervisor of its own

  Monitors used to sit directly under `MonitorSupervisor`, a `DynamicSupervisor`
  with `max_restarts: 5, max_seconds: 60`. That bound reads like "a monitor that
  crashes five times is given up on". It is not: restart intensity belongs to the
  supervisor, not to a child. The sixth crash of *any one* monitor inside a minute
  exceeded it, the `DynamicSupervisor` terminated itself with every monitor under
  it, and nothing started them again. One misbehaving service left every service
  in every organization unwatched (F10).

  A container gives each service its own restart budget. When a monitor crashes
  too often, only its container reaches the limit and exits.

  ## Why the container is temporary

  A container that has given up must stay down. If `MonitorSupervisor` restarted
  it, the restarts would be counted against `MonitorSupervisor`'s intensity again
  — which is the shared budget this module exists to get away from. A temporary
  child is never restarted, so it never counts.

  ## Why the monitor is significant

  A monitor also stops *normally*, when its service row is gone. Without
  `auto_shutdown` the container would outlive it, empty, still holding the
  service's name in the registry. Marking the monitor significant makes its
  normal exit shut the container down with it.
  """

  use Supervisor

  alias PulseOps.Monitoring.Service
  alias PulseOps.Monitoring.ServiceMonitor

  @max_restarts 5
  @max_seconds 60

  def child_spec(%Service{} = service) do
    %{
      id: {__MODULE__, service.id},
      start: {__MODULE__, :start_link, [service]},
      type: :supervisor,
      restart: :temporary
    }
  end

  def start_link(%Service{} = service) do
    Supervisor.start_link(__MODULE__, service, name: via(service.id))
  end

  @doc """
  The `:via` tuple a container is registered under.
  """
  def via(service_id) do
    {:via, Registry, {PulseOps.Monitoring.Registry, {:container, service_id}}}
  end

  @doc """
  The pid of the container for a service, or nil if there is none.
  """
  def whereis(service_id) do
    case Registry.lookup(PulseOps.Monitoring.Registry, {:container, service_id}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @impl true
  def init(%Service{} = service) do
    children = [Supervisor.child_spec({ServiceMonitor, service}, significant: true)]

    Supervisor.init(children,
      strategy: :one_for_one,
      # Per service now, which is what these numbers always claimed to be.
      max_restarts: @max_restarts,
      max_seconds: @max_seconds,
      auto_shutdown: :any_significant
    )
  end
end
