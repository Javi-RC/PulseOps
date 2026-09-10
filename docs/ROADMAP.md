# Roadmap

Audit of the codebase as of 2026-09-09 (branch `feature/incident-notifications`,
tag `v0.3.0`, phase 11 complete) and the plan that comes out of it.

**Read [`PROGRESS.md`](PROGRESS.md) first** for what is built. This file is the
other half: what is *wrong* with what is built, and what to do next, in order.

Everything below was derived by reading the code, not by reading the docs. Where
a finding contradicts a claim made elsewhere in `docs/` or `README.md`, the
finding is what the code actually does — the docs have not been corrected yet.

---

## Where the project stands

PulseOps is a multi-tenant uptime and incident-management system built on
Elixir/OTP. The technical thesis is sound and well executed: state is held by
supervised processes that push changes over PubSub, never computed by polling.

**Maturity: a solid MVP carrying beta-grade engineering.** The scaffolding (CI,
Dialyzer, Credo `--strict`, ADRs, living documentation, substitutable I/O seams)
is production quality. The product surface is still the minimum viable one. That
imbalance is the right one to have — the foundation will take the weight of new
features — but five concrete defects must be fixed before anything is added.

| Dimension | Level |
|---|---|
| OTP design / concurrency | High beta |
| Domain modelling and contexts | Beta |
| Multi-tenancy / authorization | Beta (with the leak in F3) |
| Testing | High MVP |
| Observability | Pre-alpha |
| Product surface | MVP |
| Operational readiness (real deploy) | Pre-alpha |

### Strongest parts

1. **`ServiceMonitor` and its supervision tree.** Real fault isolation, a single
   status-transition gate (`transition/3`), and backstops for every probe
   failure mode (crash, hang, late reply, deleted service).
2. **`Scope`-based tenancy.** Authorization in the contexts, not the templates;
   unknown slugs and non-membership return the same response, so organizations
   cannot be enumerated.
3. **Guarantees in the database.** `incidents_one_open_per_service` is what will
   make clustering safe later.
4. **Testing seams.** Every outbound I/O path is swappable through config
   (`HealthCheck` behaviour + Mox, `webhook_client: :stub` + `Req.Test`, Swoosh
   Test adapter, `start_monitors: false`).

### Weakest parts

1. Incident reconciliation — happens only at monitor boot (F1).
2. Dashboard performance — full reload per broadcast (F4).
3. Observability — telemetry is emitted and consumed by nobody.
4. Alert rules — uniqueness model is broken (F2) and propagation is serial and
   blocking (F7).
5. Health checks — GET only, no headers, no auth, no body assertion.

---

## Findings

Nine defects found by reading the code. None are recorded in `PROGRESS.md`.
F1–F5 are the P0 set; the fix plan in [Phase 1 in detail](#phase-1-in-detail)
covers them.

### F1 — A manually resolved incident never reopens while the service is still down

**Correctness. The most serious finding.**

`Incidents.resolve_incident/3` closes the incident row, but the `ServiceMonitor`
keeps `state.status == :down`. Incidents open only on the *transition* to
`:down`, and the monitor is already there, so it will never transition again.
The service stays down **indefinitely with no open incident and no further
notifications**.

This breaks exactly the invariant ADR-008 protects — "a down service has an open
incident" — but reconciliation runs only in
`handle_continue(:reconcile_incident)`, i.e. **only when the monitor boots**. In
production it does not heal until a redeploy.

Files: `lib/pulse_ops/monitoring/service_monitor.ex`, `lib/pulse_ops/incidents.ex`

### F2 — Several organization-default alert rules can exist

**Integrity.**

`create unique_index(:alert_rules, [:service_id])` — in Postgres NULLs are
distinct from each other, so N rows with `service_id = NULL` are legal. The only
defence is the UI: `alert_rule_live/form.ex:109` hides the "Organization
default" option when one already exists. That is check-then-act with no
transaction — two concurrent requests, or a crafted `phx-submit`, create two
defaults.

`Monitoring.rule_for_monitoring/1` and `get_rule_for_service/2` then order by
`is_nil(service_id)` with `limit: 1` and **no tiebreaker**, so which rule governs
a service becomes non-deterministic.

Files: `priv/repo/migrations/20260907120542_create_alert_rules.exs`,
`lib/pulse_ops/monitoring.ex`, `lib/pulse_ops_web/live/alert_rule_live/form.ex`

### F3 — `alert_rules.service_id` is not validated against the tenant

**Cross-tenant.**

`AlertRule.changeset/3` casts `:service_id` with only a `foreign_key_constraint`.
`Notifier.changeset/3` does validate this (`validate_service_scope`); the alert
rule does not. An admin can create a rule pointing at another tenant's
`service_id`.

The impact is not reading another tenant's data — `rule_for_monitoring/1` filters
by `organization_id` — but it **occupies the victim's slot in the unique index**,
preventing them from ever creating their own rule for that service. A
cross-tenant denial of service through an unvalidated field.

Files: `lib/pulse_ops/monitoring/alert_rule.ex`

### F4 — The dashboard reloads everything on every broadcast

**Performance. The hard scaling ceiling today.**

`DashboardLive.load_dashboard/1` runs in full on every message, and that is four
queries, one of them expensive:

```
list_services + uptime_by_service (24h of raw checks)
             + recent_checks_by_service (window function)
             + list_active_incidents
```

Cost is **O(viewers x status_changes x checks_in_24h)**. With 50 services at a
30 s interval that is ~144,000 rows scanned by `uptime_by_service`, repeated per
open tab and per status change. There is no debounce, no cache, no rollups.

This is the real limit of the system today, well ahead of the number of monitors.

Files: `lib/pulse_ops_web/live/dashboard_live.ex`, `lib/pulse_ops/monitoring.ex`

### F5 — SSRF through service and webhook URLs

**Security. The most serious design vulnerability for a multi-tenant product.**

A tenant registers `http://169.254.169.254/latest/meta-data/` or
`http://localhost:5432` as a service and PulseOps probes it from inside the
network, returning the HTTP status and response time. The same applies to
webhook URLs. Neither `Service.changeset/3` nor `Notifier.changeset/3` does
anything beyond an http(s) format check.

Files: `lib/pulse_ops/monitoring/service.ex`,
`lib/pulse_ops/notifications/notifier.ex`,
`lib/pulse_ops/monitoring/health_check/req.ex`,
`lib/pulse_ops/notifications/webhook_sender.ex`

### F6 — `prune_old_checks/1` cannot use an index, and does not batch

The only index on `service_checks` is `[:service_id, :inserted_at]`. The nightly
delete filters on `inserted_at` alone, so it cannot use it: a sequential scan and
a single unbounded `DELETE` over the fastest-growing table in the schema.

Files: `lib/pulse_ops/monitoring.ex`,
`priv/repo/migrations/20260906125420_create_service_checks.exs`

### F7 — `stop_monitor/1` blocks the caller, and restarts are serial

`MonitorSupervisor.await_unregistered/2` busy-waits with `Process.sleep(10)` up
to 500 ms. `Monitoring.restart_affected_monitors/3` for an organization-default
rule calls `restart_monitor/1` for **every** service, sequentially, from the
LiveView process. With 100 services, saving one rule can block the LiveView for
up to 50 seconds. The fix is `Process.monitor` + `receive`, not sleeping.

Files: `lib/pulse_ops/monitoring/monitor_supervisor.ex`, `lib/pulse_ops/monitoring.ex`

### F8 — Telemetry is emitted and consumed by nobody

`ServiceMonitor.record/2` emits `[:pulse_ops, :monitoring, :check]` and nothing
listens. No exported metrics, no structured logging, no traces. A monitoring
product that does not monitor itself.

Files: `lib/pulse_ops_web/telemetry.ex`, `lib/pulse_ops/monitoring/service_monitor.ex`

### F9 — Not deployable safely

`PHX_HOST` defaults to `"example.com"` in production, which silently produces
broken webhook incident URLs. There is only a `Dockerfile.dev`; no production
image. `force_ssl` is still commented out in `runtime.exs`.

Files: `config/runtime.exs`, `Dockerfile.dev`

### F10 — One crash-looping monitor takes every monitor down

**Found on 2026-09-10 while building monitor-health visibility, and verified by
running it** — not part of the original audit.

`MonitorSupervisor`'s `max_restarts: 5, max_seconds: 60` is the intensity of the
whole `DynamicSupervisor`, not a per-child budget. One monitor crashing six times
in a minute exceeds it: the supervisor terminates itself and every monitor under
it. `Monitoring.Supervisor` (`:one_for_one`) restarts it empty and `Bootstrapper`
does not run again, so **every service in every organization goes unwatched**
until the application restarts. Killing one service's monitor seven times left a
second, healthy service with no monitor.

This contradicts what this audit listed as the strongest part of the system
("real fault isolation"). A crashing *probe* does not trigger it — probes run
under `async_nolink` — but anything that crashes the monitor process itself does,
and a crash at boot repeats on every restart.

Files: `lib/pulse_ops/monitoring/monitor_supervisor.ex`,
`lib/pulse_ops/monitoring/supervisor.ex`

**Fixed** by giving each monitor its own supervisor, `MonitorContainer`, with the
restart budget the shared one only claimed to have; containers are temporary, so
a service that exceeds its budget stays down on its own (ADR-017). The regression
test kills one monitor six times and asserts the other monitor is the same
process under the same `MonitorSupervisor` — run against the old supervisor, it
fails with the other monitor gone.

---

## Technical debt

### Fix now

| Problem | Impact | Risk | Effort | Priority |
|---|---|---|---|---|
| F1 manual resolve never reopens; reconciliation only at boot | A down service sits with no incident and no alerts, indefinitely | **Very high** — breaks the core promise | Low | **P0** |
| F2 `unique_index(:alert_rules,[:service_id])` allows N defaults | Non-deterministic effective rule; racy UI guard | High | Low | **P0** |
| F3 `AlertRule` does not validate `service_id` tenancy | Cross-tenant DoS: occupies another org's unique slot | High | Low | **P0** |
| F4 full dashboard reload per broadcast over raw 24 h checks | O(viewers x changes x rows); hard scaling ceiling | High | Medium | **P0** |
| F5 SSRF via `Service.url` and `Notifier.url` | Internal network and cloud metadata probing from any tenant | High | Medium | **P0** |
| F6 retention delete without usable index or batching | Nightly seq scan and lock on the largest table | Medium | Low | **P1** |
| F7 `Process.sleep` wait + serial restarts | LiveView blocked for seconds when saving an org rule | Medium | Low | **P1** |
| F8 telemetry emitted, never consumed | Zero production visibility | Medium | Low | **P1** |
| F9 `PHX_HOST` default, no prod image, `force_ssl` commented | Not safely deployable; silently broken webhook URLs | Medium | Low | **P1** |

### Can wait

| Problem | Impact | Risk | Effort | Priority |
|---|---|---|---|---|
| `Incidents` hard-coupled to `Notifications`; enqueue runs inside `ServiceMonitor` | DB work on the monitor's critical path | Low | Medium | P2 |
| ~~`WebhookSender` uses `PulseOpsWeb.Endpoint.url()` (domain depends on web)~~ — **fixed**: `PulseOps.Links` from the domain's own config, and a boundary test keeps `PulseOpsWeb` out of `lib/pulse_ops` | Layer inversion | Low | Low | P2 |
| ~~`case record(...)` triplicated in `ServiceMonitor` (~lines 150, 165, 180)~~ — **done**: one `finish_check/2` for every way a probe ends | Maintainability | Low | Low | P2 |
| ~~`secret_token` stored in plaintext, no `redact`, echoed back into the form~~ — **fixed**: encrypted at rest, redacted, never rendered (ADR-018) | Secret exposure | Medium | Low | P2 |
| ~~`Service.request_headers` stored in plaintext — an `Authorization` header set on a check is readable in the table and rendered back into the service form~~ — **fixed**: encrypted, redacted, values masked in the form (ADR-018) | Secret exposure | Medium | Low | P2 |
| ~~StreamData declared in `mix.exs` and used nowhere~~ — **done**: property tests for the status machine and `UrlGuard` | Missed testing opportunity | Low | Medium | P2 |
| ~~No rate limiting on login/registration~~ — **fixed**: per email always, per address behind a trusted proxy (ADR-019) | Brute force | Medium | Low | P2 |
| `Bootstrapper` loads every enabled service into memory at once | Memory at boot, at scale | Low | Low | P3 |
| ~~`mix.exs` says `0.2.0` while `v0.3.0` is tagged; stray empty `.github;W` dir; 7 MB untracked `erl_crash.dump`~~ — **done** in the Phase 1 housekeeping | Noise | None | Trivial | P3 |

---

## Phases

Ordered by dependency and risk, not by ease.

### Phase 1 — Stabilisation

Make what already exists correct and defensible. F1–F5 are independent of each
other, so this order is purely decreasing risk; each is its own commit.

- [x] **F1** Periodic incident reconciliation
- [x] **F2** Partial unique index for the organization-default rule
- [x] **F3** Validate `service_id` tenancy in `AlertRule`
- [x] **F4** Dashboard debounce (the cheap half of F4)
- [x] **F5** SSRF mitigation (`UrlGuard`)
- [x] **F6** Batched retention + index
- [x] Housekeeping: `mix.exs` to `0.3.0`, delete `.github;W` and `erl_crash.dump`

Detailed implementation plan: [Phase 1 in detail](#phase-1-in-detail).

### Phase 2 — Scale and visibility

Make the system survive realistic data and observe itself.

- [x] Metric rollups (hourly table + Oban job), rewrite `service_metrics/3` and
      `uptime_by_service/2` to read them — the expensive half of F4
- [x] **F8** Consume the telemetry: Prometheus metrics, a `/metrics` endpoint,
      structured logging with `service_id`/`organization_id`, `Oban.Telemetry`
      for job failures
- [x] **F7** Propagate rule changes without restarting processes:
      `GenServer.cast({:rule_changed, rule})` instead of restart, and
      `Process.monitor` instead of `Process.sleep`
- [x] Extract the status state machine (`next_status/3`, `tally/2`) from
      `ServiceMonitor` into a pure module, and property-test it with StreamData:
      *no sequence of probe outcomes produces two open incidents*
- [x] `mix test --cover` with a threshold in CI

### Phase 3 — Product surface

Turn the engine into something other people interact with.

- [x] Public status page (see [Star features](#star-features))
- [x] JSON API + organization tokens
- [x] Configurable checks: HTTP method, headers, expected status, body assertion
- [x] Email invitations for people who are not registered yet
- [x] **F9** Real deploy: production Dockerfile, `force_ssl`, mandatory
      `PHX_HOST`, secrets

### Phase 4 — Operational reliability and polish

Behave like an actual on-call tool.

- [x] Maintenance windows and silencing
- [x] Anti-flapping, notification grouping, escalation
- [x] TLS certificate expiry watching
- [x] UX: time-window selector, destructive-delete confirmation, incident
      pagination, monitor-health visibility — the delete confirmation already
      existed by the time this was picked up; it is now pinned by a test.
      Building monitor-health visibility is what surfaced **F10**.
- [x] **F10** A restart budget per service: one crash-looping monitor no longer
      takes every other monitor down

---

## Quick wins

Ordered by impact over effort. Each is small enough to land on its own.

1. **Dashboard debounce** — a coalescing `Process.send_after(self(), :reload, 250)`
   in `load_dashboard`. ~15 lines; removes most of the query load under flapping.
2. **`service_checks(inserted_at)` index + batched delete** — one migration and a
   loop. Turns a nightly seq scan into a bounded operation.
3. **Tenancy validation in `AlertRule.changeset/3`** — copy `validate_service_scope`
   from `notifier.ex`. Closes a cross-tenant leak in ~12 lines.
4. **Partial unique index for the default rule** — one migration; replaces a racy
   UI guard with a real guarantee.
5. **Consume the telemetry already emitted** — add metrics to `telemetry.ex`; the
   `[:pulse_ops, :monitoring, :check]` event is emitted and thrown away today.
6. **"Send test notification" button** — reuse `NotifyJob` with a synthetic
   incident; turns blind webhook configuration into something verifiable.
7. **Enable/disable toggle in the services list** — `Service.enabled` and
   `MonitorSupervisor` already support this end to end.
8. **Confirm before deleting a service** — deleting cascades away all history and
   incidents; today it is one click.
9. **`Process.monitor` instead of `Process.sleep`** in `await_unregistered/2` —
   ~10 lines, removes up to 500 ms of blocking per monitor.
10. **Repo housekeeping** — `mix.exs` to `0.3.0`, delete `.github;W` and
    `erl_crash.dump`.

---

## Star features

Five features that would differentiate the project. All reuse what exists; none
are disconnected from the current state.

### 1. Public status page per organization

An unauthenticated page at `/status/:slug` with current status, historical
uptime, and open and past incidents, updating live over the same WebSocket.

It is the natural, missing complement to a system that already computes exactly
this data, and it closes the loop: PulseOps goes from "I watch my services" to
"my customers watch my services". Reuses `Organization.slug`,
`uptime_by_service/2`, `list_incidents/2`, `status_badge`, `uptime_bar` and the
existing PubSub topics — almost no new domain, just a `live_session` outside
`:require_organization` plus a visibility flag.

**Complexity: Medium. Impact: Very high** — it is what makes the project
demonstrable without handing anyone credentials.

### 2. JSON API with organization tokens

Read and write REST over services and incidents, token authenticated, plus an
inbound webhook for creating incidents externally.

`pipeline :api` has been declared and unused in `router.ex:18` since bootstrap.
More importantly, the contexts already take a `%Scope{}` with authorization
inside: a plug that builds a `Scope` from a token reuses the entire domain and
all of its authorization without duplicating a single rule.

**Complexity: Medium. Impact: High** — and it proves the layer separation was real.

### 3. Heartbeat monitors (dead-man's switch)

Instead of PulseOps probing, the client pings a unique URL every N minutes; if
the ping does not arrive, an incident opens.

This is the exact inversion of the `ServiceMonitor` that already exists. A
monitor in heartbeat mode launches no `Task` — it just checks `last_ping_at` on
its tick, which is *less* code than the current path. And it watches what HTTP
probing cannot: cron jobs, backups, workers, ETL. Reuses `ServiceMonitor`,
`AlertRule`, `Incidents`, `Notifications` and the whole UI; needs a `type` on
`services` and an ingest endpoint.

**Complexity: Medium-low. Impact: High** — doubles the product's market for very
little code.

### 4. Maintenance windows with incident suppression

Schedule a window per service or per organization; during it checks are still
recorded but no incidents open and nothing is notified, and the status page
announces it as planned maintenance.

This is the number one failure of any alerting system in real use — you deploy
and wake everyone up. `ServiceMonitor.transition/3` is the single gate, so
suppression is a check in one function. Reuses `transition/3`, `Incidents`, the
status page, and Oban for opening and closing the window.

**Complexity: Medium. Impact: High.**

### 5. Anti-flapping with grouping and escalation

Detect an oscillating service, group notifications into a digest ("5 transitions
in 10 minutes") instead of sending N, and escalate to a second channel if a
critical incident goes unacknowledged for X minutes.

Today `enqueue_incident_notifications/3` fires 1:1 with no suppression at all, so
a service sitting on the threshold produces a storm. Reuses `NotifyJob`,
`notifier_assignments`, and Oban's `unique` and `scheduled_at`, which support
exactly this.

**Complexity: Medium-high. Impact: High** — turns notifications from noise into
signal, which is what separates a toy from an on-call tool.

---

## Missing features that complete what exists

Each is traceable to something in the code, not a generic wishlist.

| Feature | Evidence it is missing |
|---|---|
| Incident reopening / periodic reconciliation | `handle_continue(:reconcile_incident)` runs only at boot (F1) |
| Email invitations for unregistered users | `Organizations.add_member/3` says so in its own `@doc`; the README claims "invite people" |
| HTTP method, headers and assertions on checks | `HealthCheck.Req.check/2` only calls `Req.get`, with no options |
| Silencing / maintenance windows | `Notifier.enabled` is global; no way to mute a planned deploy |
| Notification dedup, grouping and escalation | `enqueue_incident_notifications/3` fires 1:1 with no flap suppression |
| "Send test notification" | `NotifierLive.Form` offers no way to validate a webhook before trusting it |
| Enable/disable a service from the list | `Service.enabled` exists and `MonitorSupervisor` honours it, but it can only be changed through the full edit form |
| Metric rollups | `service_metrics/3` and `uptime_by_service/2` aggregate over raw rows |

## UX gaps

1. Deleting a service cascades away all history and incidents behind one button,
   with no confirmation.
2. Everything is hardcoded to 24 hours (`hours_ago(24)`); no 7- or 30-day view.
3. No historical availability timeline beyond the last 24 bars.
4. `list_incidents/2` has a fixed `limit: 50` and no pagination or filtering.
5. No acknowledge state, distinct from `:investigating`.
6. The UI shows *service* status but never whether its monitor is alive — a
   monitor abandoned after 5 crashes is invisible.

---

## Future problems to design against

**When data grows.** `service_checks` grows at `86,400 / interval` rows per
service per day — 100 services at 30 s is ~29M rows a month. `service_metrics/3`
and `uptime_by_service/2` aggregate over raw data, so the dashboard degrades
linearly with retention, and retention is *configurable* — a config change can
sink performance. *Prevent:* rollups now, while migrating the data is trivial;
range partitioning by date past ~50M rows.

**When concurrent users grow.** Each open dashboard runs 4 queries per broadcast.
20 people watching an incident that causes 10 transitions is 800 queries, many of
them aggregations. *Prevent:* debounce now; later a per-organization summary
GenServer holding state in memory and broadcasting diffs, instead of every
LiveView re-querying.

**When services grow.** "Restart the process to reload configuration" is O(n) and
blocking. At 500 services, changing the organization default rule is unworkable.
*Prevent:* move to hot config `cast` (Phase 2) — far easier at 10 services than
at 500.

**When nodes are added.** `Bootstrapper` starts every enabled service on *each*
node. A second node duplicates probes, checks and notifications. The partial
unique index protects incidents and nothing else. *Prevent:* do not deploy
multi-node until leader election or consistent partitioning by `service_id`
exists. **Document this as a deployment constraint now**, before someone scales
by replicas and causes a notification storm.

**When notification channels are added.** `NotifyJob.dispatch/3` is a `case` on
`type` and `Notifier` has one column per destination (`url`). Slack, PagerDuty
and SMS each add columns the others leave null. *Prevent:* move to a `config`
map with a `Channel` behaviour per type **before the third channel**.

**When check types are added.** Same shape: HTTP, TCP, ping, heartbeat, DNS and
TLS share no fields, and `services` will accumulate nullable columns. *Prevent:*
a `type` discriminator plus a per-type validated `config` map, decided **before**
implementing heartbeats.

**When threshold logic changes.** The state machine (`next_status/3`, `tally/2`)
is correct but entangled with GenServer I/O, so adding hysteresis, sliding
windows or dependency suppression is risky. *Prevent:* extract it into a pure,
property-testable module — the best value-to-risk refactor available in this
project.

---

## Phase 1 in detail

### Order

Strictly by risk: **F1** (correctness) → **F2/F3** (integrity and tenancy) →
**F4 debounce** (scale) → **F5** (security) → **F6** (retention). They are
independent, so this is decreasing risk rather than a dependency chain.

### Files to touch

| Task | Files |
|---|---|
| F1 | `lib/pulse_ops/monitoring/service_monitor.ex`, `lib/pulse_ops/incidents.ex` |
| F2 | new migration, `lib/pulse_ops/monitoring/alert_rule.ex`, `lib/pulse_ops/monitoring.ex`, `lib/pulse_ops_web/live/alert_rule_live/form.ex` |
| F3 | `lib/pulse_ops/monitoring/alert_rule.ex` |
| F4 | `lib/pulse_ops_web/live/dashboard_live.ex` |
| F5 | `lib/pulse_ops/monitoring/service.ex`, `lib/pulse_ops/notifications/notifier.ex`, `lib/pulse_ops/monitoring/health_check/req.ex`, `lib/pulse_ops/notifications/webhook_sender.ex` |
| F6 | new migration, `lib/pulse_ops/monitoring.ex` (`prune_old_checks/1`) |

### New components

- `PulseOps.Monitoring.UrlGuard` — a pure module: validates the scheme, resolves
  DNS, rejects private/loopback/link-local ranges. Used both in the changeset and
  again immediately before the request — validation alone is not enough, because
  of DNS rebinding.
- Migration `add_default_alert_rule_unique_index` — must delete pre-existing
  duplicates (keeping the lowest `id`) in `up` before creating the index.
- Migration `add_inserted_at_index_to_service_checks`.

### Interfaces to define

```elixir
# Reconciliation — the monitor asks, the context decides the action
@spec Incidents.ensure_incident_state(Service.t(), status :: atom(), AlertRule.t()) ::
        {:ok, :unchanged | Incident.t()} | {:error, term()}

# URL guard — pure, testable, shared by services and webhooks
@spec UrlGuard.validate(String.t()) ::
        :ok | {:error, :private_address | :invalid_scheme | :unresolvable}

# Batched retention
@spec Monitoring.prune_old_checks(days :: pos_integer(), opts :: [batch_size: pos_integer()]) ::
        non_neg_integer()
```

The debounce needs no new interface: a deferred `:reload` message and a
`reload_pending?` flag inside `DashboardLive`.

### Tests to add

- **F1 (write this one first, and watch it fail):** service `:down` → a user
  resolves the incident by hand → next failing probe → **a new incident opens**.
  This is the regression test that anchors the whole finding.
- **F1:** resolving by hand and then having the service recover must not reopen
  anything.
- **F2:** creating two organization defaults concurrently — the second returns an
  `{:error, changeset}`, not an exception.
- **F3:** creating a rule with another organization's `service_id` returns
  `{:error, changeset}` with the error on `:service_id`.
- **F4:** N rapid broadcasts produce exactly one reload (count queries via Ecto
  telemetry or an `Agent` counter).
- **F5:** `UrlGuard` rejects `127.0.0.1`, `169.254.169.254`, `10.0.0.1`, `::1`
  and a hostname resolving to a private address; accepts a public one. Property
  test with StreamData over IP ranges.
- **F6:** with `batch_size: 10` and 25 expired rows, deletes 25 in 3 batches.

### Risks

- Reconciliation could reopen incidents a human closed deliberately while the
  service is still down. *Mitigate:* a grace period (e.g. do not reopen within
  5 minutes of a manual resolution) and an explicit `:reopened` timeline event,
  so the timeline does not lie.
- The uniqueness migration **will fail** if duplicate defaults already exist in
  the development database. The migration must clean them first.
- The SSRF guard can block legitimate private-network deployments. *Mitigate:*
  `config :pulse_ops, :allow_private_targets`, `true` in dev, `false` in prod.
- The debounce adds up to 250 ms of visible latency. Acceptable, but it weakens
  the README's "real time" claim — adjust the wording.

### How to validate

1. `docker compose run --rm web mix check` — the full suite, Credo `--strict` and
   Dialyzer must stay green.
2. **Against the running app**, which is how every previous phase was validated
   and is this project's standard: use `/dev/flaky` to break the endpoint, wait
   for the incident, **resolve it by hand in the UI while it is still broken**,
   and confirm a new incident opens on the next cycle. That is the scenario that
   fails silently today.
3. Seed ~100k `service_checks` and compare queries-per-status-change on the
   dashboard before and after the debounce, via Ecto logs.
4. Try to create a service pointing at `http://169.254.169.254/` and confirm the
   form rejects it.
5. `EXPLAIN ANALYZE` the retention `DELETE` before and after the index.

---

## Conventions to follow when implementing

Taken from how the repository already works — see `AGENTS.md` and ADR-006.

- **There is no Elixir on the host.** Everything runs through the container:
  `docker compose up -d db` first, then
  `docker compose run --rm web mix <anything>`.
- `mix check` (format + compile --warnings-as-errors + credo --strict + test +
  dialyzer) must be green before a phase is considered done.
- Update `PROGRESS.md` **in the same commit** as the code it describes, and tick
  the box in this file.
- A decision that a future reader would question belongs in `DECISIONS.md` as a
  new ADR. F1's fix earns one — it extends ADR-008 from "reconcile at boot" to
  "reconcile continuously".
- Authorization goes in the context, never in the template.
- Business invariants belong in the database where a constraint can express them
  (ADR-004 is the precedent, and F2 is what happens when that is skipped).
- No AI co-authorship or attribution in commit messages.
