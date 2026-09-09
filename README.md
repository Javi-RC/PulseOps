# PulseOps

Real-time monitoring and incident management for distributed services, built with
Elixir, Phoenix LiveView and OTP.

PulseOps watches each registered service from its own supervised process, decides
when a service is genuinely down rather than briefly flaky, opens and resolves
incidents on its own, and pushes every state change to connected dashboards over
WebSockets. Nothing polls — the dashboard coalesces a burst of changes into one
refresh a quarter of a second later, so a flapping service costs one reload
rather than one per change.

## What it does

- **Register services** — a name, a URL, how often to probe it and how long to wait.
- **Watch them live** — a dashboard of every service with its recent history,
  24-hour availability and the incidents currently open. It updates over a
  WebSocket as the monitors see things change; nothing on the page polls.
- **Read the detail** — response time over the recent checks, p50/p95/p99, uptime,
  and the full list of probes behind the chart.
- **Work through incidents** — opened and resolved automatically, with a timeline
  that distinguishes what a monitor saw from what a person did. You move them
  through the workflow and record the root cause.
- **Alert on your terms** — each service, or the whole organization, has an alert
  rule: how many failed probes open an incident, how many successes close it, and
  the severity it is reported as.
- **Never miss an incident** — a generic webhook (Discord, Teams, ntfy, Make…) or
  an email to your team, each per-organization and optionally narrowed to a single
  service, with its own queue and retry budget, so a slow receiver never slows the
  monitor that spotted the incident.
- **Share an organization** — invite people, give them one of four roles
  (owner, admin, member, viewer) and change them later. Authorization is enforced
  in the domain layer, not by hiding buttons.

## Resuming development

Start here, in this order:

1. [`docs/PROGRESS.md`](docs/PROGRESS.md) — current state, what is done, what is next.
2. [`docs/ROADMAP.md`](docs/ROADMAP.md) — audited defects, priorities and the phased plan.
3. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — supervision tree, data model, PubSub topics.
4. [`docs/DECISIONS.md`](docs/DECISIONS.md) — why the design looks the way it does.

## Running it

Everything runs in Docker; no Elixir installation is required on the host.

```bash
cp .env.example .env                      # optional; the compose file reads .env
docker compose build
docker compose run --rm web mix deps.get
docker compose run --rm web mix ecto.setup   # migrates and seeds demo data
docker compose up web
```

Without `.env` Docker Compose refuses to start, so create it from
`.env.example` first. With `BREVO_API_KEY` set, incident emails are actually
sent through Brevo; without it they land in the development mailbox at
`/dev/mailbox`.

The app is served at http://localhost:4000. Register an account, or log in as the
seeded `demo@pulseops.test` — magic-link emails are captured at `/dev/mailbox`.

Every `mix` command goes through the container:

```bash
docker compose run --rm web mix test
docker compose run --rm web mix check     # format + compile + credo + test + dialyzer
docker compose run --rm web iex -S mix
```

## Seeing an incident happen

The seeds create a service pointed at a local endpoint whose behaviour can be
changed at runtime, so an outage can be produced on demand rather than waited for:

```bash
curl -X POST http://localhost:4000/dev/flaky/break   # API Gateway starts failing
curl -X POST http://localhost:4000/dev/flaky/heal    # and recovers
```

Open the dashboard in two browser windows first. After three failed checks the
service turns red and an incident appears — in both windows, with no reload and
no HTTP requests. The Network tab shows only WebSocket traffic. Healing the
endpoint resolves the incident automatically two checks later.

## How it works

Health checks are driven by long-lived processes, not by requests. The web layer
only reads state and listens for changes.

```
PulseOps.Application
├── PulseOps.Repo
├── Phoenix.PubSub
├── PulseOps.Monitoring.Supervisor        (:one_for_one)
│   ├── Registry                          (:unique — a monitor is found by service id)
│   ├── Task.Supervisor                   (runs the HTTP probes)
│   ├── MonitorSupervisor                 (DynamicSupervisor — one child per service)
│   └── Bootstrapper                      (starts a monitor per enabled service at boot)
└── PulseOpsWeb.Endpoint
```

```
Process.send_after(self(), :check, interval ± 10% jitter)
        │
        ▼
Task.Supervisor.async_nolink  ──►  HealthCheck.Req  ──►  {:ok, Result} | {:error, Result}
        │                                                        │
        └──────────────── handle_info({ref, result}) ◄───────────┘
                                  │
                   update failure/success counters
                                  │
                    ┌─────────────┴─────────────┐
              status changed?               unchanged
                    │                           │
        persist check + service status     persist check only
        open/resolve incident
        broadcast to PubSub  ──►  LiveView  ──►  DOM
```

The decisions worth knowing about, all argued in [`docs/DECISIONS.md`](docs/DECISIONS.md):

- **The probe never runs inside the GenServer callback.** A monitor has one
  mailbox; a synchronous request with a 5 s timeout would block it for 5 s — it
  could not answer a call, be reconfigured, or shut down cleanly. The request goes
  through `Task.Supervisor.async_nolink/2` and reports back as a message, which
  also means a crash inside the request cannot take the monitor down.
- **Jittered scheduling**, so monitors that started together do not settle into
  lockstep and hit shared infrastructure in bursts.
- **Alert rules, not hardcoded thresholds.** A service or the organization sets
  how many failed probes open an incident and how many successes close it, plus
  the severity. The default remains three failures to go down and two successes
  to recover, and the rules reach running monitors by restarting the ones that
  read them.
- **A partial unique index** — `incidents (service_id) WHERE resolved_at IS NULL` —
  makes "at most one open incident per service" a database guarantee rather than an
  application convention, so two racing monitors produce one insert and one no-op.
- **Monitors reconcile incidents at startup**, not only on transitions: restarting
  while a service was already down otherwise left the outage with no incident.
- **One PubSub topic per organization, and broadcasts only on state change.** A
  per-service topic would mean N subscriptions per connected client, and pushing
  every "still healthy" probe would re-render every open dashboard for nothing.
- **Tenancy through Phoenix scopes**, so the organization filter lives in every
  context function instead of being something to remember.

## Testing

```bash
docker compose run --rm web mix check
```

The HTTP client is a behaviour resolved at call time, so tests drive a service
from healthy through down and back without a network. Monitors do not start
themselves in the test environment — they would issue real requests and check out
connections outside the Ecto sandbox.

The test that carries the argument of the whole project kills a monitor with
`Process.exit(pid, :kill)` and asserts that the supervisor replaces it *and* that
every other monitor keeps running.

## Stack

Elixir · Phoenix · Phoenix LiveView · OTP (GenServer, Supervisor, DynamicSupervisor,
Registry, Task.Supervisor) · Phoenix PubSub · Ecto · PostgreSQL · Telemetry ·
Docker · ExUnit · Mox · Credo · Dialyzer · GitHub Actions

## Not built yet

Slack (the generic webhook channel already speaks its format, but an official
Slack app/bolt integration is not built), metric rollups, an activity log,
clustering with leader election, and Prometheus/Grafana export. The groundwork is
in place: `:telemetry` already emits per-check events, Oban runs nightly
retention jobs, and the partial unique index is what will make clustering safe.
