# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :pulse_ops, :scopes,
  user: [
    default: true,
    module: PulseOps.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: PulseOps.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ],
  # Tenant scope. Generators reading this entry give every scoped resource an
  # organization_id and nest its routes under /orgs/:org. It has to exist before
  # running any `mix phx.gen.* --scope organization`.
  organization: [
    module: PulseOps.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:organization, :id],
    route_prefix: "/orgs/:org",
    route_access_path: [:organization, :slug],
    schema_key: :organization_id,
    schema_type: :id,
    schema_table: :organizations,
    test_data_fixture: PulseOps.OrganizationsFixtures,
    test_setup_helper: :register_and_log_in_user_with_org
  ]

config :pulse_ops,
  ecto_repos: [PulseOps.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :pulse_ops, PulseOpsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PulseOpsWeb.ErrorHTML, json: PulseOpsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PulseOps.PubSub,
  live_view: [signing_salt: "0QVbCJWP"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :pulse_ops, PulseOps.Mailer,
  adapter: Swoosh.Adapters.Local,
  from: "contact@example.com",
  from_name: "PulseOps"

config :pulse_ops, PulseOps.Notifications.Mailer,
  adapter: Swoosh.Adapters.Local,
  from: "contact@example.com",
  from_name: "PulseOps"

# Configure Oban, the job queue. Housekeeping jobs (check retention, expired
# token purge) and notification deliveries run on the default queue. Tests
# disable the queues and drive jobs through `Oban.Testing`.
config :pulse_ops, Oban,
  repo: PulseOps.Repo,
  queues: [default: 10],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"@daily", PulseOps.Monitoring.RetentionJob},
       {"@daily", PulseOps.Accounts.PurgeExpiredTokensJob},
       # A few minutes past the hour, so the hour it rolls up is finished and
       # no checks are still landing in it.
       {"5 * * * *", PulseOps.Monitoring.RollupJob}
     ]}
  ]

# Data retention. `checks_retention_days` is the window for raw `service_checks`
# rows — anything older is deleted nightly by `PulseOps.Monitoring.RetentionJob`.
config :pulse_ops, :retention, checks_retention_days: 30

# How long a manual resolution suppresses reconciliation. Closing an incident by
# hand on a service that has not recovered means "snooze this outage", so the
# monitor waits this long before reopening it (see ADR-009). A real transition
# back to :down is never suppressed — only the reconciliation path is.
config :pulse_ops, :incident_reopen_grace_seconds, 300

# How long the dashboard waits before re-reading its summary after a broadcast.
# Every message that lands inside the window is absorbed by the reload already
# pending, so a flapping service costs one reload rather than one per change.
# The cost is up to this much latency on a status appearing.
config :pulse_ops, :dashboard_debounce_ms, 250

# Whether tenants may point a service or a webhook at a private, loopback or
# link-local address. False here so production is safe by default; development
# and test turn it on, because localhost is what they watch. See
# `PulseOps.Monitoring.UrlGuard` — an installation that legitimately monitors a
# private network sets this to true.
config :pulse_ops, :allow_private_targets, false

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  pulse_ops: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  pulse_ops: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
# The domain identifiers are logged as metadata rather than interpolated into
# the message, so a log aggregator can filter on them instead of parsing prose.
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :service_id,
    :organization_id,
    :service_status_from,
    :service_status_to,
    :incident_id
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
