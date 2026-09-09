defmodule PulseOpsWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  @prometheus_reporter :pulse_ops_prometheus

  @doc """
  Name of the Prometheus reporter, for `/metrics` to scrape.
  """
  def prometheus_reporter, do: @prometheus_reporter

  @doc """
  Current metrics in the Prometheus text exposition format.
  """
  def scrape, do: TelemetryMetricsPrometheus.Core.scrape(@prometheus_reporter)

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      # Keeps the Prometheus-shaped metrics in an ETS table for /metrics to
      # scrape. Separate from metrics/0, which feeds LiveDashboard: the two
      # reporters want different shapes, and a Prometheus histogram needs
      # explicit buckets that LiveDashboard has no use for.
      {TelemetryMetricsPrometheus.Core, metrics: prometheus_metrics(), name: @prometheus_reporter}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Metrics exported to Prometheus at `/metrics`.

  These describe **PulseOps itself** — how its own probes, jobs and queries are
  behaving — not the services it watches. Per-service uptime and latency already
  live in the database and on the dashboard, and putting a `service_id` label on
  a metric would make its cardinality grow with every tenant's every service,
  which is the standard way to make a Prometheus server fall over.
  """
  def prometheus_metrics do
    [
      # The monitoring loop. This event was emitted and heard by nobody.
      counter("pulse_ops.monitoring.check.count",
        event_name: [:pulse_ops, :monitoring, :check],
        measurement: :response_time_ms,
        tags: [:status],
        description: "Health check probes completed, by resulting status"
      ),
      distribution("pulse_ops.monitoring.check.response_time_ms",
        event_name: [:pulse_ops, :monitoring, :check],
        measurement: :response_time_ms,
        tags: [:status],
        reporter_options: [buckets: [25, 50, 100, 250, 500, 1_000, 2_500, 5_000]],
        description: "Probe response time in milliseconds"
      ),

      # Background jobs: a silently failing job queue is how notifications stop
      # arriving without anyone noticing.
      counter("oban.job.stop.duration",
        event_name: [:oban, :job, :stop],
        tags: [:worker, :state],
        description: "Oban jobs that finished, by worker and outcome"
      ),
      counter("oban.job.exception.duration",
        event_name: [:oban, :job, :exception],
        tags: [:worker, :state],
        description: "Oban jobs that raised, by worker"
      ),
      distribution("oban.job.stop.queue_time",
        event_name: [:oban, :job, :stop],
        measurement: :queue_time,
        unit: {:native, :millisecond},
        tags: [:worker],
        reporter_options: [buckets: [10, 100, 1_000, 10_000, 60_000]],
        description: "How long a job waited before running"
      ),

      # The web and database layers.
      distribution("phoenix.router_dispatch.stop.duration",
        unit: {:native, :millisecond},
        tags: [:route],
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1_000]],
        description: "Request duration by route"
      ),
      distribution("pulse_ops.repo.query.total_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 50, 100, 500, 1_000]],
        description: "Database query time"
      ),
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
      last_value("vm.total_run_queue_lengths.total")
    ]
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("pulse_ops.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("pulse_ops.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("pulse_ops.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("pulse_ops.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("pulse_ops.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {PulseOpsWeb, :count_users, []}
    ]
  end
end
