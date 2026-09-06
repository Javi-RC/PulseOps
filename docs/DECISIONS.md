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

**Decision.** The dashboard subscribes to `org:{id}:services` and `org:{id}:incidents`.
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
