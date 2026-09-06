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
└── PulseOpsWeb.Endpoint
```

Each `ServiceMonitor` is registered as `{:via, Registry, {PulseOps.Monitoring.Registry,
{:monitor, service_id}}}`, so it can be found, restarted or stopped by service id.

Monitors are `restart: :transient` under a `DynamicSupervisor` with bounded
`max_restarts`. A monitor whose endpoint makes it crash repeatedly is given up on
without affecting any other monitor — fault isolation is the point of the design.

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
        open/resolve incident
        broadcast to PubSub
```

The jitter keeps monitors from synchronising into a thundering herd after a mass
restart. See ADR-002 for why the request is not made inline.

## Data model

```
organizations ──┬── organization_members ──── users
                │
                └── services ──┬── service_checks
                               └── incidents ──── incident_events
```

- `services` — name, description, environment, url, `check_interval_ms`,
  `timeout_ms`, `enabled`, current `status`, `last_checked_at`.
- `service_checks` — one row per probe: status, http status, response time, error.
  Grows quickly; indexed on `(service_id, inserted_at DESC)`. Rollups and pruning
  are V2 work.
- `incidents` — severity, status (`open` → `investigating` → `identified` →
  `monitoring` → `resolved`), cause, started/resolved timestamps, resolver.
  A partial unique index enforces at most one unresolved incident per service (ADR-004).
- `incident_events` — the timeline; `user_id` is null for automatic events.

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

## Testing seams

The HTTP client is a behaviour, `PulseOps.Monitoring.HealthCheck`, resolved through
application config. Tests swap in a Mox mock; development and production use
`HealthCheck.Req`. A `/dev/flaky` endpoint whose response is toggled at runtime lets
an incident be triggered on demand during a demo.
