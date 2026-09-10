# Progress

Living record of where the project stands. Updated in the same commit as the code
of each phase. **Read this first when picking the work back up.**

## Current state

| | |
|---|---|
| Branch | `main` |
| Phase | Phase 4 of [`ROADMAP.md`](ROADMAP.md) complete — operational reliability, and F10 fixed (v0.6.0) |
| Next | No numbered phase left — the remaining debt, quick wins and star features in [`ROADMAP.md`](ROADMAP.md) |
| Checks | `mix check` green: 729 tests, coverage above the 90% threshold, Credo `--strict` and Dialyzer clean |


## Commands

There is no Elixir on the host. Everything goes through the container:

```bash
docker compose up -d db                        # Postgres must be up first
docker compose up web                          # http://localhost:4000
docker compose run --rm web mix test
docker compose run --rm web mix check          # format + compile + credo + test + dialyzer
docker compose run --rm web iex -S mix
docker compose run --rm web mix <anything>
```

Docker Desktop must be running. On Windows it is at
`%LOCALAPPDATA%\Programs\DockerDesktop\Docker Desktop.exe`, not under Program Files.

## Done

### Phase 0 — Bootstrap and Docker environment

- Phoenix 1.8.13 project generated at the repository root (`--app pulse_ops --module PulseOps`),
  using a throwaway container since no Elixir exists on the host.
- `Dockerfile.dev` (elixir:1.20-otp-28 + inotify-tools) and `compose.yaml` with `db`
  (postgres:17-alpine) and `web`.
- Database config in `config/dev.exs` and `config/test.exs` reads `DATABASE_HOST`,
  defaulting to `db` so it works inside compose.
- Added: Oban (declared, now wired with housekeeping jobs), Credo, Dialyxir, Mox, StreamData.
- `mix check` alias wired up.
- `config :pulse_ops, start_monitors: false` already set in `config/test.exs` — see
  ADR-005, this must stay.
- Verified: `http://localhost:4000` returns 200.

### Phase 1 — Authentication and multi-tenancy

- `mix phx.gen.auth Accounts User users --live` — LiveView registration, login,
  settings and confirmation, plus `PulseOps.Accounts.Scope`.
- `PulseOps.Organizations`: `Organization` (name + unique slug, slug derived from
  the name) and `Membership` (`owner`/`admin`/`member`/`viewer`).
- `Accounts.register_user/1` now runs an `Ecto.Multi` that also creates the user's
  personal organization and their owner membership — a new user is never stranded
  without a tenant.
- `Scope` extended with `organization` and `role`; `Scope.put_organization/3`.
- `config :pulse_ops, :scopes` has the `organization` entry with
  `route_prefix: "/orgs/:org"` — required *before* any `--scope organization`
  generator runs (ADR-001).
- `on_mount :require_organization` in `PulseOpsWeb.UserAuth` resolves the slug,
  verifies membership, and narrows the scope. Non-members and unknown slugs get
  the same response, so the route cannot enumerate organizations.
- Authorization in `Organizations.can?/2` and `authorize/2`, in the context.
- Test helper `register_and_log_in_user_with_org` and `PulseOps.OrganizationsFixtures`.
- Tidied Credo `--strict` findings in the Phoenix-generated files so the linter is
  green from the start.

### Phase 2 — Services CRUD

- `mix phx.gen.live Monitoring Service services ... --scope organization`. The
  generator emitted organization-filtered queries and PubSub broadcasting on its
  own, because the scope config from Phase 1 was already in place.
- `environment` and `status` are `Ecto.Enum`; URL must be http/https;
  `check_interval_ms` 10s–1h, `timeout_ms` 1s–30s and strictly below the interval.
- Unique index on `(organization_id, name)`, with the error reported against
  `:name` so the form shows it on the field the user can change.
- `status` and `last_checked_at` are **not** castable in `changeset/3` — they belong
  to the monitor. `status_changeset/2` is the separate path the monitor will use in
  Phase 3, and the form no longer renders those fields.
- Writes go through `Organizations.authorize(scope, :manage_services)`; the
  LiveViews handle `{:error, :unauthorized}` rather than crashing.
- Routes live under `live_session :require_organization` at `/orgs/:org/services`.
- PubSub topic emitted by the generator is `organization:{id}:services`.

### Phase 3 — Health checks with OTP

- `PulseOps.Monitoring.Supervisor` in the app tree after Repo and PubSub:
  Registry (`:unique`) → `Task.Supervisor` → `MonitorSupervisor` → `Bootstrapper`.
- `ServiceMonitor` (`restart: :transient`), one per enabled service, registered
  `{:via, Registry, {..., {:monitor, service_id}}}`. The probe runs under
  `Task.Supervisor.async_nolink/2`, never inline (ADR-002). Jittered scheduling,
  at most one probe in flight per service, and a backstop timeout in case a task
  wedges past the service's own timeout.
- Thresholds: 3 consecutive failures to go down, 2 successes to recover, and a
  success slower than half the service timeout reports degraded.
- `HealthCheck` behaviour + `HealthCheck.Req`; `config/test.exs` points at
  `HealthCheckMock`, defined in `test_helper.exs`.
- `service_checks` table; every probe is recorded, but only status *changes* are
  broadcast to the organization topic.
- Lifecycle wired into the context: create starts a monitor, update restarts it,
  delete stops it.
- `/dev/flaky` (dev only) with `POST /dev/flaky/break` and `/heal`, plus seeds
  covering a controllable target, a real external one, and a permanently dead one.

**Verified against the running app,** not just in tests: `Legacy Payments` went
down after exactly 3 failed probes, and breaking the flaky endpoint drove
`API Gateway` healthy → down → healthy on the real thresholds.

### Phase 4 — Incidents

- `PulseOps.Incidents` is its own context: incidents have a lifecycle of their
  own, people act on them, and Phase 5 gives them their own LiveView.
- `incidents` and `incident_events`, with the partial unique index
  `incidents_one_open_per_service` (ADR-004). `open_incident/2` treats the
  constraint violation as "already open" and returns the existing incident, so a
  race ends in one insert and one no-op.
- Opened on the transition to `:down`, resolved on the transition back. The hook
  sits in `ServiceMonitor.transition/3`, the single place a status change passes
  through.
- **Monitors also reconcile at startup** (ADR-008) — without it, restarting with a
  service already down left the outage with no incident.
- Severity from the environment: production `:critical`, staging `:high`,
  development `:medium`. Alert rules replace this in V2.
- `status` cannot be set to `:resolved` through the workflow changeset; resolving
  is its own operation because it also stamps who did it and when.
- Automatic events have a null `user_id`, which is what separates "the monitor
  saw this" from "somebody did this" on the timeline.
- Responding to incidents needs `:respond_to_incidents`, so a `viewer` is locked
  out but a `member` is not.

**Verified against the running app:** breaking the flaky endpoint opened a
critical incident carrying the real failure reason ("unexpected HTTP status 503"),
and healing it resolved the incident automatically after 42 s with both timeline
entries recorded and no author.

### Phase 5 — Real-time dashboard

- `DashboardLive` at `/orgs/:org`, `IncidentLive.Index`/`Show`, and a rebuilt
  `ServiceLive.Show` with the latency chart and the uptime/percentile figures.
- **No polling anywhere.** Every page subscribes on connect and re-reads on a
  broadcast. Only the service detail page subscribes to `service:{id}:checks`.
- Uptime and p50/p95/p99 are aggregated in SQL (`percentile_cont`,
  `count(*) FILTER`). `uptime_by_service/2` is one query for the whole dashboard
  rather than one per service.
- Anything not healthy sorts to the top of the dashboard: the reason to open the
  page is to find what is broken.
- Chart follows the `dataviz` skill: one series so no legend, reserved status
  palette, solid hairline grid, direct labels only on the latest and worst
  readings, a hover column per point, and a `<table>` twin so no value is
  hover-only. Both themes are declared explicitly.
- Icons are [Lucide](https://lucide.dev), installed like heroicons — a `lucide`
  git dep plus a Tailwind plugin in `assets/vendor/lucide.js`, exposed as
  `lucide-<name>` and usable through the existing `<.icon>` component. Each
  status has its own icon, so a badge still reads in greyscale.
- `/` and the post-login redirect now send a logged-in user to their dashboard.

### Phase 6 — Continuous integration and release

- `.github/workflows/ci.yml`: `postgres:17-alpine` service with
  `DATABASE_HOST=localhost`, `deps`/`_build` and the Dialyzer PLT cached
  separately, and steps format → unused deps → compile → credo → test → dialyzer.
- `README.md` now carries the supervision tree, the check cycle, and the reasoning
  behind the parts of the design that look unusual.
- Tagged `v0.1.0` on `main`.

### Phase 7 — Front end and organization management

- **Two navigations became one.** `root.html.heex` was still rendering the user
  menu injected by `phx.gen.auth` above the application header.
- Sidebar shell (`Layouts.app`) with the organization switcher, section
  navigation and user menu, collapsing to a drawer below `lg`; `Layouts.public`
  for the landing and authentication screens.
- **Brand hue is violet on purpose.** Status is the only thing on a monitoring
  screen allowed to shout, and the stock Phoenix orange sat on top of the amber
  used for a degraded service. Violet is far from every status hue and from the
  chart's series blue. daisyUI's `success`/`warning`/`error` are now the exact
  status palette values, so a flash and a badge agree.
- Organization management, which had no UI at all: `/orgs/new`,
  `/orgs/:org/members` and `/orgs/:org/settings`. The rules live in the context —
  the last owner cannot be demoted or removed, and an admin cannot touch an
  owner or create one.
- The members page carries a permission table generated from `Organizations.can?/2`,
  so it cannot drift from what is actually enforced.
- Services list rebuilt around status, uptime and last check, with status and
  environment filters, replacing the generator's nine-column table.
- The service form asks for **seconds** and converts at the boundary.
- Landing page replaces the Phoenix welcome screen; the browser tab no longer
  says "Phoenix Framework".
- Chart gained x-axis time labels. Relative timestamps refresh on a 30 s tick
  that only reassigns the clock and issues no queries.
- Demo controls on the service page break and fix the local endpoint through a
  LiveView event — no HTTP round trip, and hidden outside development.

**Verified against the running app**, signed in through the magic-link flow:
landing, dashboard, services list, service detail (chart with both axes),
members and settings all render; the switcher lists both organizations.

### Phase 9 — Job queue and data retention

- Oban wired into `PulseOps.Application` with `Application.fetch_env!/2` so the
  config is testable; queues disabled and `testing: :manual` in `config/test.exs`.
- `add_oban_tables` migration via `Oban.Migrations.up()/down()`.
- `PulseOps.Monitoring.RetentionJob` — nightly cron job that deletes
  `service_checks` older than a configurable window (`:retention` app config,
  default 30 days).  Accepts a `"days"` arg so tests drive it without touching the
  global config.
- `PulseOps.Accounts.PurgeExpiredTokensJob` — nightly cron job that deletes
  `users_tokens` past their purpose-specific validity (sessions 14 d, magic links
  15 min, change-email tokens 7 d).  Windows live in `UserToken` as public
  accessors so auth checks and the purge job share one source of truth.
- Both jobs live next to their contexts (`Monitoring` and `Accounts`) rather than
  in a generic `jobs/` directory, and call clean context functions
  (`prune_old_checks/1`, `purge_expired_tokens/0`) — the jobs are thin wrappers,
  not owners of logic.
- Context tests cover both functions (backdating via `Repo.update_all ... set:
  [inserted_at: ...]`), and separate job test files exercise the workers through
  `Oban.Testing.perform_job/2`.

### Phase 10 — Alert rules UI and propagation

- Alert *rules* already lived in the context (see PR #3); this phase gives them a
  UI and makes them reach running monitors.
- `AlertRuleLive.Index` at `/orgs/:org/settings/alert-rules` lists the
  organization default and every per-service rule, with severity badges, and gates
  the manage controls behind `:manage_organization` — a viewer sees everything,
  changes nothing. Reached from a card on the organization settings page.
- `AlertRuleLive.Form` creates and edits a rule. A per-service rule is picked from
  a select that offers only services without a rule (plus an "Organization
  default" option only if none exists yet); `degraded_ratio` is entered as a
  percentage and converted at the boundary, like the service form's seconds.
- **Rule changes propagate to running monitors**: creating, editing or deleting a
  rule restarts every monitor that reads it — one for a per-service rule, all of
  them for the organization default — because a monitor reads its rule at boot.
- Fixed a crash-loop this wiring exposed: a probe that lands after its service row
  is gone (sandbox rollback, or a delete racing an in-flight probe) failed the
  `service_checks` foreign key, which crashed the monitor, which the
  `:transient` restart turned into a boot-probe-crash loop. `record_check/3` now
  returns `{:error, :service_not_found}` on that constraint and the monitor stops
  on it instead.

**Verified by tests:** creating a per-service rule restarts the monitor and its
next probe opens an incident at the new severity; editing thresholds takes effect
on the restarted monitor; the organization default restarts every monitor; and
deleting a rule puts the monitor back on the built-in default.

### Phase 11 — Incident notifications (webhook + email)

- A `Notifier` is a delivery channel an organization configures: a generic webhook
  URL (`:webhook`) or an email (`:email`). Both can be paused with `enabled` —
  kept but no longer addressed. The `notifiers` table is organization-scoped and
  optionally narrowed to a single `service_id` (nil = fires for any incident in
  the organization). Email notifiers reach each user assigned via the
  `notifier_assignments` join table (one copy per person); webhooks record the
  responsible people through the same assignments.
- **Webhooks** get a POST of flat JSON (event, incident, service, organization) so
  Discord, Teams, Mattermost, ntfy, Gotify, Make, n8n or a script can consume it
  with no PulseOps schema knowledge. An optional `secret_token` is sent as a
  `Bearer` header. A non-2xx response or a transport error is returned so the job
  retries.
- **Email** is plain text on purpose (pager/phone friendly), delivered via Swoosh.
  The sender defaults are in app config; `runtime.exs` and `prod.exs` read
  `MAILER_FROM`/`MAILER_FROM_NAME` and, when `BREVO_API_KEY` is set, switch the
  adapter to Swoosh's Brevo one with Req as the API client.
- **Delivery is queued, never inline.** `enqueue_incident_notifications/3` — called
  from `PulseOps.Incidents` after an incident opens or resolves — queues one
  `NotifyJob` per matching enabled notifier (matching = enabled, same
  organization, and service-wide or narrowed to the incident's service). Each
  notifier gets its own job and retry
  budget (`max_attempts: 5`), so a slow or down receiver never blocks the monitor.
- `NotifyJob` is deliberately quiet when a notifier or incident is gone by the
  time it runs (deleted, or paused): no error is logged for a channel that no
  longer exists.
- `NotifierLive.Index` lists channels with service scope, Active/Paused pills and
  delete; `NotifierLive.Form` switches a scope dropdown (every service / one) and
  an assigned-members multi-select by type. Manage controls
  are gated behind `:manage_organization`, like alert rules. Both are reached from
  a "Notifications" card on the organization settings page.
- In tests, webhook deliveries go through Req's test plug adapter
  (`config :pulse_ops, webhook_client: :stub`) so nothing touches the network.

**Verified by tests:** payload shape and bearer header, retry on HTTP 500,
no-op on deleted/paused notifier or deleted incident, email subject/body/to and
per-assignee delivery, enqueue-once per matching notifier for both open and
resolve, service narrowing (a notifier for another service does not fire), and
cross-organization service rejection.

### Stabilisation — F1: continuous incident reconciliation

First of the five P0 defects from [`ROADMAP.md`](ROADMAP.md).

- **The bug, confirmed by a failing test before anything was changed.** Incidents
  open on a status *transition*, and a service already at `:down` never
  transitions again. So resolving an incident by hand while the service was still
  broken left the outage running with no incident and no further notifications,
  and it did not heal until the monitor restarted — in production, a redeploy.
  ADR-008's reconciliation ran only in `handle_continue/2` at boot.
- `Incidents.reconcile_incident/3` is the new monitor-facing entry point: it reads
  the current incident state and acts only where it diverges from the status just
  observed. `ServiceMonitor` calls it after every probe that produced no
  transition, and `handle_continue(:reconcile_incident)` now delegates to it
  instead of open-coding the same cases.
- **A manual resolve is a snooze, not a fix.** Reopening is suppressed for
  `:incident_reopen_grace_seconds` after a person resolves an incident on a
  service that has not recovered — `resolved_by_id` is what tells a human's
  resolution from the monitor's. 300 s in production, 0 in the suite so probes
  stay deterministic.
- **The grace period applies to reconciliation only.** A genuine transition back
  to `:down` always opens an incident. A flat window would have swallowed a real
  new outage that started inside it.
- Reopening inserts a **new** incident whose first timeline event is typed
  `:reopened`, so the timeline does not claim the monitor detected something it
  had already reported. The resolved row and the person who closed it are left
  intact. `incident_events.type` is a string column, so no migration was needed.
- See **ADR-009**, which extends ADR-008 from "reconcile at boot" to "reconcile
  continuously" and records why a reconciling *read* is not the failing *insert*
  ADR-008 rejected.

**Verified by tests:** the anchor regression (down → resolved by hand → next
failing probe opens a new incident) plus the timeline event, suppression inside
the grace window, a recovery during the window leaving the manual resolution
standing, and a real recover-then-break-again cycle not being suppressed.

**Verified against the running app**, which is this project's standard and the
scenario that fails silently without the fix. `priv/scenarios/f1_reconciliation.exs`
drives it end to end with real monitors, real HTTP probes against `/dev/flaky`
and real timers, nothing mocked:

```
docker compose run --rm -e PHX_SERVER=true web mix run priv/scenarios/f1_reconciliation.exs
```

It breaks the endpoint, waits for the incident, resolves it by hand while the
service is still broken, confirms nothing reopens inside the grace period,
confirms a **new** incident with a `:reopened` event opens once the grace is
lifted, then heals the endpoint and confirms the monitor closes it on its own.

**`PHX_SERVER=true` is not optional.** Under plain `mix run` the endpoint starts
but never listens, so every probe gets "connection refused" — which still drives
a service down and would look like a passing scenario while proving nothing
about the flaky endpoint. The script now asserts a healthy probe first.


### Stabilisation — F2: one default alert rule per organization

- `unique_index(:alert_rules, [:service_id])` never said what it looked like it
  said. Postgres treats NULLs as distinct from each other, so any number of rows
  with a null `service_id` — the organization default — were legal. The only
  thing preventing a second default was the form hiding the option once one
  existed: check-then-act, no transaction, and bypassable with a crafted submit.
- With duplicates present, `rule_for_monitoring/1` and `get_rule_for_service/2`
  ordered by `is_nil(service_id)` with `limit: 1` and **no tiebreaker**, so which
  rule governed a service was whatever the planner returned.
- Migration `add_default_alert_rule_unique_index` adds
  `alert_rules_one_default_per_organization`, unique on `organization_id` where
  `service_id IS NULL`. Its `up` deletes pre-existing duplicates first, keeping
  the lowest id — the index cannot be created while they exist, and a
  development database may well carry some.
- Both lookups gained `asc: r.id` as a tiebreaker, so resolution is deterministic
  regardless of what the data looks like.
- `AlertRule.changeset/3` declares the constraint, reported against `:service_id`
  because that is the field the user can change. The form guard stays as a
  convenience; it is no longer the guarantee.
- **A test asserted the bug as intended behaviour** ("two org defaults are
  allowed"). It is now inverted, plus one confirming a second organization is
  still free to have its own default.

### Stabilisation — F3: alert rules cannot point at another tenant's service

- `AlertRule.changeset/3` cast `:service_id` with only a `foreign_key_constraint`,
  which says the service exists *somewhere* — not that it belongs to the
  organization creating the rule. `Notifier.changeset/3` already validated this;
  the alert rule did not.
- The impact was not reading another tenant's data — `rule_for_monitoring/1`
  filters by `organization_id` — but **taking the victim's slot in the unique
  index**, so they could never create their own rule for their own service. A
  cross-tenant denial of service through an unvalidated field.
- `validate_service_scope/1` added, mirroring the notifier's, and running after
  `organization_id` is put from the scope so it has something to compare against.
  The check is in the changeset rather than the form, so it holds for any caller.

### Stabilisation — F4: the dashboard coalesces reloads (the cheap half)

- `load_dashboard/1` ran in full on every broadcast: four queries, one of them
  aggregating 24 h of raw `service_checks`. Cost was
  O(viewers × status changes × checks in 24 h), with no debounce and no cache —
  the real scaling ceiling today, well ahead of the number of monitors.
- A broadcast now schedules a deferred `:reload` and sets `reload_pending?`;
  anything arriving while one is pending is absorbed by it. A burst of ten
  messages costs one reload instead of ten.
- `:dashboard_debounce_ms` is 250 in production. In the suite it is **0**, and a
  window of zero re-reads inside the broadcast callback rather than deferring at
  all — see the trap about `send(self(), ...)` landing behind a queued call.
- The debounce is trailing-edge, so a status change takes up to 250 ms longer to
  appear. The README's "nothing polls" claim now says so.
- **Only the cheap half of F4.** The queries themselves still aggregate raw
  checks; the rollups are Phase 2.
- The coalescing test counts the repo queries issued *by the LiveView process* —
  the telemetry handler runs in whichever process ran the query, so filtering on
  the pid keeps a concurrently running test's queries out of the count — and
  asserts a ten-message burst costs exactly what a single message costs.

### Stabilisation — F5: SSRF guard on tenant-supplied URLs

- Both the health checks and the outgoing webhooks fetch a URL somebody typed
  into a form, from inside the network PulseOps runs in. Neither
  `Service.changeset/3` nor `Notifier.changeset/3` did more than an http(s)
  format check, so any tenant could register
  `http://169.254.169.254/latest/meta-data/` or `http://localhost:5432` as a
  "service" and have the dashboard report back its HTTP status and response
  time, on a schedule.
- `PulseOps.Monitoring.UrlGuard` is a pure module: it checks the scheme,
  resolves the host, and rejects loopback, RFC 1918, link-local, CGNAT,
  benchmark, multicast and reserved IPv4, plus unspecified, loopback,
  unique-local and link-local IPv6. **Both IPv4-in-IPv6 forms are unwrapped and
  judged as IPv4**, or `::ffff:127.0.0.1` walks straight past.
- A host resolving to nothing is rejected rather than allowed, so the guard
  cannot fail open. Every address a name answers with must pass — one public
  answer alongside a private one is still a way in.
- **The guard runs twice.** The changeset is not enough: a name can be repointed
  at a private address between saving and fetching (DNS rebinding), and the check
  interval keeps that window open for as long as the service exists. So
  `HealthCheck.Req.check/2` and `WebhookSender.deliver/3` check again immediately
  before the request. A blocked probe is recorded as a failed check carrying the
  reason, rather than silently not happening.
- `:allow_private_targets` is **false in production, true in development and
  test** — plenty of installations exist to watch a private network, and the
  guard would break them. The scheme check applies either way.
- Tested with the ranges spelled out, plus two StreamData properties over IPv4
  host bits — the first use of StreamData, which was declared and unused.

### Stabilisation — F6: retention deletes in batches, on an index

- The only index on `service_checks` was `[:service_id, :inserted_at]`, which
  serves every read — they are all "the latest checks for one service". The
  nightly retention delete filters on `inserted_at` alone, and a composite index
  cannot serve a predicate that does not constrain its leading column. So the
  job was a **sequential scan over the largest table in the schema, every
  night**, and one unbounded `DELETE` holding row locks for as long as it ran.
- New index on `[:inserted_at]`, created `concurrently` with
  `@disable_ddl_transaction` and `@disable_migration_lock`, because this
  migration will one day run against a table with tens of millions of rows.
- `prune_old_checks/2` takes `batch_size` (default 10,000) and deletes in
  bounded batches until a short one says the backlog is exhausted. Postgres has
  no `LIMIT` on `DELETE`, so the batch is picked by an id subquery, which keeps
  the lookup on the new index.
- How long the old statement ran depended on the retention window, which is
  *configurable* — a config change could have put the nightly job on the table
  for minutes. Batching makes each statement short whatever the backlog is.
- The test asserts the batching itself by counting `DELETE` statements through
  Ecto telemetry: 25 expired rows at `batch_size: 10` is three statements, not
  one, and the fresh row survives.

### Stabilisation — repo housekeeping

- `mix.exs` said `0.2.0` while `v0.3.0` was tagged; it now agrees with the tag.
- Deleted the stray empty `.github;W` directory — a shell redirection that
  landed as a filename — and the 7 MB `erl_crash.dump`, which was already
  ignored but still sitting in the working tree.


### Stabilisation — ARCHITECTURE.md brought back in line

`ARCHITECTURE.md` still described the system as it was before Phase 1, which is
the failure mode ADR-006 exists to prevent — it is the "shape of the system"
document, so a stale one is worse than none. Corrected:

- The check-cycle diagram now shows reconciliation on the *unchanged* branch,
  which is where F1 actually hooks in.
- `service_checks` no longer says "pruning is V2 work" (it shipped in Phase 9),
  and now lists both indexes and the batched delete. Rollups stay Phase 2.
- `alert_rules` documents the two unique indexes and why one does not cover the
  other, plus the tenancy validation on `service_id`.
- `incidents` documents the reopen grace and that a reopened outage is a new row.
- A new **Outbound requests** section covers `UrlGuard` and why it runs twice.
- The PubSub section says the dashboard coalesces its re-reads.


### Phase 2 — Metric rollups (the expensive half of F4)

- `service_checks` grows at `86,400 / interval` rows per service per day, and
  both `uptime_by_service/2` and `service_metrics/3` aggregated over those raw
  rows. The cost of opening the dashboard therefore scaled with the **retention
  window**, which is a config value — lengthening it to keep more history would
  have quietly made every page slower.
- `service_check_rollups`: one row per service per hour, built by
  `RollupJob` on a `5 * * * *` cron so the hour it aggregates is finished.
  `roll_up_hour/1` **recomputes and upserts**, so a retry, a backfill overlapping
  a scheduled run, or the same hour rolled twice all converge instead of
  double-counting.
- Reads take complete hours from rollups and the current, still-filling hour from
  raw checks, then add them. `since` is aligned down to the hour, so a "last 24
  hours" figure covers from the top of that hour.
- **Latency is a cumulative histogram, not three percentile columns.** Counts
  merge across hours by addition; percentiles do not — the p95 of a day is not
  the average of 24 hourly p95s and cannot be recovered from them. Hourly
  percentile columns would have produced a plausible, unboundedly wrong number.
  A histogram merges by addition and its error is bounded by the bucket width.
  See **ADR-010**.
- `backfill_service_check_rollups` populates history in one SQL statement at
  migration time. Without it an existing installation would show an empty rollup
  table and the dashboard's uptime would silently narrow to the current hour.

**Verified against the development database**, not only by tests:
`priv/scenarios/rollup_consistency.exs` compared the summed rollups with the raw
aggregation over the same finished hours — **17,247 raw checks across 9 services
reduced to 142 rollup rows, agreeing exactly** on totals, up counts, latency
counts and histogram buckets.


### Phase 2 — F8: the telemetry is consumed

- `[:pulse_ops, :monitoring, :check]` had been emitted since Phase 3 and heard
  by nobody. `PulseOpsWeb.Telemetry` defined the stock Phoenix metrics, which
  only LiveDashboard read, and the reporter line was still commented out.
- `telemetry_metrics_prometheus_core` keeps a Prometheus-shaped set in ETS,
  separate from `metrics/0`: the two reporters want different shapes, and a
  Prometheus histogram needs explicit buckets LiveDashboard has no use for.
- Exported: probe counts and a response-time histogram by status, Oban job
  outcomes and queue time by worker, request duration by route, query time, and
  VM memory. **Nothing is labelled with a `service_id`** — cardinality would
  grow with every tenant's every service, and per-service figures already live
  in the database and on the dashboard. Prometheus watches PulseOps; the
  database watches the services.
- `/metrics` sits on its own pipeline — no session, no CSRF, no layout — behind
  `MetricsAuth`. **No token configured means 404, not 401**, so an installation
  that never set one does not advertise that it has metrics. The comparison is
  `Plug.Crypto.secure_compare/2`; `==` leaks the token's prefix to anyone
  willing to measure. `METRICS_TOKEN` at runtime, a fixed one in dev.
- Status transitions and the incident lifecycle now log `service_id`,
  `organization_id` and `incident_id` as **metadata rather than interpolated
  prose**, so an aggregator can filter on them. `Oban.Telemetry.attach_default_logger`
  turns a failing job into a log line instead of silence.

**Verified against the running app** with
`priv/scenarios/metrics_endpoint.exs`: 401 with no token, 401 with a wrong one,
200 with the right one, and real series
(`pulse_ops_monitoring_check_count{status="healthy"} 6`) with no `service_id`
label anywhere in the output.


### Phase 2 — F7: rule changes propagate without restarting anything

- A rule change used to restart every affected monitor: stop the process, wait
  for the registry to release its name, boot a replacement — **once per service,
  in sequence, from the LiveView that saved the rule**. An organization-wide
  rule made that O(number of services) of blocking work; the roadmap's estimate
  was up to 50 seconds at 100 services.
- `ServiceMonitor.rule_changed/1` casts instead. Each monitor re-reads its own
  rule in its own process, so nothing waits on anything else and the caller
  returns immediately.
- **The cast does something a restart could not.** A restart discarded the
  failure and success tallies, so a threshold lowered to 1 still needed a fresh
  probe to bite. The monitor now applies the new thresholds to what it has
  already counted, so the change takes effect at once and no information is
  thrown away.
- `MonitorSupervisor.stop_monitor/1` waits for `Process.monitor`'s `:DOWN`
  instead of sleeping in 10 ms steps for up to half a second. The registry's
  own cleanup still cannot be awaited — it drops its entry when *it* handles the
  `:DOWN`, in its own process, with no message to subscribe to — so that part
  keeps a bounded check, now yielding with `Process.sleep(0)` rather than idling.
- `status/1` reports the thresholds the monitor is actually running on, which is
  the only way to observe that a change reached it.
- The four propagation tests asserted the *mechanism* (the pid changed). They
  now assert the outcome — the new thresholds are in force — **and** that the
  pid did not change. A cast from the test process is ordered ahead of a call
  made from it afterwards, so they need no polling.


### Phase 2 — the status state machine is pure, and property-tested

- `next_status/3`, `tally/2` and the degraded check were private functions of
  `ServiceMonitor`, entangled with its I/O. `PulseOps.Monitoring.StatusMachine`
  now holds them: no processes, no database, no clock. The monitor keeps a
  `%StatusMachine{}` in its state and asks it.
- The behaviour worth testing there is **hysteresis** — down needs sustained
  failure, recovery needs sustained success — and hysteresis bugs only appear
  over *sequences*, which are expensive to explore through a GenServer and cheap
  through a function. That is the whole reason for the split.
- Five StreamData properties: entering `:down` always took `failure_threshold`
  consecutive failures, leaving it always took `success_threshold` consecutive
  successes, a short run of failures never moves the status, the two counters
  are never both running, and the status is always a known one.
- **The first version of the "two open incidents" property could not fail.** It
  derived incident opens and closes from *status changes*, so they alternated by
  construction whatever the machine did. It was replaced by the properties above,
  which are what that invariant actually rests on; the database holds the
  invariant itself (ADR-004). The replacements were **checked by mutation**:
  weakening the threshold comparison to `>= threshold - 1` fails two of the five
  properties and two example tests.
- `ServiceMonitor.status/1` reports the thresholds in force, which is how a test
  observes that a rule change reached a running monitor.


### Phase 2 — coverage with a threshold in CI

- `mix test --cover` now runs in CI and in `mix check`, with
  `summary: [threshold: 90]` in `mix.exs`. Verified that it actually gates:
  raising the threshold to 99 exits 3, and 90 exits 0.
- The threshold is a **ratchet set just under what the suite achieves** (91.30%),
  so it catches a drop rather than inviting tests written to move a number.
- `ignore_modules` excludes test support — counting `DataCase` and the fixtures
  flatters the figure, since they are exercised by definition — the dev-only
  `/dev/flaky` demo modules, and generated shells with no logic of ours.
- **Chasing the number found a real gap.** `HealthCheck.Req` was at 0%: every
  test swaps the whole behaviour for a Mox mock, so the real client, *including
  the SSRF guard F5 added to it*, was never executed. It now has the same
  `Req.Test` seam the webhook sender has (`health_check_transport: :stub`) and
  six tests covering the response mapping and the guard — including one asserting
  a private target is refused **without any request being attempted**.


### Phase 3 — public status page

- `/status/:slug`, unauthenticated, live over the same PubSub topics the
  signed-in dashboard uses. The roadmap's star feature: it turns "I watch my
  services" into "my customers watch my services", and it is what makes the
  project demonstrable without handing anyone credentials.
- **All unauthenticated reads live in `PulseOps.StatusPage`.** Everywhere else a
  context function takes a `%Scope{}` whose holder got through
  `on_mount :require_organization`; this breaks that on purpose, so it is one
  file to review rather than `public_`-prefixed functions sitting next to scoped
  ones. See **ADR-011**.
- **The queries name their columns.** A service's `url` is usually an internal
  hostname — it is why `UrlGuard` exists — and an incident's `cause` and timeline
  are written by staff for staff. None are fetched at all, so the guarantee is
  not "the template does not render it" and cannot be undone by editing markup.
- **Two flags, because they answer different questions.**
  `organizations.status_page_enabled` is off until somebody turns it on;
  `services.public` defaults to **true**, because publishing a page is a
  statement about what you are watching and a page that starts empty reads as
  broken rather than as careful.
- An organization that has not published is **indistinguishable from one that
  does not exist** — both 404 — so the page cannot be used to find out who has
  an account here.
- `Scope.for_public_organization/1` carries the organization with no user and no
  role, so the existing read functions filter by tenant exactly as for a member
  while `Organizations.can?/2` denies every action. The visitor goes through the
  same authorization code path, not a parallel one.
- Published from organization settings, with its own form. The handler takes
  only the two status page fields, so the control cannot become a second way to
  rename the organization or move its slug — there is a test that tries.

**Verified against the running app** with `priv/scenarios/status_page.exs`: 404
before publishing and for a slug that never existed, the public service listed
and the held-back one absent, and neither the service URL, its hostname, a member
email, nor the incident cause anywhere in the HTML.


### Phase 3 — F9: deployable for real

- **`Dockerfile`** (production) beside the existing `Dockerfile.dev`: a two-stage
  `mix release` shipped on a runtime with no Mix, no build tools and no source,
  running as a non-root user. 296 MB.
- **`PHX_HOST` is mandatory.** It defaulted to `"example.com"`, which booted
  happily and put a hostname nobody owns into every generated link — magic-link
  logins, and the incident URLs in webhook and email notifications. The release
  now refuses to boot without it, with a message saying what it is for.
- **`bin/migrate` and `bin/server` are separate entry points.** Migrating on
  boot races every other replica starting at the same moment. `PulseOps.Release`
  is the eval target, because `mix ecto.migrate` does not exist in a release.
- `DATABASE_SSL` defaults to **true** with `verify_peer` against the OS CA
  bundle; `false` is the deliberate opt-out for a database on a private network.
- **`force_ssl` was already enabled** in `config/prod.exs` — the roadmap's F9
  claim that it was still commented out is wrong. What is commented out is the
  explanatory block in `runtime.exs`. Verified in the running image: HTTP gets a
  301 to HTTPS and served responses carry HSTS.
- The **one-node deployment constraint** is now written down in
  `ARCHITECTURE.md` and the README, which the roadmap asked for explicitly:
  every node starts a monitor for every service, so a second replica duplicates
  probes, checks and notifications.

**Verified by building and running the image**, which is the only way any of
this can be verified: migrations applied to a fresh database from the release,
the server booted, HTTP redirected to HTTPS, HSTS present, `/metrics` 401 then
200 with its token, assets served digested and gzipped, `whoami` is `pulseops`,
and `mix` is absent from the image.


### Phase 3 — configurable checks

- A probe was `Req.get(url)` with no options, so PulseOps could only watch
  endpoints that are public, answer GET, and say everything they mean in the
  status line. A service now carries `http_method`, `request_headers`,
  `request_body`, `expected_status` and `body_assertion`.
- **Every column defaults to the old hardcoded behaviour**, so an existing
  service is probed exactly as before.
- `expected_status` null means any 2xx; an integer means exactly that, which is
  how you watch an endpoint whose healthy answer is a 204, or one that proves it
  is alive by answering 401.
- **`body_assertion` is the point of the whole item.** It catches a service that
  is up, answering 200, and saying in its payload that it is not well — the
  failure a status code cannot see. Checked *after* the status, so a 503 is
  reported as a bad status rather than as a missing string.
- Methods are GET, HEAD and POST. PUT, PATCH and DELETE are deliberately absent:
  nothing that changes state on the far side belongs on a schedule.
- **Header injection is rejected in the changeset.** A line break in either half
  of a header lets a tenant append headers of their own to a request PulseOps
  makes on their behalf. Names must also be RFC tokens, which is what turns a
  line the form could not parse into "that is not a header name". Count, length
  and a HEAD-with-body-assertion contradiction are checked too.
- Headers are a textarea of `Name: value` lines, parsed into a map at the form
  boundary — the same place the seconds-to-milliseconds conversion happens. A
  map is not something an HTML form can post, and a repeating-row widget is a
  lot of machinery for something everyone can already read.
- **A header value is stored as written**, so a token sits in the database in
  plain text exactly like `notifiers.secret_token` does. That is the same known
  P2 debt, now with a second place to fix; the form says so.

**Verified against the running app** with
`priv/scenarios/configurable_checks.exs`, including the case that matters: a
service pointed at `/dev/flaky`, which answers **200**, is correctly reported
**down** because the body does not contain what the service requires.


### Phase 3 — JSON API with organization tokens

- `pipeline :api` had been declared and unused since bootstrap. Behind it now:
  services (list, show, create, update, delete) and incidents (list, show,
  workflow update, resolve) at `/api/v1`.
- **The API restates no authorization.** A token produces a `%Scope{}`, and the
  controllers call the same context functions the LiveViews call, so every
  tenant filter and role check applies unchanged. The SSRF guard, the
  alert-rule tenancy check and the "resolving is not a workflow status" rule all
  hold over HTTP without being mentioned there. See **ADR-012**.
- **A token has no permissions of its own.** It names the person who created it
  and takes its role from their membership *at request time*, so it can never
  outrank its owner, weakens when they are demoted, and stops working entirely
  when they leave the organization. There is a test for each.
- **Only the hash is stored.** The token is shown once and cannot be recovered —
  unlike `notifiers.secret_token`, which is kept in the clear because it has to
  be *sent* on every delivery. Recognising something needs no more than its hash.
- Missing, malformed, unknown and revoked tokens all answer 401 with the same
  body, and another tenant's id answers 404 rather than 403: either distinction
  would confirm something exists.
- **The API found a latent bug.** `resolve_incident/3` did
  `Map.put(attrs, :resolved_by_id, ...)`, which produced a map of mixed atom and
  string keys as soon as the attrs came from JSON. It never showed through the
  LiveView, which passes an empty map. `resolved_by_id` is now `put_change`d
  rather than cast — which is also what the project's own convention says about
  fields set programmatically.
- `PulseOps.Accounts.User` gained `@type t`, which every other schema already
  had; without it a `@spec` naming it failed Dialyzer with `unknown_type`.

**Verified against the running app** with `priv/scenarios/json_api.exs`, over
real HTTP with a real token: 401 unauthenticated, 201 on create, 422 carrying
the SSRF guard's own message, 404 for another tenant, resolve credited to the
token's owner, 409 on a second resolve, a demoted owner's token reading but not
writing, and 401 the moment it is revoked.


### Phase 3 — email invitations

- `add_member/3` could only add somebody already registered, and its own `@doc`
  said so while the README promised "invite people". Invitations close that gap.
- **One field does both.** The members page adds whoever already has an account
  and invites whoever does not, which is what it should have done from the start
  — the old copy said "the person must already have a PulseOps account", a dead
  end at exactly the moment somebody is bringing a colleague in.
- **Accepting creates the account, confirms it, adds the membership and signs
  them in**, in one transaction. Holding the link proves control of the mailbox,
  which is precisely what the magic-link login already accepts as proof — so
  making the invitee register, log in, and find the invitation again would be
  three steps proving nothing the first click had not. See **ADR-013**.
- **Accepting is a POST, and this is the part that matters.** A `GET` is followed
  by mail scanners, link-rewriting proxies and browser prefetchers, none of which
  asked to join anything. The page offers; the form accepts. The scenario checks
  exactly this: fetching the page creates no account.
- Single use, expires in 7 days, stored only as a hash. Re-inviting replaces the
  pending link rather than leaving two live ones.
- **Expired, accepted, withdrawn and unknown tokens all render the same page**,
  because saying which would report whether an address had ever been invited.
- Somebody added by hand between the invitation being sent and opened is not an
  error: the invitation is spent and they are let in with the membership they
  already have.
- The email goes through `PulseOps.Mailer`, not `Notifications.Mailer`: an
  invitation is account correspondence, not an incident alert, and has to work
  whether or not a tenant has configured a provider.

**Verified against the running app** with `priv/scenarios/invitations.exs`, over
real HTTP and driving the form the way a browser does, CSRF token and session
cookie included: the page readable with no session, **fetching it creating no
account**, the POST creating a confirmed account and a membership, and a second
POST refused.


### Phase 4 — maintenance windows

- A planned deploy looked exactly like an outage: probes fail, an incident
  opens, everyone on the notifier list is woken up for something somebody
  scheduled. The roadmap calls this the number one failure of any alerting
  system in real use.
- A window is a time range, optionally narrowed to one service. **Probes still
  run, checks are still recorded, the status still changes** — what is held back
  is the incident. Stopping the checks would leave a hole in the history exactly
  where somebody later asks "was it already broken before the deploy?".
- **The check is in `Incidents`, not in `transition/3`.** The roadmap said the
  transition is the single gate, and it *was* — until F1 gave incidents a second
  way to open. Suppressing only the transition would have silenced new outages
  and not the one the window was scheduled for, because a service already down
  would get an incident from reconciliation on its next probe. Both paths funnel
  into `insert_incident/4`. See **ADR-014**.
- **Nothing schedules the end of the silence.** When a window finishes with the
  service still broken, the next probe reconciles and opens an incident then,
  carrying a `:reopened` event. That is F1 paying for itself — the roadmap
  expected Oban here and no job is needed.
- Notification suppression falls out of it rather than being a second rule: no
  incident opened, so there is nothing to announce. A *recovery* during a window
  is still announced, because that is not a page in the night.
- The public status page announces a running window and marks the services it
  covers, and its banner says "Down for planned maintenance" rather than
  crying outage.
- Windows are capped at 31 days, validated against the tenant like alert rules
  and notifiers, and a database constraint refuses one that ends before it
  starts.
- **A test caught a real bug**: a window aimed at a service the status page does
  not publish was still putting that service's id into the map the page reads by
  id. The coverage assertion had started life as a brittle substring count in the
  web test; moving it to the context, where it could be precise, is what found it.

**Verified against the running app** with
`priv/scenarios/maintenance_windows.exs`: `/dev/flaky` genuinely broken, probes
genuinely failing, the service genuinely reading down — **and no incident**. Then
the window is cancelled and the very next probe opens one, by reconciliation.


### Phase 4 — anti-flapping, digests and escalation

- `enqueue_incident_notifications/3` fired 1:1 with no suppression, so a service
  sitting on its threshold produced a storm, and there was no way to say
  "somebody is on this" or "nobody is, make more noise".
- **Flap detection counts incidents, not raw checks.** Every threshold crossing
  already produces one incident row with a `started_at`, so counting those is one
  indexed query and no new bookkeeping — and it measures *the thing people
  actually receive* rather than oscillations nobody was told about.
- A flapping service stops sending per-incident messages and schedules one
  `DigestJob`, **unique per service**, so everything arriving while it waits
  collapses into it. Nine crossings became one message in the scenario.
- **The digest counts when it runs, not when it was scheduled.** At schedule time
  only the first crossing has happened; the interesting number is the total.
- **Escalation is decided at the end, not cancelled at the start.** A critical
  incident schedules an `EscalationJob`; when it runs it re-reads the incident and
  does nothing unless it is still open and still unacknowledged. Cancelling a
  scheduled job instead would mean getting it right in three places — acknowledge,
  resolve and automatic recovery — and this is one check in one place.
- **Acknowledgement is its own field, not a workflow status.** `:investigating`
  says something about the incident; acknowledging says somebody has it. In the
  first minute both are true and neither implies the other. See **ADR-015**.
- `notifiers.escalation_only` keeps a channel quiet for ordinary incidents. An
  escalation reaches **everybody**, including the people already told — nobody
  picked it up, so more noise is the intent.

**Verified against the running app** with
`priv/scenarios/flapping_and_escalation.exs`: the first line paged and the second
silent, eight further crossings producing exactly one digest, the escalation
reaching the escalation-only channel, and acknowledging making a re-run send
nothing.


### Phase 4 — TLS certificate expiry

- An expired certificate takes a service down as surely as a crashed process,
  and it is the one outage that announces itself weeks in advance to anybody who
  looks. Nothing was looking.
- A daily Oban job reads every enabled `https` service's certificate and stores
  the expiry. **Daily, not per probe**: a certificate changes at most once in its
  life, and per-probe would be a handshake every thirty seconds to learn a date
  that moves once a quarter.
- **The handshake does not verify the certificate.** That looks alarming and is
  the point: an expired, self-signed or wrong-name certificate all fail
  verification, and those are exactly the cases somebody needs told about.
  Verified against `expired.badssl.com`, which returned `2015-04-12` — a date a
  verifying connection could not have produced. See **ADR-016**.
- **It does not open an incident.** The service is up. An incident would put a
  false outage in the uptime figures and page somebody for what needs a calendar
  entry. It goes out through the ordinary channels with its own webhook event.
- `tls_warned_for` stores **which** expiry was warned about, not a boolean.
  Renewing moves the expiry, so the next one warns in its turn; a flag would
  either repeat daily or go silent for ever after the first time.
- The service page shows a notice inside the window, red once expired, and says
  the service itself is fine so it does not read as an outage.

**Coverage caught two real gaps rather than one nuisance.** Adding this dropped
the total to 88.92% and `mix test --cover` exited 3, as it is supposed to. Two of
the three uncovered modules were the email and the delivery job — genuinely
untested, now tested. Only the socket module is excluded, and its parsing was
first extracted into `TlsCheck.Certificate` so the fiddly part (two time formats
and RFC 5280's two-digit-year pivot at 2049) is covered directly.


### Phase 4 — UX: time windows, incident pagination, monitor health

- **Time windows on a service.** Uptime and the percentiles read over 24 hours,
  7 days or 30 days, chosen in the URL (`?window=7d`), so a view can be linked
  and survives a reload; an unknown value falls back to 24 hours rather than
  erroring. Thirty days used to mean aggregating a month of raw checks per page
  view; with hourly rollups (ADR-010) it is cheap. The chart and the check bar
  still show the last 60 probes whatever the window — and now say so.
- **Incident pagination and filtering.** The list was the 50 most recent and
  nothing else, so the 51st incident silently stopped existing on that page. It
  is now paged 25 at a time and filterable to open or resolved, both in the URL.
  One extra row is fetched to answer "is there another page?" without a count
  query. **`started_at` has one-second resolution**, so incidents opened in the
  same second had no order, and offset pagination over them showed some twice
  and others never; `id` breaks the tie — the same lesson as F2. A live update
  refreshes the page being read instead of bouncing the reader to page one.
- **Monitor health.** `Monitoring.monitor_state/1` says whether anything is
  actually watching a service: running, stopped, disabled, or not applicable
  (monitors never run in the test suite, so their absence means nothing there).
  An enabled service with no monitor now says "Nothing is watching this service"
  instead of showing its last status as though it were current.
- **The delete confirmation already existed.** The roadmap listed it as missing;
  the services list had carried a `data-confirm` naming what goes with a service
  since before this phase. It is now pinned by a test so it cannot quietly go.
- **Building monitor health surfaced F10**, a real defect in the supervision
  tree, not part of the original audit. `MonitorSupervisor`'s restart intensity
  is supervisor-wide, so one monitor crashing six times in a minute terminates
  the `DynamicSupervisor` with every monitor under it, and nothing starts them
  again. Verified with a scratch script that killed one service's monitor seven
  times and found a second, healthy service unwatched afterwards. **Not fixed
  here**: it is a change to the supervision design. It is recorded as F10 in
  `ROADMAP.md`, and `ARCHITECTURE.md` — which claimed the opposite — is corrected.
  Fixed in its own commit, next section.

### Stabilisation — F10: a restart budget per service

- **Each monitor has a supervisor of its own** (ADR-017). `MonitorSupervisor`
  starts one `MonitorContainer` per service as a temporary child; the container
  supervises that service's `ServiceMonitor` with `max_restarts: 5,
  max_seconds: 60`. Those were always the right numbers — they were attached to
  the supervisor every monitor shared, so they were a budget for all of them
  together.
- **A container that gives up stays down.** Being temporary, it is never
  restarted and never counted against `MonitorSupervisor`. The service reads as
  "Nothing is watching this service" until it is edited.
- **A monitor that stops normally takes its container with it.** It is a
  significant child and the container has `auto_shutdown: :any_significant`, so
  a deleted service does not leave an empty container holding its name.
- **"Watched" means a container exists**, not a monitor. A monitor restarting
  inside its budget is briefly unregistered, and the service page should not
  flicker to "stopped" for that.

**Verified by tests, including against the bug.** The regression test kills one
service's monitor five times (each restarted), then a sixth (given up on), and
asserts the other service's monitor is the *same pid* under the *same*
`MonitorSupervisor`. With `MonitorSupervisor` temporarily put back to starting
monitors directly under a shared 5/60 budget, it failed with the other monitor
gone — which is F10. The first version of the test did not fail that way; see
the trap below.

**Verified against the running app** with `priv/scenarios/f10_isolation.exs`:
two real services probing `/dev/flaky`, one monitor killed five times (restarted
each time) and a sixth (given up on, reported "not watched"), while the other
kept the same pid under the same `MonitorSupervisor` and recorded a healthy probe
afterwards; editing the given-up service watched it again. Needing that second
service to stay *healthy* is what exposed `/dev/flaky` answering 401 — fixed in
the commit before this one.

## Next steps

**See [`ROADMAP.md`](ROADMAP.md).** A full audit of the codebase on 2026-09-09
found nine defects that are not recorded in this file, five of them P0, so the
next work is stabilisation rather than new features:

1. ~~A manually resolved incident never reopens while the service is still down~~
   — fixed, see the F1 section above and ADR-009.
2. ~~Several organization-default alert rules can exist~~ — fixed by a partial
   unique index, see the F2 section above.
3. ~~`AlertRule` does not validate that `service_id` belongs to the tenant~~ —
   fixed, see the F3 section above.
4. ~~The dashboard reloads four queries on every broadcast~~ — debounced, see
   the F4 section above. The queries themselves are still Phase 2 work.
5. ~~Service and webhook URLs allow SSRF into the internal network~~ — fixed
   by `UrlGuard`, see the F5 section above.

Metric rollups (the original V2 item) are Phase 2 there, together with
observability and hot rule propagation. Activity log, clustering with leader
election, and Prometheus/OpenTelemetry export remain later phases. The partial
unique index (ADR-004) is already what makes the clustering step safe.

## Traps already hit

- `mix phx.new .` refuses a non-empty directory without an interactive `Y`; pipe
  `yes Y` into it when scripting.
- `phx.new` generates some editor-tooling files that are not part of the project;
  they are excluded locally rather than through `.gitignore`.
- `_build` and `deps` are named volumes shadowing the bind mount. Anything that
  needs to be visible on the host must not live there.
- **Never set `MIX_ENV` in `Dockerfile.dev`.** An explicit value overrides the env
  `mix test` picks for itself, so the suite silently ran against dev config and
  failed with "cannot invoke sandbox operation with pool DBConnection.ConnectionPool".
- Elixir 1.20 warns about files under `test/support` not matching the test filters;
  `test_ignore_filters` in `mix.exs` handles it.
- Dialyzer flags `call_without_opaque` on every `Multi.new() |> Multi.insert(...)`
  chain under OTP 28 — an upstream Ecto/MapSet opacity issue. Filtered narrowly in
  `.dialyzer_ignore.exs`; `list_unused_filters: true` means the build complains if
  the filter ever becomes unnecessary.
- `user_fixture/0` now creates a personal organization as a side effect of
  registration. Tests that count a user's organizations must account for it.
- `DynamicSupervisor.terminate_child/2` returns once the process is dead, but the
  Registry drops its entry only when it handles the `:DOWN`. `stop_monitor/1`
  therefore waits for the name to be released, or `restart_monitor/1` would fail
  with `{:already_started, <dead pid>}`.
- **A property test can be structurally incapable of failing.** The first
  "no two open incidents" property derived incident opens and closes from status
  *changes*, so they alternated by construction no matter what the state machine
  did. Mutating the implementation is the cheap way to find this out: if
  weakening the code does not fail the property, the property was decoration.
- **A Swoosh mailbox is per test process and keeps everything.** Every fixture
  user that registers sends a confirmation email, so `assert_email_sent/1` reads
  *that* one unless the mailbox is drained after the fixtures and immediately
  before the assertion. Draining once in `setup` is not enough when a test
  creates more users than the setup did.
- **Stopping a monitor mid-query breaks the shared sandbox for the rest of the
  test.** A monitor's boot probe writes to the database within a second of it
  starting. `stop_monitor/1` called in that window kills the process while it
  holds the shared connection, the sandbox disconnects, and every later query in
  the test fails with an `OwnershipError` naming the *test* process — nothing
  about monitors. Start the monitor explicitly, `assert_receive` its
  `{:check_recorded, _}`, then make a `ServiceMonitor.status/1` call to be sure
  the callback returned, and only then stop it.
- **A regression test that reads the fix's own structure cannot catch the bug.**
  The first F10 test decided "given up" by the container being absent. Against
  the old code there were no containers at all, so it concluded "given up" after
  the first kill, stopped, and passed with the bystander untouched. Waiting only
  on things both versions have — the monitor's own name — and killing exactly six
  times is what made it fail against the bug. Run the test against the unfixed
  code before trusting it.
- **`GenServer.stop/2` returning does not mean the name is free.** The registry
  drops the entry when it handles the `:DOWN`, so `ServiceMonitor.whereis/1` can
  still return the dead pid for a moment afterwards.
- **A private helper called `path/3` is not called inside HEEx.** The
  verified-routes import defines `path/3`, and in a template the import wins, so
  the compiler reported a `~p` error about an argument the helper never had.
- **Swoosh's `assert_email_sent/1` runs `assert fun.(email)`**, so the function
  has to end in something truthy — and `refute` evaluates to `false` even when it
  passes. A closure ending in a `refute` fails the assertion it is inside.
- **`mix check`'s last line is Dialyzer's, not the suite's.** Grepping for
  "passed successfully" reported success while `mix test --cover` had already
  exited 3 on the coverage threshold. Check the exit status, not the prose.
- **`Oban.Testing.perform_job/3` calls the worker directly** and does not consume
  the scheduled row, so a job stays queued after it has been run in a test.
- **Application env is global, so a test that flips it cannot be `async: true`.**
  `UrlGuardTest` toggles `:allow_private_targets` and, while async, failed
  unrelated modules whose fixtures were saving a service URL at that moment. The
  same applies to any test setting `:incident_reopen_grace_seconds` or
  `:dashboard_debounce_ms` — those live in modules that run their tests in order.
- Monitor tests must be `async: false` with `set_mox_global`: the monitor and its
  probe tasks are separate processes, so they need the shared sandbox connection
  and a globally visible mock.
- The check is broadcast from inside the same callback that updates the status,
  so receiving `{:check_recorded, _}` does not mean the callback finished. Follow
  it with a `GenServer.call` to synchronise before asserting on status.
- `/dev/flaky/break` must not sit on the `:browser` pipeline: CSRF protection
  rejects the POST with a 403.
- A `<form>` with `phx-change` needs an `id`, or LiveView warns on every render.
- `{:ok, check} = Repo.insert(...)` is not crash-proof once probes can outlive
  their service: a check that lands after the row is gone fails the foreign key,
  and under a `:transient` monitor that means a crash → restart → boot probe →
  crash loop. `record_check/3` reports `{:error, :service_not_found}` instead, and
  the monitor stops cleanly.
- `{...}` inside a HEEx template is interpolation even inside `<pre><code>`; the
  ASCII diagram on the landing page needs `phx-no-curly-interpolation`.
- `attach_hook(:handle_params)` raises for a LiveView not mounted through the
  router, which is how the `on_mount` unit tests call it — guard on `socket.router`.
- `deps/` and `_build/` are Docker named volumes: they do **not** exist on the
  host. Check anything in them from inside the container.
- **`.gitignore` does not untrack what is already tracked.** 3.2 MB of Dialyzer
  PLT binaries were committed before the ignore rule existed and stayed in the
  repository until `git rm --cached` removed them.
- CI runs in the project's own image (ADR-007). `erlef/setup-beam` installs an
  OTP build missing `dialyzer`'s `erl_bif_types.beam`, which made Dialyzer fail
  while every other step passed.
- **A CSS mask does not scale to its box.** Lucide ships its SVGs with
  `width="24" height="24"`, which gives the mask an intrinsic size, so every icon
  rendered at 24px no matter what size utility was on the element — larger than
  its container and clipped. Heroicons ship without those attributes, which is
  why they never showed it. `assets/vendor/lucide.js` now strips them and sets
  `mask-size: 100% 100%` — but **only from the opening `<svg>` tag**. Many Lucide
  icons are drawn out of `<rect>` elements (`layout-dashboard` and `server` are
  nothing else), and stripping width/height from those collapses the shapes.
- **`attr` and `slot` declarations attach to the next function definition.** A
  private helper defined between them and `def app/1` silently stole the attrs
  and every page using the layout crashed with `BadMapError`.
- **Registering a user already creates their personal organization**, whose slug
  comes from the email local part. A scenario script that registers
  `checks-123@…` and then creates an organization named `Checks 123` collides
  with it, because both slugify to `checks-123`.
- **A release ships the builder's ERTS, so the two Docker stages must agree on
  their Debian.** Building on `elixir:1.20-otp-28` (trixie, glibc 2.41) and
  running on `debian:bookworm-slim` (glibc 2.36) produced an image that built
  cleanly and died on boot with `libm.so.6: version GLIBC_2.38 not found`. The
  Dockerfile comment warned about exactly this and the first version did it
  anyway — which is why the image is booted as part of the check, not assumed.
- **`rel/overlays` only reaches the release if `rel/` is in the build context.**
  Without `COPY rel rel` the image builds fine and `bin/server` and
  `bin/migrate` simply are not in it.
- **Git Bash rewrites container paths.** `docker run ... /app/bin/migrate`
  becomes `C:/Program Files/Git/app/bin/migrate`. `MSYS_NO_PATHCONV=1` stops it.
- **`mix run` starts the endpoint but does not listen.** Only `mix phx.server` or
  `PHX_SERVER=true` makes it serve. A scenario script probing the app's own
  `/dev/flaky` under plain `mix run` gets "connection refused" on every probe,
  which drives the service down and can look like the scenario working.
- **`send(self(), msg)` does not jump the queue.** The dashboard debounce first
  deferred with `send(self(), :reload)` when the window was zero, on the theory
  that a mailbox delivery beats a timer. It does, but the reload message is
  appended *behind* a `render` call already sitting in the mailbox, so a test
  rendering right after a broadcast intermittently saw the previous state. A
  zero window now re-reads inside the callback and defers nothing.
- `Float.round/2` rejects integers. Plot coordinates land on whole numbers often
  enough that the chart crashed on any real data; `round2/1` coerces first. The
  LiveView tests missed it because none of them rendered a service that had
  checks — there is now one that does.
- **`/dev/flaky` answered 401 to every probe from the JSON API commit on.** It was
  routed through the `:api` pipeline to dodge CSRF, and that pipeline later gained
  `ApiAuth`. Dev routes are not compiled in the test environment, so no test
  could notice; a scenario that breaks the endpoint cannot either, because a 401
  is a failure too. It surfaced only when the F10 scenario needed a bystander
  service to stay *healthy*. The endpoint now has a pipeline of its own that
  only accepts JSON. A route borrowing a pipeline for one plug inherits every
  plug added to it later.

## Open questions

- Live reload inside the container has not been exercised yet with a real file edit.
  If it does not fire, switch `config/dev.exs` to `live_reload: [backend: :fs_poll]`.
