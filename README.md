# PulseOps

Real-time monitoring and incident management for distributed services, built with
Elixir, Phoenix LiveView and OTP.

PulseOps watches registered services with one supervised process per service,
detects failures, opens and resolves incidents automatically, and pushes every
state change to connected dashboards over WebSockets — no polling anywhere.

## Resuming development

Start here, in this order:

1. [`docs/PROGRESS.md`](docs/PROGRESS.md) — current state, what is done, what is next.
2. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — supervision tree, data model, PubSub topics.
3. [`docs/DECISIONS.md`](docs/DECISIONS.md) — why the design looks the way it does.

## Running it

Everything runs in Docker; no Elixir installation is required on the host.

```bash
docker compose build
docker compose run --rm web mix deps.get
docker compose run --rm web mix ecto.setup
docker compose up web
```

The app is served at http://localhost:4000.

Every `mix` command goes through the container:

```bash
docker compose run --rm web mix test
docker compose run --rm web mix check     # format + compile + credo + test + dialyzer
docker compose run --rm web iex -S mix
```

## Stack

Elixir · Phoenix · Phoenix LiveView · OTP (GenServer, Supervisor, Registry) ·
Phoenix PubSub · Ecto · PostgreSQL · Docker · ExUnit · Credo · Dialyzer
