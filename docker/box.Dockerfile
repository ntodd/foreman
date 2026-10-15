# A stand-in for a remote Linux box, for end-to-end tests: Docker Engine
# (docker-in-docker), git, Node and the devcontainer CLI, and the Foreman
# agent release, supervised by a loop that does what systemd would.
#
#   docker build -f docker/box.Dockerfile -t foreman-box .
#
# The agent target is also exported for self-update tests:
#   docker build -f docker/box.Dockerfile --target agent-tarball -o tmp/agent .
# The agent release bundles ERTS, which links the build image's glibc and
# OpenSSL, so it only runs on systems at least that new. Build it on the
# oldest base boxes should support: jammy runs on Ubuntu 22.04+ and
# Debian 12+; trixie (OpenSSL 3.5) wouldn't start on Ubuntu 24.04.
ARG ELIXIR_IMAGE=hexpm/elixir:1.20.4-erlang-29.1.1-ubuntu-jammy-20260810
ARG RUNTIME_IMAGE=debian:trixie-20261005-slim

FROM ${ELIXIR_IMAGE} AS agent
ARG FOREMAN_AGENT_VERSION=0.1.0
ARG FOREMAN_RELEASE_PUBLIC_KEY=
ENV MIX_ENV=prod FOREMAN_AGENT_VERSION=${FOREMAN_AGENT_VERSION} FOREMAN_RELEASE_PUBLIC_KEY=${FOREMAN_RELEASE_PUBLIC_KEY}
RUN apt-get update -y && apt-get install -y --no-install-recommends build-essential git ca-certificates \
  && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force
WORKDIR /src
COPY apps/foreman_protocol apps/foreman_protocol
COPY features features
COPY apps/foreman_agent/mix.exs apps/foreman_agent/mix.lock apps/foreman_agent/
WORKDIR /src/apps/foreman_agent
RUN mix deps.get --only prod
COPY apps/foreman_agent/config config
RUN mix deps.compile
COPY apps/foreman_agent/lib lib
COPY apps/foreman_agent/rel rel
RUN mix release && cp _build/prod/foreman_agent-${FOREMAN_AGENT_VERSION}.tar.gz /foreman_agent.tar.gz

FROM scratch AS agent-tarball
COPY --from=agent /foreman_agent.tar.gz /

FROM ${RUNTIME_IMAGE} AS box
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends ca-certificates curl gnupg git procps iptables \
       libstdc++6 openssl libncurses6 libsctp1 locales nodejs npm \
  && install -m 0755 -d /etc/apt/keyrings \
  && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable" > /etc/apt/sources.list.d/docker.list \
  && apt-get update -y \
  && apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin \
  && rm -rf /var/lib/apt/lists/* \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# The same layout the install script creates.
RUN useradd --system --home-dir /var/lib/foreman-agent --shell /usr/sbin/nologin foreman \
  && usermod -aG docker foreman \
  && install -d -m 0700 -o foreman -g foreman /var/lib/foreman-agent \
  && install -d -m 0755 -o foreman -g foreman /srv/foreman /srv/foreman/envs /opt/foreman-agent /opt/foreman-agent/releases \
  && npm install --prefix /opt/foreman-agent/node --no-fund --no-audit --silent @devcontainers/cli@0.89.0

ARG FOREMAN_AGENT_VERSION=0.1.0
COPY --from=agent /foreman_agent.tar.gz /tmp/foreman_agent.tar.gz
RUN install -d -o foreman -g foreman /opt/foreman-agent/releases/${FOREMAN_AGENT_VERSION} \
  && tar -xzf /tmp/foreman_agent.tar.gz -C /opt/foreman-agent/releases/${FOREMAN_AGENT_VERSION} \
  && chown -R foreman:foreman /opt/foreman-agent \
  && ln -sfn releases/${FOREMAN_AGENT_VERSION} /opt/foreman-agent/current \
  && chown -h foreman:foreman /opt/foreman-agent/current \
  && rm /tmp/foreman_agent.tar.gz

COPY docker/box-entrypoint.sh /usr/local/bin/box-entrypoint
ENV FOREMAN_DEVCONTAINER_CLI=/opt/foreman-agent/node/node_modules/.bin/devcontainer \
    HOME=/var/lib/foreman-agent
VOLUME /var/lib/docker
ENTRYPOINT ["/usr/local/bin/box-entrypoint"]
