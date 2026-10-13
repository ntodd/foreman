# The Foreman control plane as a release.
#
#   docker build -f docker/control-plane.Dockerfile -t foreman .
#   docker build -f docker/control-plane.Dockerfile --build-arg FOREMAN_DB=postgres -t foreman:pg .
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
RUN mix assets.setup && mix compile && mix assets.deploy && mix release

FROM ${RUNTIME_IMAGE}
RUN apt-get update -y && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 libsctp1 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 MIX_ENV=prod PHX_SERVER=true

RUN useradd --system --create-home --home-dir /var/lib/foreman foreman
WORKDIR /app
COPY --from=build --chown=foreman:foreman /src/apps/foreman/_build/prod/rel/foreman ./
USER foreman
ENV DATABASE_PATH=/var/lib/foreman/foreman.db
CMD ["/app/bin/foreman", "start"]
