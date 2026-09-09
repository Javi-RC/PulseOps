# Production image. `Dockerfile.dev` is the one compose uses for development;
# this one builds a release and ships it on a runtime with no build tools, no
# Mix and no source in it.
#
#   docker build -t pulseops:latest .
#
# The two stages must agree on their Debian release: the release ships the
# builder's ERTS, which is linked against the builder's glibc. A mismatch builds
# cleanly and then fails to boot, which is why the runtime is verified below and
# not merely assumed.

ARG ELIXIR_VERSION=1.20
ARG OTP_VERSION=28
# Must match the Debian the builder image is built on. `elixir:1.20-otp-28` is
# Debian 13 (trixie, glibc 2.41); pointing this at bookworm produced an image
# that built cleanly and then died on boot with
# `libm.so.6: version GLIBC_2.38 not found`, because the ERTS is compiled
# against the builder's glibc and copied wholesale into the runtime.
ARG DEBIAN_VERSION=trixie-slim

FROM elixir:${ELIXIR_VERSION}-otp-${OTP_VERSION} AS builder

# git is needed for the git-sourced deps (heroicons, lucide, daisyui);
# build-essential for anything with native code.
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends build-essential git \
    && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod \
    LANG=C.UTF-8

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# Dependencies first and on their own, so a change to application code does not
# invalidate the layer that fetches and compiles them.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Config before application code: config/*.exs is read at compile time and
# changes far less often than lib/.
COPY config/config.exs config/prod.exs config/

# The tailwind and esbuild binaries are downloaded, not compiled, so this is its
# own layer. `assets.deploy` only runs them; it does not install them.
RUN mix assets.setup

COPY assets assets
COPY priv priv
COPY lib lib

RUN mix compile

# Bundle, minify, then digest and gzip. The endpoint serves what the manifest
# names, so this has to happen before the release is assembled.
RUN mix assets.deploy

# runtime.exs is read when the release boots, not when it is built, so it is
# copied after compilation.
COPY config/runtime.exs config/

# rel/overlays is copied into the release root by `mix release`. Without this
# the image builds and `bin/server` and `bin/migrate` simply are not there.
COPY rel rel

RUN mix release

# ---------------------------------------------------------------------------

FROM debian:${DEBIAN_VERSION} AS runtime

# openssl for TLS, libncurses for the Erlang runtime, ca-certificates so
# outbound HTTPS — every probe and every webhook — can verify a certificate.
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libncurses6 \
        libstdc++6 \
        locales \
        openssl \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true

WORKDIR /app

# Not root: the release needs no privileges, and a monitoring product makes
# outbound requests to addresses its own tenants chose.
RUN groupadd --system --gid 1000 pulseops \
    && useradd --system --uid 1000 --gid pulseops --create-home pulseops \
    && chown pulseops:pulseops /app

COPY --from=builder --chown=pulseops:pulseops /app/_build/prod/rel/pulse_ops ./

USER pulseops

EXPOSE 4000

# Migrations are not run here. A container that migrates on boot races every
# other replica that starts at the same time; run
# `bin/pulse_ops eval "PulseOps.Release.migrate()"` as its own step first.
CMD ["/app/bin/server"]
