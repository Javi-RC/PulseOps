# Progress

Living record of where the project stands. Updated in the same commit as the code
of each phase. **Read this first when picking the work back up.**

## Current state

| | |
|---|---|
| Branch | `develop` |
| Phase | 7 complete — front end rebuilt, organization management shipped |
| Next | V2 — Oban, alert rules, notifications, activity log, metric rollups |
| Checks | `mix check` green: 329 tests, Credo `--strict` clean, Dialyzer clean |

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
- Added: Oban (declared, unused until V2), Credo, Dialyxir, Mox, StreamData.
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

## Next steps — V2

Nothing here is started. In rough order of what adds most:

1. **Oban** for work that should not sit in a monitor's callback: notifications,
   and pruning `service_checks`, which is the fastest-growing table by far.
2. **Alert rules** — replace the hardcoded thresholds in `ServiceMonitor`
   (`@failure_threshold`, `@success_threshold`, `@degraded_ratio`) and the
   environment-based severity in `Incidents.severity_for/1` with configurable rules.
3. **Notifications**: Slack and generic webhooks first, email second.
4. **Metric rollups** so uptime and percentiles stop scanning raw checks, plus a
   retention policy.
5. **Activity log** for auditability.

Then V3: clustering with leader election so several nodes do not duplicate checks,
Prometheus/OpenTelemetry export, and load and chaos testing. The partial unique
index (ADR-004) is already what makes the clustering step safe.

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
- Monitor tests must be `async: false` with `set_mox_global`: the monitor and its
  probe tasks are separate processes, so they need the shared sandbox connection
  and a globally visible mock.
- The check is broadcast from inside the same callback that updates the status,
  so receiving `{:check_recorded, _}` does not mean the callback finished. Follow
  it with a `GenServer.call` to synchronise before asserting on status.
- `/dev/flaky/break` must not sit on the `:browser` pipeline: CSRF protection
  rejects the POST with a 403.
- A `<form>` with `phx-change` needs an `id`, or LiveView warns on every render.
- `{...}` inside a HEEx template is interpolation even inside `<pre><code>`; the
  ASCII diagram on the landing page needs `phx-no-curly-interpolation`.
- `attach_hook(:handle_params)` raises for a LiveView not mounted through the
  router, which is how the `on_mount` unit tests call it — guard on `socket.router`.
- `deps/` and `_build/` are Docker named volumes: they do **not** exist on the
  host. Check anything in them from inside the container.
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
- `Float.round/2` rejects integers. Plot coordinates land on whole numbers often
  enough that the chart crashed on any real data; `round2/1` coerces first. The
  LiveView tests missed it because none of them rendered a service that had
  checks — there is now one that does.

## Open questions

- Live reload inside the container has not been exercised yet with a real file edit.
  If it does not fire, switch `config/dev.exs` to `live_reload: [backend: :fs_poll]`.
