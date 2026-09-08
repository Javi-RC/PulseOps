import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :pulse_ops, PulseOps.Repo,
  username: System.get_env("DATABASE_USER", "postgres"),
  password: System.get_env("DATABASE_PASSWORD", "postgres"),
  hostname: System.get_env("DATABASE_HOST", "db"),
  database: "pulse_ops_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :pulse_ops, PulseOpsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "CeTRnmD03dgDX2hiOEOK8gRrHu0IfvzW25sQx7zZK0DbMrOWKSnj4QQ8tTX0cKDs",
  server: false

# In test we don't send emails
config :pulse_ops, PulseOps.Mailer, adapter: Swoosh.Adapters.Test
config :pulse_ops, PulseOps.Notifications.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Monitors must never start on their own in tests: they would perform real HTTP
# requests and check out database connections outside the Ecto sandbox. Tests
# that need one start it explicitly and call Sandbox.allow/3 for it.
config :pulse_ops, start_monitors: false

# Probes go through a Mox mock, so tests can drive a service from healthy to
# down and back without touching the network.
config :pulse_ops, health_check_client: PulseOps.Monitoring.HealthCheckMock

# Oban boots like in any environment (so job workers resolve their config), but
# queues and cron never start during the suite — jobs run manually through
# `Oban.Testing.perform_job/2`.
config :pulse_ops, Oban, queues: false, plugins: false, testing: :manual

# Route every webhook delivery through the Req.Test stub so nothing touches the network.
config :pulse_ops, webhook_client: :stub
