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

## Deploying it

`Dockerfile` builds a production image: a `mix release` on a runtime that has no
Mix, no build tools and no source in it, running as a non-root user.

```bash
docker build -t pulseops:latest .

# Migrations are their own step. A container that migrates on boot races every
# other replica starting at the same moment.
docker run --rm --env-file prod.env pulseops:latest /app/bin/migrate
docker run -d -p 4000:4000 --env-file prod.env pulseops:latest
```

Required environment:

| | |
|---|---|
| `SECRET_KEY_BASE` | signs cookies and tokens; `mix phx.gen.secret` |
| `DATABASE_URL` | `ecto://user:pass@host/database` |
| `PHX_HOST` | the hostname this installation answers at |

`PHX_HOST` has **no default**. It ends up in every link PulseOps generates —
magic-link logins, and the incident URLs in webhook and email notifications — so
a wrong one produces links that silently go nowhere. The release refuses to boot
without it.

Optional: `PORT` (4000), `POOL_SIZE` (10), `DATABASE_SSL` (`true`; set `false`
only for a database on a private network that does not speak TLS),
`METRICS_TOKEN`, `BREVO_API_KEY` with `MAILER_FROM` and `MAILER_FROM_NAME`,
`DNS_CLUSTER_QUERY`, `ECTO_IPV6`.

HTTP is redirected to HTTPS with HSTS, trusting `x-forwarded-proto`, so put it
behind a proxy or load balancer that terminates TLS.

Sign-in, magic-link and registration attempts are always limited per email. Set
`TRUSTED_PROXY=true` to limit them per client address as well — **only** if every
request goes through that proxy, it appends the client address to
`X-Forwarded-For`, and the app cannot be reached any other way. Otherwise the
header is whatever the client sent, and trusting it would let anyone claim a
fresh address for every attempt.

**One node only.** Every node starts a monitor for every enabled service, so a
second replica duplicates probes, checks and notifications. The partial unique
index keeps incidents from being duplicated and protects nothing else. Do not
scale by replicas until there is leader election.

## Certificate expiry

Every `https` service's certificate is read once a day and its expiry stored. A
certificate inside the warning window is announced once — and again if a renewal
later runs low — without opening an incident, because the service is up and this
needs a calendar entry rather than a page.

## Notifications that stay signal

A service oscillating on its threshold sends **one** message saying how often it
moved, not one per crossing. A critical incident that nobody acknowledges within
the escalation window reaches the channels marked "only for escalations", which
stay silent the rest of the time.

Acknowledging an incident is separate from moving it to *investigating*: it says
somebody has this, which is what stops the escalation.

## Maintenance windows

Schedule a window before a deploy and PulseOps stops paging for it. The probes
keep running and the history stays honest — the status still changes, the uptime
figures still count it — but no incident opens, and the status page tells your
customers it was planned.

Nothing has to be turned back on: when the window ends with the service still
broken, the next check opens an incident.

## Inviting people

Adding somebody on the members page adds them straight away if they already have
an account, and emails them an invitation if they do not. The link works once,
lasts a week, and creates their account when they accept — so a colleague needs
nothing but the email.

## JSON API

Services and incidents are readable and writable over HTTP at `/api/v1`, with an
organization token minted in **Settings → API tokens**:

```bash
curl -H "Authorization: Bearer $TOKEN" https://your-host/api/v1/services
curl -H "Authorization: Bearer $TOKEN" -X POST   https://your-host/api/v1/incidents/42/resolve -d '{"cause":"restarted the pool"}'
```

A token acts as the person who created it and takes its role from their
membership on every request, so it can never do more than they can and stops
working when they leave the organization. Only a hash is stored — the token is
shown once and cannot be recovered, only replaced.

## Configurable checks

A service says how it wants to be probed — GET, HEAD or POST, with headers and a
body — and what counts as healthy. `expected_status` accepts an exact code, so an
endpoint whose healthy answer is a `204`, or one that proves it is alive by
answering `401`, can be watched. `body_assertion` requires a string in the
response, which is the only way to catch a service that is up, answering `200`,
and saying in its payload that its database is gone.

Everything defaults to the previous behaviour: a `GET` that accepts any 2xx.

## Public status page

An organization can publish a page at `/status/:slug` that anyone can read
without an account, updating live over the same WebSocket the dashboard uses.
Service names, statuses and uptime appear on it; service URLs, incident causes
and timelines never do, and an organization that has not published is
indistinguishable from one that does not exist. Turn it on in organization
settings, and exclude individual services with their "Show on the status page"
checkbox.

## Metrics

PulseOps exposes its own health to Prometheus at `/metrics`, behind a bearer
token — set `METRICS_TOKEN` to enable it, and without one the endpoint returns
404 rather than advertising itself. The series describe *PulseOps*: probe
volumes and response times, Oban job outcomes, request and query latency. They
carry no `service_id` label, because per-service figures live in the database
and a label per tenant's service is how a Prometheus server falls over.

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
