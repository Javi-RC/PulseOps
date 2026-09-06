# Progress

Living record of where the project stands. Updated in the same commit as the code
of each phase. **Read this first when picking the work back up.**

## Current state

| | |
|---|---|
| Branch | `develop` |
| Phase | 1 complete — Authentication and multi-tenancy |
| Next | Phase 2 — Services CRUD, scoped to the organization |
| Tests | 136 passing, Credo `--strict` clean |

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

## Next steps

Phase 2 — Services CRUD:

1. `mix phx.gen.live Monitoring Service services name:string description:text
   environment:string url:string check_interval_ms:integer timeout_ms:integer
   enabled:boolean status:string last_checked_at:utc_datetime --scope organization`
2. Turn `environment` and `status` into `Ecto.Enum`; validate the URL scheme and
   that `timeout_ms < check_interval_ms`; unique index on `(organization_id, name)`.
3. Enforce `:manage_services` in the context for writes, not just in the UI.
4. Add the `/orgs/:org` route scope with `on_mount :require_organization` — nothing
   uses that hook yet, so Phase 2 is where it first runs for real.
5. Leave a hook in create/update/delete to start, restart and stop monitors; it gets
   connected in Phase 3.

## Traps already hit

- `mix phx.new .` refuses a non-empty directory without an interactive `Y`; pipe
  `yes Y` into it when scripting.
- `phx.new` generates an `AGENTS.md`; it is gitignored on purpose (see ADR-006).
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

## Open questions

- Live reload inside the container has not been exercised yet with a real file edit.
  If it does not fire, switch `config/dev.exs` to `live_reload: [backend: :fs_poll]`.
