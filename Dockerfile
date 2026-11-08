# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the builder image
#     E.g.: docker.io/hexpm/elixir:1.20.2-erlang-29.0.2-debian-trixie-20260623-slim
#   - https://hub.docker.com/_/debian/tags?name=trixie-20260623-slim - for the runner image
#     E.g.: docker.io/debian:trixie-20260623-slim
#
# Find builder and runner images on Docker Hub or on Hex's Build Server (Bob).
# We recommend using Bob's Web UI to find recent tags:
#
#   - https://bob.hex.pm/docker?repo=hexpm/elixir&os=debian&sort=elixir_version,erlang_version,os_version
#
# We suggest using the same Debian version for both the builder and runner images.
#
# We suggest Debian/Ubuntu instead of Alpine to avoid production compatibility issues
# (such as DNS resolution failures, and dynamically linked NIFs/precompiled binaries).
#
# For finding packages in Debian, search on https://packages.debian.org/.

ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=29.0.2
ARG DEBIAN_VERSION=trixie-20260623-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"
# uv for backends of content repositories (ADR 26); it installs Python itself.
ARG UV_VERSION=0.11.21

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Tailwind is downloaded from github.com/.../releases/download/..., which has
# failed with "504 Gateway Time-out" while the GitHub API kept working; the
# fallback fetches it through the API (see docs/deployment.md, "Releasing").
COPY docker/fetch_tailwind.exs docker/
RUN --mount=type=secret,id=github_token \
  mix assets.setup \
  || (mix run --no-compile --no-start docker/fetch_tailwind.exs && mix assets.setup)

COPY priv priv

COPY lib lib

# Compile the release
RUN mix compile

COPY assets assets

# compile assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
    git openssh-client tini \
  && rm -rf /var/lib/apt/lists/*

# Backends (ADR 26): uv installs their Python and packages at runtime, into
# the cache on the volume.
COPY --from=uv /uv /usr/local/bin/uv

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"

# deepsplay runs as its own user. The cache (cache_dir in the host
# configuration) lives on a volume; the host configuration and secrets are
# mounted read-only (see docs/deployment.md, ADR 13).
RUN useradd --system --uid 10001 --home-dir /var/lib/deepsplay --create-home deepsplay \
  && mkdir -p /var/lib/deepsplay/cache /etc/deepsplay \
  && chown -R deepsplay /var/lib/deepsplay /app
VOLUME /var/lib/deepsplay

ENV DEEPSPLAY_CONFIG=/etc/deepsplay/host.toml
ENV PORT=4000
EXPOSE 4000

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=deepsplay:root /app/_build/${MIX_ENV}/rel/deepsplay ./

USER deepsplay

# tini reaps processes left behind by backends and passes signals on
# (SIGHUP reloads the host configuration, ADR 23).
ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["/app/bin/server"]
