defmodule PulseOps.Monitoring.ServiceMonitor do
  @moduledoc """
  Watches one service: probes it on a schedule, decides what its status is, and
  records every probe.

  One of these runs per enabled service, supervised individually, so a service
  whose endpoint misbehaves cannot affect the monitoring of any other.

  ## Why the request does not happen in the callback

  A GenServer has one mailbox and handles one message at a time. Calling the HTTP
  client directly from `handle_info(:check, ...)` would block this process for the
  whole timeout — it could not answer a `GenServer.call`, could not be
  reconfigured, and could not shut down cleanly. So the probe runs in a task
  under `Task.Supervisor.async_nolink/2` and the outcome arrives as a message.
  `async_nolink` also means a crash inside the request cannot take the monitor
  down with it.
  """

  use GenServer, restart: :transient

  require Logger

  alias PulseOps.Incidents
  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.HealthCheck
  alias PulseOps.Monitoring.HealthCheck.Result
  alias PulseOps.Monitoring.Service
  alias PulseOps.Monitoring.StatusMachine

  # Monitors that all started together would otherwise probe in lockstep for ever
  # and hammer shared infrastructure in bursts.
  @jitter_ratio 0.1

  # Grace period on top of the service timeout before the monitor gives up on a
  # task that has not reported back.
  @task_grace_ms 2_000

  defstruct [
    :service,
    :task,
    :timeout_ref,
    :timer_ref,
    :rule,
    :machine,
    last_check_status: nil,
    last_error: nil
  ]

  ## Client

  def child_spec(%Service{} = service) do
    %{
      id: {__MODULE__, service.id},
      start: {__MODULE__, :start_link, [service]},
      restart: :transient
    }
  end

  def start_link(%Service{} = service) do
    GenServer.start_link(__MODULE__, service, name: via(service.id))
  end

  @doc """
  The `:via` tuple a monitor is registered under, so it can be reached by service id.
  """
  def via(service_id) do
    {:via, Registry, {PulseOps.Monitoring.Registry, {:monitor, service_id}}}
  end

  @doc """
  The pid of the monitor for a service, or nil if none is running.
  """
  def whereis(service_id) do
    case Registry.lookup(PulseOps.Monitoring.Registry, {:monitor, service_id}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc """
  Current state of a monitor, for inspection and tests.
  """
  def status(service_id), do: GenServer.call(via(service_id), :status)

  @doc """
  Probes now instead of waiting for the next scheduled tick.
  """
  def check_now(service_id), do: GenServer.cast(via(service_id), :check)

  @doc """
  Tells a monitor its alert rule may have changed, so it re-reads it.

  A monitor used to be restarted for this, which meant stopping a process,
  waiting for the registry to release its name and booting a replacement — per
  affected service, in sequence, from whichever process saved the rule. An
  organization-wide rule made that O(number of services) of blocking work.

  A cast reaches every affected monitor without any of them waiting on each
  other, and each re-reads its own rule in its own process.
  """
  def rule_changed(service_id) do
    case whereis(service_id) do
      nil -> :ok
      _pid -> GenServer.cast(via(service_id), :rule_changed)
    end
  end

  ## Server

  @impl true
  def init(%Service{} = service) do
    state = %__MODULE__{
      service: service,
      machine: StatusMachine.new(service.status),
      rule: Monitoring.rule_for_monitoring(service)
    }

    # First probe is almost immediate so a newly created service shows a real
    # status quickly, but still spread out so a mass restart does not stampede.
    {:ok, schedule_check(state, :initial), {:continue, :reconcile_incident}}
  end

  # Incidents are opened on a status *transition*, so a restart while a service
  # is already down would otherwise leave it with no incident at all: the monitor
  # starts in :down, never transitions, and nothing fires. Reconciling at startup
  # keeps the invariant "a down service has an open incident" true across
  # restarts and crashes; reconciling again after every probe keeps it true while
  # the monitor runs, which boot-only reconciliation did not (ADR-009).
  @impl true
  def handle_continue(:reconcile_incident, state) do
    state = %{state | rule: Monitoring.rule_for_monitoring(state.service)}
    Incidents.reconcile_incident(state.service, state.machine.status, state.rule)

    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       status: state.machine.status,
       consecutive_failures: state.machine.consecutive_failures,
       consecutive_successes: state.machine.consecutive_successes,
       checking?: state.task != nil,
       # Which rule the monitor is actually running on, which is the only way to
       # observe that a rule change reached it.
       failure_threshold: state.rule.failure_threshold,
       success_threshold: state.rule.success_threshold
     }, state}
  end

  @impl true
  def handle_cast(:check, state), do: {:noreply, start_check(state)}

  # Re-read the rule and judge what we have already seen against it, rather than
  # waiting for the next probe. A restart used to discard the failure and
  # success tallies and start counting again from zero, so a threshold lowered
  # to 1 still needed a fresh probe to bite. Applying it to the counts already
  # taken makes the change take effect immediately and keeps the information.
  def handle_cast(:rule_changed, state) do
    rule = Monitoring.rule_for_monitoring(state.service)
    machine = StatusMachine.reapply(state.machine, state.last_check_status, rule)
    state = %{state | rule: rule}

    if machine.status == state.machine.status do
      {:noreply, %{state | machine: machine}}
    else
      {:noreply, transition(state, machine, state.last_error)}
    end
  end

  @impl true
  def handle_info(:check, state), do: {:noreply, start_check(state)}

  # The probe reported back.
  def handle_info({ref, outcome}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    cancel_timer(state.timeout_ref)

    state = %{state | task: nil, timeout_ref: nil}

    case record(state, outcome) do
      {:ok, state} -> {:noreply, schedule_check(state, :regular)}
      # The service is gone, so there is nothing left to probe. A normal stop
      # does not count as an abnormal termination, so the supervisor leaves the
      # monitor dead instead of restarting it into a boot-probe crash loop.
      {:stop, state} -> {:stop, :normal, state}
    end
  end

  # The probe process died without reporting. async_nolink means this reaches us
  # as a message rather than killing the monitor.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    cancel_timer(state.timeout_ref)

    outcome = {:error, %Result{error: "health check crashed: #{inspect(reason)}"}}
    state = %{state | task: nil, timeout_ref: nil}

    case record(state, outcome) do
      {:ok, state} -> {:noreply, schedule_check(state, :regular)}
      {:stop, state} -> {:stop, :normal, state}
    end
  end

  # The probe overran even its own timeout. Req should have given up already, so
  # this is the backstop for a task wedged somewhere else.
  def handle_info({:check_timeout, ref}, %{task: %Task{ref: ref} = task} = state) do
    Task.Supervisor.terminate_child(PulseOps.Monitoring.TaskSupervisor, task.pid)
    Process.demonitor(ref, [:flush])

    outcome = {:error, %Result{error: "health check timed out"}}
    state = %{state | task: nil, timeout_ref: nil}

    case record(state, outcome) do
      {:ok, state} -> {:noreply, schedule_check(state, :regular)}
      {:stop, state} -> {:stop, :normal, state}
    end
  end

  # Late messages from a probe we already gave up on. The two-tuple clause also
  # covers stale {:check_timeout, ref} messages.
  def handle_info({_ref, _outcome}, state), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.timer_ref)
    cancel_timer(state.timeout_ref)
    :ok
  end

  ## Probing

  # A probe is already in flight. Skipping keeps at most one request per service
  # outstanding, so a slow endpoint cannot pile up requests against itself.
  defp start_check(%{task: %Task{}} = state), do: state

  defp start_check(state) do
    %{url: url, timeout_ms: timeout_ms} = state.service
    client = HealthCheck.client()
    opts = check_options(state.service)

    task =
      Task.Supervisor.async_nolink(PulseOps.Monitoring.TaskSupervisor, fn ->
        client.check(url, opts)
      end)

    timeout_ref =
      Process.send_after(self(), {:check_timeout, task.ref}, timeout_ms + @task_grace_ms)

    %{state | task: task, timeout_ref: timeout_ref}
  end

  # How this particular service wants to be probed. Built here, in the monitor,
  # so the HTTP client stays a plain function of a URL and options and never
  # learns what a Service is.
  defp check_options(%Service{} = service) do
    [
      timeout_ms: service.timeout_ms,
      method: service.http_method,
      headers: Map.to_list(service.request_headers || %{}),
      body: service.request_body,
      expected_status: service.expected_status,
      body_assertion: service.body_assertion
    ]
  end

  ## State machine

  defp record(state, outcome) do
    {result, healthy?} =
      case outcome do
        {:ok, %Result{} = result} -> {result, true}
        {:error, %Result{} = result} -> {result, false}
      end

    check_status =
      StatusMachine.classify(
        healthy?,
        result.response_time_ms,
        state.service.timeout_ms,
        state.rule
      )

    machine = StatusMachine.advance(state.machine, check_status, state.rule)
    state = %{state | last_check_status: check_status, last_error: result.error}

    :telemetry.execute(
      [:pulse_ops, :monitoring, :check],
      %{response_time_ms: result.response_time_ms || 0},
      %{service_id: state.service.id, status: check_status}
    )

    case Monitoring.record_check(state.service, check_status, result) do
      {:ok, _check} ->
        if machine.status == state.machine.status do
          # No transition to hang the incident hook on, so this is the only
          # chance to notice that the incident state no longer matches reality —
          # most importantly a service still down whose incident somebody
          # resolved by hand (ADR-009).
          Incidents.reconcile_incident(state.service, machine.status, state.rule)
          {:ok, %{state | machine: machine}}
        else
          {:ok, transition(state, machine, result.error)}
        end

      # No point recording a status for a service that no longer exists: tell the
      # caller to stop the monitor instead (see record_check/3).
      {:error, :service_not_found} ->
        {:stop, state}
    end
  end

  defp transition(state, %StatusMachine{status: next_status} = machine, reason) do
    previous = state.machine.status

    Logger.info("service status changed",
      service_id: state.service.id,
      organization_id: state.service.organization_id,
      service_status_from: previous,
      service_status_to: next_status
    )

    service = Monitoring.update_service_status(state.service, next_status)

    # Every status change passes through here, which makes it the one place the
    # incident lifecycle has to hook into.
    case {previous, next_status} do
      {_previous, :down} -> Incidents.open_incident(service, state.rule, reason)
      {:down, _recovered} -> Incidents.resolve_open_incident(service)
      {_previous, _next} -> :ok
    end

    %{state | service: service, machine: machine}
  end

  ## Scheduling

  defp schedule_check(state, kind) do
    cancel_timer(state.timer_ref)

    delay =
      case kind do
        :initial -> :rand.uniform(1_000)
        :regular -> with_jitter(state.service.check_interval_ms)
      end

    %{state | timer_ref: Process.send_after(self(), :check, delay)}
  end

  defp with_jitter(interval) do
    spread = trunc(interval * @jitter_ratio)
    interval - spread + :rand.uniform(2 * spread + 1) - 1
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)
end
