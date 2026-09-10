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
│   ├── MonitorSupervisor                 (DynamicSupervisor — one temporary container per service)
│   │   └── MonitorContainer              (Supervisor — this service's own restart budget)
│   │       └── ServiceMonitor            (transient, significant)
│   └── Bootstrapper                      (starts a monitor per enabled service at boot)
├── Oban                                  (job queue — cron hourly rollups and nightly retention, incident notification deliveries)
└── PulseOpsWeb.Endpoint
```

Each `ServiceMonitor` is registered as `{:via, Registry, {PulseOps.Monitoring.Registry,
{:monitor, service_id}}}`, and its container as `{:container, service_id}`, so
both can be found, restarted or stopped by service id.

**Restart budgets are per service** (ADR-017). Restart intensity belongs to a
supervisor, not to a child, so a budget shared by every monitor is not a budget
per monitor: before F10 was fixed, one monitor crashing six times in a minute
terminated the shared `DynamicSupervisor` with every monitor under it, and
nothing started them again. Each monitor now sits alone in a `MonitorContainer`
with `max_restarts: 5, max_seconds: 60`. When a monitor exceeds that, only its
container exits. Containers are `:temporary` under `MonitorSupervisor`, so a
container that gave up stays down and is never counted against the shared
supervisor. The monitor is a *significant* child with `auto_shutdown:
:any_significant`, so a monitor that stops normally — its service row is gone —
takes its container with it rather than leaving an empty one holding the name.

A service that has been given up on is not silent. An enabled service with no
container says "Nothing is watching this service" on its page
(`Monitoring.monitor_state/1`), instead of showing its last recorded status as
though it were current. The state is read from the container, not the monitor,
so a monitor that is mid-restart inside its budget still counts as watched.

A monitor reads its alert rule at boot, and the context casts to every monitor
whose rule changed so each re-reads it in its own process — the new thresholds
are applied to the failure and success counts already taken, so a change takes
effect immediately rather than at the next probe. If the service row
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

A probe is not always `GET` and a status line is not always the whole story. A
service says how it wants to be reached — method, headers, body — and what
counts as healthy: an exact status, so an endpoint whose healthy answer is `204`
or `401` can be watched, and a string that must appear in the response, which is
the only way to catch a service that is up, answering `200`, and saying in its
payload that its database is gone. The monitor builds those options and the HTTP
client stays a function of a URL and a keyword list, never learning what a
`Service` is.

A maintenance window suppresses the *consequence* of a failure, not the
monitoring of it: probes still run, checks are still recorded and the status
still changes, but no incident opens, so a planned deploy pages nobody. The check
sits in `Incidents`, in the one function both paths into an incident go
through — the transition hook and reconciliation — because suppressing only the
transition would let a service that was already down get an incident from the
next reconciliation. Nothing schedules the end of the silence: when the window
finishes with the service still broken, the next probe reconciles and opens one
then. See ADR-014.

Deciding *what the status is* is not part of the monitor. `StatusMachine` is a
pure module — no processes, no database, no clock — that folds probe verdicts
into a status under the rule's thresholds. The monitor owns the I/O and the
scheduling and asks it. The interesting behaviour there is hysteresis, whose
bugs only appear over sequences, and sequences are expensive to explore through
a GenServer and cheap to explore through a function.

## Data model

```
organizations ──┬── organization_members ──── users
                ├── alert_rules               (org default or per-service override)
                ├── notifiers                 (webhook URL or email per organization)
                ├── api_tokens                (hashed; acts as the user who made it)
                ├── organization_invitations  (hashed; single use, expires)
                ├── maintenance_windows       (org-wide or one service; suppresses incidents)
                └── services ──┬── service_checks ──── service_check_rollups
                               └── incidents ──── incident_events
```

- `services` — certificate expiry is watched daily for `https` ones and warned
  about once per expiry, without opening an incident: the service is up, and a
  certificate running out needs a calendar entry rather than a page (ADR-016).
- `services` — name, description, environment, url, `check_interval_ms`,
  `timeout_ms`, `enabled`, `public`, current `status`, `last_checked_at`, plus
  how to make the request: `http_method`, `request_headers`, `request_body`,
  and what counts as healthy — `expected_status` (null means any 2xx) and
  `body_assertion` (null means the body is not read).
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
  `acknowledged_at` on the incident is deliberately not a workflow status:
  `:investigating` says something about the incident, acknowledging says
  somebody has it, and in the first minute both are true (ADR-015).
- `notifiers` — where an organization is told about incidents: a `:webhook` (URL +
  optional bearer `secret_token`) or an `:email`, with `enabled` to pause without
  deleting. A notifier is `:organization`-scoped and may be narrowed to a single
  `service_id` (nil = any incident in the organization). Email notifiers reach the
  organization users linked through `notifier_assignments`, one copy each; for
  webhooks the assignments record who is responsible for the channel. When an
  incident opens or resolves, `PulseOps.Notifications` queues one `NotifyJob` per
  matching enabled notifier; a slow receiver never blocks the monitor.
  `escalation_only` keeps a channel silent until a critical incident has gone
  unacknowledged. A service that opens too many incidents inside the flap window
  stops sending per-incident messages and sends one `DigestJob` instead, unique
  per service so a storm becomes a message (ADR-015).

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

People join either by being added — if they already have an account — or by
being invited, which emails a single-use link to an address that may have none.
Accepting creates the account, confirms it, adds the membership and signs them
in, because holding the link proves control of the mailbox, which is what the
magic-link login already accepts as proof. Accepting is a `POST`, so a mail
scanner following the link cannot join on somebody's behalf. See ADR-013.

Roles: `owner` and `admin` may write, `member` may act on incidents, `viewer` is
read-only. Authorization is enforced in the contexts, not by hiding buttons.

A token is the second way to hold a scope. `PulseOpsWeb.Plugs.ApiAuth` turns a
bearer token into the same `%Scope{}` a session produces, and the API controllers
then call the same context functions the LiveViews call — so every tenant filter
and role check applies without the API restating one. A token names the person
who made it and takes its role from their membership at request time, so it can
never outrank its owner. Only the hash is stored. See ADR-012.

The one deliberate exception is the public status page at `/status/:slug`, which
anybody can read. It goes through `PulseOps.StatusPage` and nowhere else — a
context of its own, so the exception is a file to review rather than a scattering
of unauthenticated functions among scoped ones. Its queries name the columns they
return, so a service's `url` and an incident's `cause` are never fetched and no
template change can start leaking them. An organization publishes nothing until
`status_page_enabled` is set; a service appears only while its `public` flag is.
See ADR-011.

## PubSub topics

| Topic | Carries | Subscribed by |
|---|---|---|
| `organization:{id}:services` | service status transitions | dashboard |
| `organization:{id}:incidents` | incident opened / changed / resolved | dashboard, incident list |
| `service:{id}:checks` | every individual check result | service detail page only |

The public status page subscribes to the first two, so an outage reaches a
reader's open tab over the connection it already has, as fast as it reaches the
on-call dashboard.

See ADR-003.

A broadcast is a signal that something changed, not the change itself: a page
re-reads from the database rather than patching its assigns from the payload, so
two racing changes cannot leave it out of step. The dashboard defers that re-read
briefly and coalesces everything arriving inside the window into one reload,
because its summary costs four queries and a flapping service would otherwise pay
for all of them per viewer, per change.

## Deployment shape

The production image is a `mix release` on a runtime carrying no Mix, no build
tools and no source, running as a non-root user. `bin/migrate` and `bin/server`
are separate entry points on purpose: a container that migrates as it boots
races every other replica starting at the same moment.

`PHX_HOST` is mandatory and the release refuses to boot without it — it is in
every generated link, and a wrong one fails silently rather than loudly.
`force_ssl` redirects and sets HSTS, trusting `x-forwarded-proto`, so TLS is
terminated by whatever sits in front.

**PulseOps runs on one node.** `Bootstrapper` starts a monitor for every enabled
service on *each* node, so a second replica duplicates probes, checks and
notifications. The partial unique index (ADR-004) keeps incidents from being
duplicated and protects nothing else. Leader election or partitioning by
`service_id` has to exist before scaling by replicas.

## Testing seams

Reading a certificate is a second seam of the same shape:
`PulseOps.Monitoring.TlsCheck` is a behaviour with an `:ssl` implementation and a
Mox mock, because a handshake needs a real host. The parsing it does with what
comes back is pure and lives in `TlsCheck.Certificate`.

The HTTP client is a behaviour, `PulseOps.Monitoring.HealthCheck`, resolved through
application config. Tests swap in a Mox mock; development and production use
`HealthCheck.Req`. A `/dev/flaky` endpoint whose response is toggled at runtime lets
an incident be triggered on demand during a demo.

Webhook deliveries share the same idea: `config :pulse_ops, webhook_client: :stub`
routes them through a `Req.Test` plug in tests so nothing touches the network, while
every other environment delivers over the wire. Email uses Swoosh's Test adapter in
tests; `BREVO_API_KEY` at runtime switches production and development to Brevo.
