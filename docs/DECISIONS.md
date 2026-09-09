# Decisions

Short architecture decision records. Each one states the alternative that was
rejected, because that is the part that is expensive to reconstruct later.

---

## ADR-001 — Multi-tenancy through Phoenix Scopes, from day one

**Decision.** Tenancy is expressed with Phoenix 1.8 Scopes. `PulseOps.Accounts.Scope`
carries `user`, `organization` and `role`. An `organization` entry in
`config :pulse_ops, :scopes` gives generated resources a `organization_id` foreign key
and a `/orgs/:org` route prefix keyed on the organization slug.

**Why.** Scopes push the tenant filter into every generated context function, so
"forgot to filter by organization" — the classic broken-access-control bug — stops
being something to remember. Retrofitting tenancy onto single-tenant schemas means
rewriting every context, query, LiveView and test at once.

**Rejected.** Starting single-tenant and adding organizations in a later phase.
Cheaper this week, disproportionately expensive later.

**Consequence.** Ordering constraint: the `organization` scope config must exist
*before* running any `mix phx.gen.* --scope organization`, or the generators emit
unscoped code.

---

## ADR-002 — Health checks run in a supervised Task, not inline in the GenServer

**Decision.** `ServiceMonitor` does not call the HTTP client from `handle_info`. It
spawns the request with `Task.Supervisor.async_nolink/2` and collects the outcome as
a message (`{ref, result}`, plus a `:DOWN` clause for a crashed task).

**Why.** A monitor is a single process with a single mailbox. A synchronous request
with a 5 s timeout blocks that process for 5 s: it cannot answer a `GenServer.call`,
cannot be reconfigured, and cannot be stopped cleanly. With hundreds of services and
one slow endpoint, the naive version stalls its own scheduling. `async_nolink` also
means a crashing request cannot take the monitor down with it.

**Rejected.** Calling `Req.get/2` directly inside the callback. Simpler to read, and
wrong for anything past a toy dataset.

---

## ADR-003 — One PubSub topic per organization, and broadcasts only on state change

**Decision.** The dashboard subscribes to `organization:{id}:services` and `organization:{id}:incidents`.
Individual check results go to `service:{id}:checks`, which only the service detail
page subscribes to. A monitor broadcasts a status message only when the status
actually changes.

**Why.** A per-service topic would mean N subscriptions per connected client and N
teardowns on navigation. And a service checked every 30 s produces a steady stream of
identical "still healthy" results; pushing each one re-renders every open dashboard
for no visible change.

**Rejected.** A topic per service, and broadcasting every check.

---

## ADR-004 — Partial unique index guarantees one open incident per service

**Decision.** `CREATE UNIQUE INDEX ON incidents (service_id) WHERE resolved_at IS NULL`.
Incident creation runs in an `Ecto.Multi` and treats a unique-violation as "already
open", not as an error.

**Why.** Whether a service has an open incident is a database invariant, not an
application convention. An application-level `if not exists` check races with itself,
and will definitely race once V3 runs several nodes. Enforcing it in Postgres makes
clustering safe without revisiting this code.

**Rejected.** Checking for an existing open incident in Elixir before inserting.

---

## ADR-008 — Monitors reconcile incidents at startup, not only on transitions

**Decision.** Incidents are opened and closed on a status *transition*, but a
monitor also reconciles once in `handle_continue/2` when it starts: a service
recorded as down gets an open incident, a service recorded as healthy has any
stale open incident closed.

**Why.** Transitions alone leave a hole across restarts. A monitor for a service
already stored as `:down` starts in `:down`, never transitions, and so never
fires the hook — the outage would exist with no incident attached to it. This was
not hypothetical: it showed up the first time the application was restarted with
a service already down, and no incident appeared. The invariant worth holding is
"a down service has an open incident", and it has to survive restarts and crashes,
which is exactly what supervision is supposed to give.

**Rejected.** Calling `open_incident/2` after every check while down. It is
idempotent thanks to ADR-004, but it means an insert that fails on the constraint
on every single probe, for as long as the outage lasts.

---

## ADR-009 — Reconciliation is continuous, not only at startup

**Decision.** Extends ADR-008. A monitor reconciles incident state after *every*
probe that does not produce a status transition, not only once in
`handle_continue/2` at boot. The decision itself moved into the context, as
`Incidents.reconcile_incident/3`: it reads the current state and acts only where
it diverges from what the monitor just observed.

Resolving an incident by hand on a service that has *not* recovered is read as
"snooze this outage", so reconciliation waits `:incident_reopen_grace_seconds`
(300 s in production, 0 in the test suite) before reopening. Only this path is
suppressed — a genuine transition back to `:down` always opens an incident.
Reopening creates a **new** incident row whose first timeline event is typed
`:reopened`, rather than reviving the resolved one.

**Why.** ADR-008 held the invariant "a down service has an open incident" across
restarts, but only across restarts. Between them, the incident hook fires only on
a status *transition*, and a service already sitting at `:down` never transitions
again. So anything that removed the incident while the outage continued — in
practice, a person resolving it in the UI — left the service down indefinitely
with no incident and no further notifications, and it did not heal until a
redeploy. That is the exact invariant ADR-008 exists to protect, so the fix
belongs at the same level: reconcile on the cycle the monitor already has.

The grace period is what keeps this from fighting the user. Without it the next
probe undoes a deliberate action seconds later, which is both useless and a
notification storm. Splitting transitions from reconciliation is what keeps the
grace period honest: a flat "do not reopen for five minutes" would also swallow a
genuinely new outage that started inside the window.

**Rejected.** *Calling `open_incident/2` after every check while down* — which is
what ADR-008 rejected, and still the wrong shape: it is an insert that fails on
the unique constraint on every single probe for the whole outage. Reconciliation
reads first and writes only on divergence, so a steady outage costs one indexed
`SELECT` per probe, served by the partial unique index that already exists.

*A separate reconciliation timer, or a periodic Oban job.* The probe cycle is
already the natural reconciliation period and is bounded below by the minimum
check interval. A second mechanism would add scheduling, jitter and failure modes
for no gain in coverage.

*Having `resolve_incident/3` notify the monitor.* It couples a user-facing
context function to a process, and it only closes the hole we happened to think
of. The invariant should hold regardless of *how* the incident went missing.

*Reopening the resolved incident row.* It would erase the resolution and the
person who made it, and the partial unique index (ADR-004) makes a second row
free anyway. Two rows tell the truth: somebody closed this, and the outage
carried on.

**Consequence.** `incident_events.type` gained `:reopened`. The column is a
string, so no migration was needed.

---

## ADR-005 — Monitors never start themselves in the test environment

**Decision.** `config :pulse_ops, start_monitors: false` in `config/test.exs`; the
bootstrapper honours it. Tests that need a monitor start it explicitly and grant it a
database connection with `Ecto.Adapters.SQL.Sandbox.allow/3`.

**Why.** Auto-started monitors would issue real HTTP requests during the suite —
slow, flaky, and dependent on the network. They would also check out connections
outside the Ecto sandbox, producing ownership errors that look like unrelated bugs.

**Rejected.** Letting them start and stubbing the network globally.

---

## ADR-006 — Project state is documented in the repository, not in tooling

**Decision.** The three files in `docs/` are the project's memory:
`ARCHITECTURE.md` for the shape of the system, `DECISIONS.md` for why it is
shaped that way, and `PROGRESS.md` for where the work currently stands.
`PROGRESS.md` is updated in the same commit as the code of the phase it describes.

**Why.** Anyone picking the work back up — after a break, or joining it — needs the
current state and the reasoning behind the awkward parts. Neither is recoverable
from the code or the git history at a reasonable cost, and both go stale
immediately if updating them is a separate chore from the work itself.

**Consequence.** A phase is not finished until its state is written down. The
quality bar for `PROGRESS.md` is that someone with no context can read it and
know what to do next.

---

## ADR-007 — The whole toolchain runs in Docker

**Decision.** No Elixir or Erlang on the host. `mix` is always
`docker compose run --rm web mix ...`. `_build` and `deps` are named volumes layered
over the bind mount.

**Why.** Elixir is not available through winget on this machine, and the named
volumes keep Linux-native BEAM artefacts off the Windows filesystem, which is
otherwise the dominant cost of every recompile.

**Rejected.** Installing Erlang via winget plus the standalone Elixir installer, with
only Postgres containerised. Better inner-loop latency, worse parity with CI.

**Consequence.** CI runs inside the same image, as a job container, rather than
installing a toolchain of its own. That is not only tidiness: the OTP build
`erlef/setup-beam` provides ships without `erl_bif_types.beam`, so Dialyzer could
not start on it at all while every other step passed. A CI that installs its own
toolchain is a second environment to keep in agreement, and it drifted.
