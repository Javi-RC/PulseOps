# Architecture

Target design for the MVP. Sections marked *planned* are not built yet — check
[`PROGRESS.md`](PROGRESS.md) for what actually exists.

## Shape of the system

```
Browser (LiveView)
      │  WebSocket
Phoenix Endpoint
      │
      ├── LiveViews ──────── subscribe ──┐
      │                                  │
      └── Contexts                  Phoenix.PubSub
             │                            ▲
             │                            │ broadcast on state change
             ▼                            │
          Postgres  ◄──── writes ──── ServiceMonitor processes
```

Health checks are driven by long-lived processes, not by requests. The web layer
only reads state and listens for changes.

## Supervision tree

```
PulseOps.Application
├── PulseOps.Repo
├── Phoenix.PubSub
├── PulseOpsWeb.Telemetry
├── PulseOps.Monitoring.Supervisor        (:one_for_one)
│   ├── Registry                          (:unique — locates a monitor by service id)
│   ├── Task.Supervisor                   (runs the HTTP requests)
│   ├── MonitorSupervisor                 (DynamicSupervisor — one child per service)
│   └── Bootstrapper                      (starts a monitor per enabled service at boot)
├── Oban                                  (job queue — cron hourly rollups and nightly retention, incident notification deliveries)
└── PulseOpsWeb.Endpoint
```

Each `ServiceMonitor` is registered as `{:via, Registry, {PulseOps.Monitoring.Registry,
{:monitor, service_id}}}`, so it can be found, restarted or stopped by service id.

Monitors are `restart: :transient` under a `DynamicSupervisor` with bounded
`max_restarts`. A monitor whose endpoint makes it crash repeatedly is given up on
without affecting any other monitor — fault isolation is the point of the design.

A monitor reads its alert rule at boot, and the context restarts every monitor
whose rule changed so the new thresholds reach them. If the service row
disappears under a running monitor (a delete racing an in-flight probe), the
failed insert tells the monitor to stop cleanly rather than be restarted into a
boot-probe crash loop.

Incidents open and close on a status *transition*, but a transition is not the
only thing that can put the incident state out of step with reality — resolving
one by hand on a service that has not recovered does it too. So a monitor also
reconciles after every probe that produced no transition, not only at boot. See
ADR-008 and ADR-009.

### Check cycle

```
Process.send_after(self(), :check, interval ± 10% jitter)
        │
        ▼
Task.Supervisor.async_nolink  ──►  HealthCheck.Req  ──►  {:ok, Result} | {:error, reason}
        │                                                        │
        └──────────────── handle_info({ref, result}) ◄───────────┘
                                  │
                   update failure/success counters
                                  │
                    ┌─────────────┴─────────────┐
              status changed?               unchanged
                    │                           │
        persist check + service status     persist check only
        open/resolve incident              reconcile incident state
        broadcast to PubSub
```

The jitter keeps monitors from synchronising into a thundering herd after a mass
restart. See ADR-002 for why the request is not made inline.

## Data model

```
organizations ──┬── organization_members ──── users
                ├── alert_rules               (org default or per-service override)
                ├── notifiers                 (webhook URL or email per organization)
                └── services ──┬── service_checks ──── service_check_rollups
                               └── incidents ──── incident_events
```

- `services` — name, description, environment, url, `check_interval_ms`,
  `timeout_ms`, `enabled`, current `status`, `last_checked_at`.
- `alert_rules` — failure/success thresholds and a severity for incident handling;
  `service_id` null is the organization default, otherwise it overrides one
  service. Monitors read their rule on boot, so changing a rule restarts every
  monitor that reads it. Two unique indexes hold the shape: one on `service_id`
  for per-service rules, and a partial one on `organization_id` where
  `service_id IS NULL` for the default — Postgres treats NULLs as distinct, so
  the first does not cover the second. A rule's `service_id` is validated
  against the tenant, or it could take another organization's slot.
- `service_checks` — one row per probe: status, http status, response time, error.
  By far the fastest-growing table in the schema. Indexed on
  `(service_id, inserted_at)`, which serves every read — they are all "the latest
  checks for one service" — and separately on `(inserted_at)`, which the nightly
  retention delete needs and a composite index cannot provide. That delete runs
  in bounded batches.
- `service_check_rollups` — one row per service per hour: status counts plus a
  cumulative latency histogram. The dashboard and the service metrics read these
  for every complete hour and only the current hour from raw checks, so the cost
  of a page is bounded by hours rather than by probe frequency or by the
  retention window. Counts merge by addition; the histogram is what makes
  percentiles merge too. See ADR-010.
- `incidents` — severity, status (`open` → `investigating` → `identified` →
  `monitoring` → `resolved`), cause, started/resolved timestamps, resolver.
  A partial unique index enforces at most one unresolved incident per service
  (ADR-004), which is also what makes reopening cheap: a reopened outage is a new
  row, not a revived one. Resolving by hand on a service that has not recovered
  suppresses reconciliation for a grace period, so it reads as a snooze rather
  than being undone on the next probe (ADR-009).
- `incident_events` — the timeline; `user_id` is null for automatic events.
- `notifiers` — where an organization is told about incidents: a `:webhook` (URL +
  optional bearer `secret_token`) or an `:email`, with `enabled` to pause without
  deleting. A notifier is `:organization`-scoped and may be narrowed to a single
  `service_id` (nil = any incident in the organization). Email notifiers reach the
  organization users linked through `notifier_assignments`, one copy each; for
  webhooks the assignments record who is responsible for the channel. When an
  incident opens or resolves, `PulseOps.Notifications` queues one `NotifyJob` per
  matching enabled notifier; a slow receiver never blocks the monitor.

## Outbound requests

Both the health checks and the webhook deliveries fetch a URL a tenant typed into
a form, from inside the network PulseOps runs in. `PulseOps.Monitoring.UrlGuard`
checks the scheme and resolves the host, rejecting loopback, private, link-local
and the other non-routable ranges, in IPv4 and IPv6 alike.

It runs twice: once in the changeset, and again immediately before each request.
Validating only on save would leave the door open to a name repointed at a
private address afterwards, and the check interval keeps that window open for as
long as the service exists.

`config :pulse_ops, :allow_private_targets` turns the address check off, because
watching a private network is a legitimate deployment. It is true in development
and test, false in production. The scheme check applies either way.

## Tenancy

`PulseOps.Accounts.Scope` holds `user`, `organization` and `role`, and is assigned as
`current_scope` on both `conn` and `socket`. Routes are prefixed `/orgs/:org` and
resolved by slug; `on_mount :require_organization` loads the organization, verifies
membership, and puts it on the scope. Every context function takes the scope and
filters by `scope.organization.id`. See ADR-001.

Roles: `owner` and `admin` may write, `member` may act on incidents, `viewer` is
read-only. Authorization is enforced in the contexts, not by hiding buttons.

## PubSub topics

| Topic | Carries | Subscribed by |
|---|---|---|
| `organization:{id}:services` | service status transitions | dashboard |
| `organization:{id}:incidents` | incident opened / changed / resolved | dashboard, incident list |
| `service:{id}:checks` | every individual check result | service detail page only |

See ADR-003.

A broadcast is a signal that something changed, not the change itself: a page
re-reads from the database rather than patching its assigns from the payload, so
two racing changes cannot leave it out of step. The dashboard defers that re-read
briefly and coalesces everything arriving inside the window into one reload,
because its summary costs four queries and a flapping service would otherwise pay
for all of them per viewer, per change.

## Testing seams

The HTTP client is a behaviour, `PulseOps.Monitoring.HealthCheck`, resolved through
application config. Tests swap in a Mox mock; development and production use
`HealthCheck.Req`. A `/dev/flaky` endpoint whose response is toggled at runtime lets
an incident be triggered on demand during a demo.

Webhook deliveries share the same idea: `config :pulse_ops, webhook_client: :stub`
routes them through a `Req.Test` plug in tests so nothing touches the network, while
every other environment delivers over the wire. Email uses Swoosh's Test adapter in
tests; `BREVO_API_KEY` at runtime switches production and development to Brevo.
