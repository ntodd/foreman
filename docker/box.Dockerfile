# The agent release, and a stand-in for a remote Linux box for end-to-end
# tests: systemd, Docker Engine (docker-in-docker), git and Node.
#
#   docker build -f docker/box.Dockerfile --target agent-tarball -o tmp/agent .
#   docker build -f docker/box.Dockerfile --target box -t foreman-box .
#
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
COPY apps/foreman_agent/priv priv
COPY apps/foreman_agent/rel rel
RUN mix release && cp _build/prod/foreman_agent-${FOREMAN_AGENT_VERSION}.tar.gz /foreman_agent.tar.gz

FROM scratch AS agent-tarball
COPY --from=agent /foreman_agent.tar.gz /

FROM ${RUNTIME_IMAGE} AS box
# What the install script expects of a box: systemd, Docker Engine with
# Compose, nftables (for the box firewall), git, and Node for the
# devcontainer CLI. Nothing of Foreman's: e2e/linux/run.sh installs the
# agent with the control plane's install script, as on a real box.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends systemd systemd-sysv dbus ca-certificates curl gnupg git procps iptables nftables nodejs npm \
  && install -m 0755 -d /etc/apt/keyrings \
  && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable" > /etc/apt/sources.list.d/docker.list \
  && apt-get update -y \
  && apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin \
  && rm -rf /var/lib/apt/lists/* \
  && echo LANG=C.UTF-8 > /etc/locale.conf
# Nothing to log in on and no hardware; and, since the container is
# privileged on a host other jobs share, nothing that writes the host's
# kernel settings (sysctls, binfmt handlers, modules).
RUN systemctl mask getty.target console-getty.service systemd-udevd.service systemd-udevd-control.socket systemd-udevd-kernel.socket systemd-firstboot.service \
      systemd-sysctl.service systemd-binfmt.service proc-sys-fs-binfmt_misc.automount proc-sys-fs-binfmt_misc.mount systemd-modules-load.service
ENV container=docker
STOPSIGNAL SIGRTMIN+3
VOLUME /var/lib/docker /var/lib/containerd
CMD ["/sbin/init"]
