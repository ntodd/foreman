# The Foreman control plane as a release.
#
#   docker build -f docker/control-plane.Dockerfile -t foreman .
#   docker build -f docker/control-plane.Dockerfile --build-arg FOREMAN_DB=postgres -t foreman:pg .
#
# The release workflow also passes the version, and puts the signed agent
# releases built with it in docker/agents/ (foreman_agent-<version>-<target>.tar.gz,
# each with a .sig beside it), which the control plane registers at boot:
#
#   docker build -f docker/control-plane.Dockerfile --build-arg FOREMAN_VERSION=0.3.0 -t foreman .
#
# Whatever is in docker/agents/ goes into the image, so keep it empty for
# an image that carries no agents.
ARG ELIXIR_IMAGE=hexpm/elixir:1.20.4-erlang-29.1.1-debian-trixie-20261005-slim
ARG RUNTIME_IMAGE=debian:trixie-20261005-slim

FROM ${ELIXIR_IMAGE} AS build
ARG FOREMAN_DB=sqlite
ENV MIX_ENV=prod FOREMAN_DB=${FOREMAN_DB}
RUN apt-get update -y && apt-get install -y --no-install-recommends build-essential git ca-certificates \
  && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force

WORKDIR /src
COPY apps/foreman_protocol apps/foreman_protocol
COPY apps/foreman/mix.exs apps/foreman/mix.lock apps/foreman/
WORKDIR /src/apps/foreman
RUN mix deps.get --only prod
COPY apps/foreman/config config
RUN mix deps.compile

COPY apps/foreman/priv priv
COPY apps/foreman/assets assets
COPY apps/foreman/lib lib
COPY apps/foreman/rel rel
COPY docker/agents/ priv/agent/releases/
# Set late, so a new version doesn't rebuild the dependencies.
ARG FOREMAN_VERSION=0.1.0
ENV FOREMAN_VERSION=${FOREMAN_VERSION}
RUN mix assets.setup && mix compile && mix assets.deploy && mix release

FROM ${RUNTIME_IMAGE}
# The database the release was built for. The release itself knows; this
# is for whoever inspects the image or runs it.
ARG FOREMAN_DB=sqlite
ENV FOREMAN_DB=${FOREMAN_DB}
RUN apt-get update -y && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 libsctp1 locales ca-certificates curl \
  && rm -rf /var/lib/apt/lists/* \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 MIX_ENV=prod PHX_SERVER=true

RUN useradd --system --create-home --home-dir /var/lib/foreman foreman
WORKDIR /app
# The host's updater (docker/foreman-update) installs and refreshes itself
# from here. Root's, so the control plane can't change what root runs.
COPY docker/foreman-update /app/updater/foreman-update
COPY --from=build --chown=foreman:foreman /src/apps/foreman/_build/prod/rel/foreman ./
USER foreman
ENV DATABASE_PATH=/var/lib/foreman/foreman.db
# 200 once the app is up and its database answers. 127.0.0.1 is exempt
# from the FOREMAN_FORCE_SSL redirect.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s \
  CMD curl -fsS -o /dev/null "http://127.0.0.1:${PORT:-4000}/healthz" || exit 1
CMD ["/app/bin/foreman", "start"]
# What the updater compares versions by. Last, so a new version only
# changes this layer.
ARG FOREMAN_VERSION=0.1.0
LABEL org.opencontainers.image.version=${FOREMAN_VERSION}
