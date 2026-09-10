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

## ADR-010 — Metrics come from hourly rollups, and latency is a histogram

**Decision.** `service_check_rollups` holds one row per service per hour, built
by an hourly Oban job that recomputes and upserts rather than appending.
`uptime_by_service/2` and `service_metrics/3` read rollups for every complete
hour and raw `service_checks` for the current, still-filling one, and add the
two together. `since` is aligned down to the hour.

Latency is stored as a **cumulative histogram** — `latency_le_100` is the number
of checks in that hour answering in 100 ms or less — plus a count, a sum and a
maximum. Percentiles are interpolated out of the merged histogram.

**Why rollups.** `service_checks` grows at `86,400 / interval` rows per service
per day; 100 services at 30 s is about 29M rows a month. Both figures on the
dashboard aggregated over those raw rows, so the cost of opening a page scaled
with the *retention window* — a configuration value. Someone lengthening
retention to keep more history would have made the dashboard slower with no
obvious connection between the two. Against the development database this
replaced 17,247 raw rows with 142 rollup rows for the same numbers.

**Why a histogram and not three percentile columns.** Counts merge across hours
by addition, so uptime over a day is exact from 24 rollup rows. Percentiles do
not merge. The p95 of a day is neither the average of 24 hourly p95s nor the p95
of them, and there is no way to recover it from them. Storing hourly percentiles
would have produced a number that looks authoritative and is wrong by an amount
nobody can bound.

A cumulative histogram does merge by addition, because each bucket is a count.
Summing `latency_le_100` across 24 rows gives the true number of sub-100 ms
checks in the day, and a percentile interpolated from the merged buckets is
wrong by at most the width of the bucket it lands in. That is the trade actually
being made: **bounded error instead of unbounded error**, in exchange for eight
integer columns.

**Rejected.** *Hourly p50/p95/p99 columns.* Simpler, and quietly wrong — the
failure mode is a plausible number, which is worse than an obviously missing one.

*t-digest or a similar sketch.* Mergeable and far more accurate in the tail, and
a great deal of machinery to maintain for a health-check response time where
bucket-width error is already well inside what anyone acts on.

*Rolling up the current hour too.* The row would be stale the moment the next
probe landed, and reads would have to correct for it anyway. Reading the current
hour from raw checks costs one bounded query — an hour of one service is at most
360 rows at the minimum interval.

*Dropping raw checks once rolled up.* The chart on the service page plots
individual probes, and an incident's cause is often a single slow response.
Retention already handles that, separately and on its own schedule.

**Consequence.** Aligning `since` down to the hour means a "last 24 hours"
figure covers from the top of that hour, so up to 25 hours. The alternative was
a third query for the partial leading hour, which is a lot of machinery for a
window whose edge nobody reads to the minute.

A new installation needs its history rolled up once, which
`backfill_service_check_rollups` does in one SQL statement at migration time.
Without it, every finished hour would simply be missing from the dashboard.

---

## ADR-011 — Unauthenticated reads live in one context, and select their columns

**Decision.** The public status page reads through `PulseOps.StatusPage`, a
context of its own, and nowhere else. Its queries name the columns they return
rather than loading schemas. An organization publishes nothing until
`status_page_enabled` is set, and a service appears only while its own `public`
flag is set. `Scope.for_public_organization/1` builds a scope carrying the
organization with no user and no role, so the existing read functions filter by
tenant exactly as they do for a member while `Organizations.can?/2` denies
every action.

**Why a separate context.** Everywhere else, a context function takes a
`%Scope{}` whose holder got through `on_mount :require_organization`. That is
the property the whole tenancy design rests on (ADR-001), and the status page
breaks it on purpose: anybody with a URL can call these functions. Spreading
that exception through `Monitoring` and `Incidents` as `public_`-prefixed
functions would put unauthenticated reads next to authenticated ones, where the
next person to add a function has to notice which kind they are writing. One
module is one file to review, and its name says what it is.

**Why the queries select columns.** A service's `url` is frequently an internal
hostname — it is the reason `UrlGuard` exists. An incident's `cause` and its
timeline are written by staff for staff. If those columns were loaded and simply
not rendered, the guarantee would live in a template, and templates get edited
by people who did not read this file. Not fetching them means no future markup
change can leak one, and the test that asserts it is checking something the
database enforces rather than something the current markup happens to do.

**Why two flags.** They answer different questions. `status_page_enabled` is
"does this organization publish at all", and it is off until somebody turns it
on. `services.public` is "does this service belong on the page", and it defaults
to **true**, because turning the page on is a statement about the things you are
watching; a page that starts empty and needs every service ticked reads as
broken rather than as careful. The URL is withheld either way, so the default
discloses a name and a status, not an address.

**Rejected.** *One organization-level flag only.* It forces a tenant watching
both a public API and an internal admin host to choose between publishing both
or neither.

*Defaulting `services.public` to false.* Safer in the abstract, and it makes
enabling the page look broken, which in practice means people leave it off.

*Reusing `list_services/1` and `list_incidents/2` with a synthetic scope.* It
works — the scope is only read for its organization id — and it would return
full schema structs with `url` and `cause` loaded, putting the guarantee back
into the templates.

**Consequence.** An organization that has not published is indistinguishable
from one that does not exist: both raise `StatusPageLive.NotFound` and answer
404. The page cannot be used to discover who has an account here.

---

## ADR-012 — The API is a second way in, not a second domain

**Decision.** A token authenticates by producing a `%Scope{}`, and every API
controller then calls the same context function a LiveView calls. There is no
authorization logic in `PulseOpsWeb.Api`: the tenant filter and the role check
are already inside `Monitoring` and `Incidents`, and they apply because the
scope is the same shape.

A token names the **person** who created it and carries no role of its own. The
role is read from that person's membership at request time.

Only the hash is stored. The token is shown once, at creation, and cannot be
recovered.

**Why the scope.** `pipeline :api` had been declared and unused since bootstrap,
and the tempting thing to write behind it is a set of `api_`-prefixed context
functions. That is how two halves of an application drift: a rule gets added to
one and forgotten in the other, and the one that gets forgotten is the one
without a UI to notice it. Because tenancy and roles were already parameters of
the domain rather than properties of a session (ADR-001), an API needed no new
rules at all — which is the thing worth having proved. The SSRF guard, the
alert-rule tenancy check, the "resolving is not a workflow status" rule: all of
them apply over HTTP without being mentioned there.

**Why a token has no role of its own.** A token with independently settable
permissions is a second permission system, and it outlives the reason it was
granted — the classic form being a token that still works long after the person
who made it left. Reading the role from the owner's membership on each request
means a token can never outrank its owner, loses power the moment they are
demoted, and stops working entirely when they leave.

**Why only the hash.** A token here only has to be *recognised*, and recognising
something needs no more than its hash. This is deliberately unlike
`notifiers.secret_token`, which is stored in the clear because it has to be
*sent* on every delivery — a different requirement, not a different standard.

**Rejected.** *Tokens with their own role or scopes.* More flexible, and a
second thing to keep in agreement with membership. Worth revisiting only when
somebody actually needs a token weaker than its owner.

*Organization-wide tokens belonging to nobody.* Simpler, and then a resolved
incident has no author — `resolved_by_id` would be null for every API action,
and the timeline would stop distinguishing "the monitor saw this" from
"somebody did this", which is the whole point of that column (ADR-008).

*Deleting a revoked token's row.* Keeping it means a token that turns up in a
log later can still be identified as one already dealt with.

**Consequence.** A missing, malformed, unknown and revoked token all answer 401
with the same body: distinguishing them would say whether a token had ever
existed. Another tenant's id answers 404 rather than 403, for the same reason.

---

## ADR-013 — An invitation is a login that also grants a membership

**Decision.** `add_member/3` could only add somebody who had already registered.
Invitations cover the case it could not: an address with no account here. The
link is emailed, stored only as a hash, single use, and expires in seven days.

Accepting **creates the account if there is none, confirms it, adds the
membership and signs the person in** — all in one transaction. The invitation
page is public and only *offers* to accept; accepting is a `POST`.

**Why accepting can create and sign in.** This application already treats
control of a mailbox as proof of identity: that is exactly what the magic-link
login is. An invitation link is delivered to one address and proves the same
thing, so making the invited person register separately — and then log in, and
then find the invitation again — would be three steps that prove nothing the
first click had not already proved. Confirming the account on the spot follows
for the same reason.

**Why accepting is a POST.** A `GET` is followed by mail scanners, corporate
link-rewriting proxies and browser prefetchers, none of which asked to join
anything. A link that acted on being fetched would produce memberships nobody
consented to, and would burn the invitation before its recipient ever saw it.
The page offers; the form accepts. `phx.gen.auth` confirms accounts the same
way, for the same reason.

**Why one field does both.** The members page used to say "the person must
already have a PulseOps account", which is a dead end at exactly the moment
somebody is trying to bring a colleague in. It now adds whoever is already
registered and invites whoever is not, which is what the README had been
claiming all along.

**Rejected.** *Making the invitee register first and then redeem.* More
conventional, and it fails the most common case — the person clicks the link,
finds a registration form, and has no idea the two are connected.

*Storing the token in the clear.* There is no reason: it only has to be
recognised, like the API tokens (ADR-012).

*Letting an invitation be accepted by whoever is signed in.* An invitation is
addressed to an address. Binding it to the email means a forwarded link cannot
quietly add the wrong account.

**Consequence.** An expired, accepted, withdrawn and unknown token all render
the same page, because saying which would report whether an address had ever
been invited. Re-inviting replaces the pending invitation rather than leaving
two live links.

Somebody added by hand between the invitation being sent and opened is not an
error: the invitation is spent and they are let in with the membership they
already have.

---

## ADR-014 — Maintenance suppresses the consequence, not the monitoring

**Decision.** A maintenance window is a time range, optionally narrowed to one
service. During it, probes still run, checks are still recorded and the service's
status still changes — what does not happen is that an **incident opens**. The
check lives in `Incidents`, in the one private function both paths into an
incident go through.

Nothing schedules the end of the suppression. When a window finishes with the
service still broken, the next probe reconciles and opens an incident then
(ADR-009).

**Why suppress the consequence and not the checks.** Stopping the probes during a
window would be simpler and would produce a hole in the history exactly where
somebody later wants to know what happened — "was it already broken before the
deploy?" is the first question after a bad release, and it is unanswerable if
nothing was recorded. Recording everything and holding back only the paging keeps
the dashboard, the uptime figures and the chart honest.

**Why in `Incidents` and not in `ServiceMonitor.transition/3`.** The roadmap said
`transition/3` is the single gate, and it *was* — until F1 gave incidents a
second way to open, through reconciliation. Suppressing at the transition alone
would leave a service that was already down when the window started getting an
incident from the reconciliation on its next probe: the window would silence
new outages and not the one it was scheduled for. Both paths funnel into
`insert_incident/4`, which is where the check belongs.

**Why nothing schedules the un-suppression.** A timer that reopens incidents when
a window ends is a second mechanism that can fail, drift, or fire against a
service that recovered in the meantime. Reconciliation already asks "is this
service down with no incident?" on every probe, so the silence lifts itself, and
the incident that follows carries a `:reopened` event that says how it came
about. This is F1 paying for itself.

**Rejected.** *Pausing the monitors.* Loses the history and needs the monitors
restarted afterwards, which is the O(n) blocking work F7 removed.

*Suppressing the notifications instead of the incidents.* The incident would
still open, so the dashboard, the status page and the incident list would all
show an outage nobody was told about — the worst of both.

*Suppressing the resolution too.* Telling people something recovered is not a
page in the night, and withholding it would make the timeline lie.

**Consequence.** An incident already open when a window starts is left alone: a
window says "expect trouble from now on", not "forget what is already broken".
A window is capped at 31 days, because beyond that it is not maintenance, it is
a service nobody wants to hear about — and the way to say that is to disable it.

---

## ADR-015 — Flap detection counts incidents, and escalation is decided at the end

**Decision.** A service that has opened `flap_threshold` incidents inside
`flap_window_seconds` is treated as oscillating. Its per-incident notifications
stop and a single `DigestJob` is scheduled instead, made unique per service so
everything arriving while it waits collapses into it. The digest counts when it
**runs**, not when it was scheduled.

A critical incident schedules an `EscalationJob` for
`escalation_after_seconds` later. When that job runs it re-reads the incident
and does nothing unless it is still open and still unacknowledged.

Acknowledgement is its own field, not a workflow status. Notifiers gain
`escalation_only`, which keeps a channel silent until an escalation.

**Why count incidents rather than track transitions.** A flap is a service
crossing its threshold repeatedly, and every crossing already produces exactly
one incident row with a `started_at`. Counting those is one indexed query and
needs no new bookkeeping — and, more usefully, it measures **the thing people
actually receive**. A definition based on raw check results would count
oscillations nobody was ever told about, which is not what "flapping" means to
somebody being paged.

**Why the digest counts at run time.** The interesting number is how often the
service moved *in total*, and at schedule time only the first crossing has
happened. Counting late means the message describes what occurred rather than
what had occurred when the storm began.

**Why escalation is decided when the job runs.** The alternative is to find and
cancel the scheduled job when somebody acknowledges or resolves. That means
knowing the job's id, handling the case where it has already started, and
getting it right in three places — acknowledge, resolve, and the automatic
recovery. Re-reading the incident at the end is one check in one place, and it
is correct by construction: whatever happened in between, the question asked is
the one that matters.

**Why acknowledgement is not a status.** Moving an incident to `:investigating`
says something about the incident; acknowledging says something about the
people — somebody has this. In the first minute of an outage both are true and
neither implies the other, and conflating them means you cannot say "I have seen
this" without also claiming to have diagnosed it.

**Rejected.** *Suppressing notifications with an Oban `unique` on `NotifyJob`
alone.* Collapses duplicates but says nothing: the receiver gets one arbitrary
message out of ten and no indication that ten happened.

*Escalating to a fixed second address.* An organization's second line is a
channel like any other, and modelling it as one means it inherits the service
narrowing, the pausing and the assignment that already exist.

*Escalating only to the escalation-only channels.* Nobody picked the incident
up, so making **more** noise is the intent; excluding the people already told
would make an escalation quieter than the page that preceded it.

**Consequence.** An escalation-only channel with nothing else configured hears
nothing at all, which is correct and can look like a broken configuration — the
form says so where it is set.

---

## ADR-016 — TLS expiry is read without verifying, checked daily, and is not an incident

**Decision.** A daily job reads the certificate of every enabled `https` service
and stores its expiry. A certificate inside the warning window is announced
through the ordinary notifier channels, once per expiry. It does **not** open an
incident.

The handshake is made with `verify: :verify_none`.

**Why not verify.** The job is to read the date the host presents. A certificate
that has already expired, is self-signed, or carries the wrong name all fail
verification — and those are exactly the cases somebody most needs told about.
Verifying would turn "your certificate expired last night" into a connection
error with no date in it, which is the least useful possible answer. Nothing is
trusted as a result: the only thing taken from the peer is a date, used to decide
whether to warn a human. Reading it against `expired.badssl.com` returned
`~U[2015-04-12 23:59:59Z]`, which a verifying connection could not have told us.

**Why daily rather than per probe.** A certificate changes at most once in its
life. Checking on every probe would be a TLS handshake every thirty seconds per
service to learn a date that moves once a quarter.

**Why not an incident.** The service is up. Opening an incident would conflate
"broken" with "will break", put a false outage in the uptime figures, and page
whoever is on call for something that needs a calendar entry rather than a
response. It is a warning with a date on it, which is a different thing to
receive — and it carries its own webhook event so a receiver can route it
differently.

**Why `tls_warned_for` holds a date, not a boolean.** Renewing a certificate
moves the expiry, and the next one deserves its own warning. A boolean would
either warn every day of the window or go silent for ever after the first time.
Recording *which* expiry was warned about makes "warn once per certificate" fall
out of a comparison.

**Rejected.** *Checking during the health probe.* Free in the sense that a
connection is already being made, and it is an HTTP connection, not a raw TLS
one — the certificate is not exposed at that layer without reaching past Req.

*Storing only "days remaining".* It goes stale the moment it is written. The
expiry is the fact; the days are a rendering of it, computed when needed —
which is also why the delivery job recomputes rather than trusting the number it
was queued with.

**Consequence.** `TlsCheck.Ssl` is the network seam and is excluded from
coverage, like the other places the suite replaces I/O. Everything it does with
what comes back — two time formats and RFC 5280's two-digit-year pivot at 2049 —
lives in `TlsCheck.Certificate`, which is pure and tested directly.

---

## ADR-017 — Every monitor gets a supervisor of its own

**Decision.** `MonitorSupervisor` no longer supervises monitors. It starts one
`MonitorContainer` per service — a plain `Supervisor` whose only child is that
service's `ServiceMonitor` — as a `:temporary` child. The container carries the
restart budget, `max_restarts: 5, max_seconds: 60`. `MonitorSupervisor` has no
budget of its own to speak of, because it never restarts anything.

**Why.** Restart intensity is a property of a supervisor, not of a child. The old
`DynamicSupervisor` had `max_restarts: 5, max_seconds: 60`, which reads as "give
up on a monitor after five crashes" and meant "give up on *all* of them after
five crashes between them". A sixth crash of one monitor in a minute terminated
the supervisor and every monitor in every organization, and `Bootstrapper` does
not run twice, so nothing came back until the application restarted (F10). The
numbers were right; they were attached to the wrong process.

**Why temporary containers.** A container that exceeds its budget exits. If
`MonitorSupervisor` restarted it, that restart would be counted against
`MonitorSupervisor` — the shared budget again, one level up, and a service with a
crash at boot would still eventually take everything down. A temporary child is
never restarted, so it is never counted. The service is left unwatched, and it
says so: `Monitoring.monitor_state/1` reports `:stopped`, and the service page
shows "Nothing is watching this service". Editing the service restarts it.

**Why the monitor is significant.** A monitor stops *normally* when its service
row disappears under it. The container would otherwise live on empty, holding the
service's name in the registry. `auto_shutdown: :any_significant` makes that
normal exit shut the container down too.

**Rejected.** *Raising `max_restarts` on the shared supervisor.* Moves the cliff
instead of removing it; with enough services, crashes across all of them add up
to any number.

*Counting crashes inside `ServiceMonitor` and stopping itself.* Re-implements
supervision by hand, and cannot count a crash that kills the process before it
has written anything down.

*A `:one_for_one` supervisor with `restart: :temporary` monitors and a separate
process watching for their `:DOWN` to restart them with a backoff.* It would add
backoff, which a container does not have, but it is a supervisor built by hand
next to one that already exists. Worth revisiting if a service that crashes at
boot should be retried after a minute rather than left until it is edited.

**Consequence.** Two processes per service instead of one, which at the scale of
a monitor per service is nothing. `stop_monitor/1` terminates the container and
waits for both registry names to be released. "Is this service watched?" asks
about the container, so a monitor in the middle of a restart inside its budget
does not flicker to "stopped".

---

## ADR-018 — Webhook tokens are encrypted at rest under a key derived from `SECRET_KEY_BASE`

**Decision.** `notifiers.secret_token` is stored as AES-256-GCM ciphertext
(`PulseOps.Vault`, through the `Vault.EncryptedString` Ecto type), redacted from
`inspect`, and never rendered back into a page. The key is derived with PBKDF2
from a key base in the application environment, which in production is the
`SECRET_KEY_BASE` the endpoint already requires.

**Why not a hash.** An API token only has to be *recognised*, so `Api.Token`
stores its hash and nothing else. A webhook token has to be *sent*, on every delivery, so
PulseOps must be able to recover it. The choice is between plain text and
reversible encryption, and plain text meant anyone with a database dump, a
backup or a read replica held every receiver's credential.

**Why derive from `SECRET_KEY_BASE` rather than a new variable.** It is already
mandatory, already secret, and already has to be managed as such. A second
variable would be one more thing a deployment can forget, for no gain in the
threat this addresses — someone holding the database but not the application's
environment. The domain reads it from its own config key, set from the same
value, so `PulseOps` never reaches into `PulseOpsWeb` configuration.

**Why GCM and a random IV.** Authenticated, so a tampered or foreign value is
refused instead of decrypting into a different token. A fresh IV per value, so
notifiers that share a token do not visibly share a ciphertext. A version byte
leads the format, so a future format can tell rows apart without guessing.

**Why the form never shows it.** A password input still carries a `value`
attribute, and the core input fills it from the form, so the stored token sat in
the page source of every edit screen. The field is now always empty; blank on
save means "keep", and removing a token is a separate, explicit checkbox —
otherwise saving any other change would silently delete it.

**Rejected.** *Cloak.* A well-made library, but it brings a vault process, a
cipher configuration and key tags for what is one field; the whole of
`PulseOps.Vault` is shorter than the configuration it would replace.

*pgcrypto.* The key would travel in SQL, where it lands in logs and
`pg_stat_statements`.

*Failing soft on a value that will not decrypt.* Reading it as nil would turn a
changed key into webhooks failing later for no visible reason.

**Consequence.** Rotating `SECRET_KEY_BASE` makes every stored token unreadable,
and loading an affected notifier raises. After a rotation, each webhook's token
has to be entered again; `config/runtime.exs` says so where the variable is read.
There is no re-keying tool yet — it would be a small task if rotation becomes
routine. The migration converts existing rows in Elixir, because the key must
never appear in SQL, and therefore depends on `PulseOps.Vault`.

**The same decision covers `services.request_headers`**, which is where an
`Authorization` header for a check lives. The map is JSON-encoded and encrypted
(`Vault.EncryptedMap`) and redacted. The service form shows header *names* with
every value masked, because it cannot know which header is a credential; a line
left masked keeps the value already known for that name, resolved in the
LiveView's assigns and never sent to the page — including a value typed a moment
ago and masked by a re-render. Header values must be printable ASCII, as HTTP
requires, which also guarantees a mask with nothing behind it is refused rather
than sent.

---

## ADR-019 — Sign-in attempts are limited per email, and per address only behind a trusted proxy

**Decision.** Password logins, magic-link requests and registrations are limited
per email, always, and per client address only when `TRUSTED_PROXY` says every
request comes through a proxy that appends the address to `X-Forwarded-For`.
The address is then the *rightmost* entry of that header. Counters are
fixed-window, in an ETS table owned by `PulseOpsWeb.RateLimiter`.

| Action | Per email | Per address |
|---|---|---|
| Password login (failures only) | 5 / 15 min | 50 / 15 min |
| Magic-link request | 3 / 15 min | 20 / 15 min |
| Registration | 3 / hour | 10 / hour |

**Why not simply the peer address.** PulseOps is deployed behind a proxy that
terminates TLS, so the peer is the proxy. A limit on it is one limit shared by
everybody, and whoever trips it locks every user out — a rate limiter turned
into a denial of service.

**Why not `X-Forwarded-For` unconditionally.** The client writes that header.
If the app is reachable around the proxy, or the proxy passes the header through
unchanged, every attempt can claim a new address and the limit is decoration.
Only the operator knows whether that is the case, so it is a setting, off by
default. The rightmost entry is used because it is the one the proxy appended;
anything to its left came from the client.

**Why per email as well.** It needs no trust in the network: it stops one
account being guessed at, and one inbox being flooded with magic links or
confirmation emails by somebody typing it into a form. It is also all that
applies without a trusted proxy.

**Why password failures only, checked first.** A person who types their
password correctly should never lock themselves out. The check happens before
the password is verified, so a refused attempt runs no bcrypt — otherwise the
limit would refuse the login but still spend the CPU at the attacker's rate.
Magic links and registrations count every request, because every request can
send an email.

**Why fixed windows.** The purpose is to make guessing slow, not to meter
precisely. A burst across a window boundary gets through at up to twice the
limit, which does not change how long guessing takes. A sliding window would
mean keeping timestamps per key for that.

**Rejected.** *Hammer or PlugAttack.* Both would do, and both bring
configuration and a backend abstraction for three counters on one node; the
limiter is under a hundred lines.

*A 429 status.* These are browser forms; the person needs the form back with a
message, not an error page.

**Consequence.** Counts live on one node and reset if the limiter process
restarts — an acceptable failure towards letting people in, and consistent with
PulseOps running as a single node until there is leader election. The refusal
message is the same whether or not the email has an account, so the limit does
not become a way to enumerate them. The LiveView socket now carries
`:x_headers` in its connect info, which is how the login and registration pages
see the proxy's header.

---

## ADR-020 — An incident's announcement is queued in its own transaction, and fanned out by a job

**Decision.** Opening or resolving an incident inserts one
`PulseOps.Incidents.EventJob` inside the same `Ecto.Multi` as the incident and
its timeline event. That job, when it runs, decides everything that follows:
which notifiers match, whether the service is flapping and gets a digest
instead, whether a critical incident schedules an escalation.

**Why.** All of that used to run after the commit, in the process that opened
the incident — almost always a `ServiceMonitor`. Every transition to or from
`:down` cost the monitor a service reload, a flap count over recent incidents, a
notifier query, a bulk insert of delivery jobs and possibly an escalation
insert, on the process whose job is to probe on time. Worse, it was not atomic:
anything that stopped the process between the incident committing and the jobs
being inserted — a crash, a deploy, a lost connection — left an incident that
nobody was ever told about. A monitoring tool that silently drops the one
notification that matters has failed at its purpose.

**Why an Oban job in the transaction.** It is a transactional outbox without a
new table: the job row commits with the incident or rolls back with it, and
Oban is already what delivers, retries and prunes. The monitor's path gains one
insert inside a transaction it was already running.

**Rejected.** *A PubSub subscriber that enqueues on `{:incident_opened, _}`.*
At-most-once: a subscriber that is restarting, or a node going down with the
message in flight, loses the announcement — the failure this removes. It would
also put every organization's fan-out behind one process.

*Keeping the direct call and inserting the delivery jobs inside the Multi.* It
fixes atomicity but keeps the notifier query, flap count and escalation logic on
the monitor's path, and keeps `Incidents` knowing how notifications are routed.

**Consequence.** The fan-out sees the world as of when the job runs, a moment
later: a notifier created in between is included, and the flap count includes
whatever else has happened by then — the same count a person looking at the
timeline would make. If queuing the deliveries fails the job retries, and a
retry after a partial fan-out can repeat a delivery; that requires the bulk
insert of delivery jobs itself to report discarded rows, and a duplicate message
is the better failure than none. `Incidents` still reads flap tuning from
`Notifications`, which is configuration, not routing. Tests that assert on
deliveries run the pending announcements first (`announce_incident_events/0`).

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
