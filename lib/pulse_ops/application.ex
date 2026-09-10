defmodule PulseOps.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PulseOpsWeb.Telemetry,
      PulseOps.Repo,
      {DNSCluster, query: Application.get_env(:pulse_ops, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PulseOps.PubSub},
      # Needs the Repo and PubSub above it: monitors read services on boot and
      # broadcast status changes.
      PulseOps.Monitoring.Supervisor,
      # Housekeeping jobs: check retention and expired token purge. Reads its
      # config from the app env so tests and dev can swap the queue settings.
      {Oban, Application.fetch_env!(:pulse_ops, Oban)},
      # Owns the counters that slow down login, magic-link and registration
      # attempts. Before the endpoint, so the table exists by the first request.
      PulseOpsWeb.RateLimiter,
      # Start to serve requests, typically the last entry
      PulseOpsWeb.Endpoint
    ]

    children =
      if Application.get_env(:pulse_ops, :dev_routes),
        do: children ++ [PulseOpsWeb.Flaky],
        else: children

    # A job queue that fails silently is how incident notifications stop
    # arriving with nobody noticing. Oban emits the telemetry; this is what
    # turns it into a log line.
    _ = Oban.Telemetry.attach_default_logger(level: :info)

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PulseOps.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PulseOpsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
