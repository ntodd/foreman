#!/bin/sh
# Installs the Foreman agent on a Linux box and enrolls it.
#
#   curl -fsSL __FOREMAN_URL__/agent/install.sh | sudo sh -s -- --token fj_...
#
# Re-running it on an enrolled box updates the agent and the devcontainer
# CLI and keeps the box's identity (no token needed). To enroll again, for
# example after the box was revoked, pass --reenroll with a new token.
#
# --isolation vm runs each environment in its own Incus VM (Incus set up,
# and the environment image built, beforehand: see the agent's priv/vm).
# A re-run without --isolation keeps the box's current isolation and its
# FOREMAN_VM_* settings.
#
# Needs: systemd, Docker Engine with Compose v2.24+, git, and Node 20+
# (for the devcontainer CLI). The agent runs as the `foreman` user, which
# joins the docker group: that is root-equivalent on this box, so only
# install it on boxes whose owner you trust with every environment on it.
set -eu

FOREMAN_URL="__FOREMAN_URL__"
DEVCONTAINER_CLI_VERSION="0.89.0"
TOKEN=""
POLICY=""
REENROLL=""
ISOLATION=""
IDENTITY=/var/lib/foreman-agent/identity.json

while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --policy) POLICY="$2"; shift 2 ;;
    --url) FOREMAN_URL="$2"; shift 2 ;;
    --reenroll) REENROLL=1; shift ;;
    --isolation) ISOLATION="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

fail() { echo "foreman: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "run this as root (sudo)"

# An existing identity is kept unless --reenroll: a new token would make a
# new box in Foreman, and this box's environments belong to the old one.
enroll=1
if [ -s "$IDENTITY" ] && [ -z "$REENROLL" ]; then
  enroll=""
fi
if [ -n "$enroll" ]; then
  [ -n "$TOKEN" ] || fail "--token is required (create one on the Boxes page)"
fi
command -v systemctl >/dev/null 2>&1 || fail "systemd is required"
command -v docker >/dev/null 2>&1 || fail "Docker Engine is required"
command -v git >/dev/null 2>&1 || fail "git is required"
command -v npm >/dev/null 2>&1 || fail "Node.js (with npm) is required for the devcontainer CLI"

# What the box ran before: its isolation and VM settings survive a re-run.
kept=""
if [ -f /etc/foreman-agent/agent.env ]; then
  kept=$(grep -E '^FOREMAN_(ISOLATION|VM_[A-Z_]+)=' /etc/foreman-agent/agent.env || true)
fi
case "$ISOLATION" in
  "") ;;
  container | vm)
    kept=$(printf '%s\n' "$kept" | grep -v '^FOREMAN_ISOLATION=' || true)
    kept=$(printf 'FOREMAN_ISOLATION=%s\n%s' "$ISOLATION" "$kept")
    ;;
  *) fail "--isolation is container or vm" ;;
esac
vm_box=""
if printf '%s\n' "$kept" | grep -qx 'FOREMAN_ISOLATION=vm'; then
  vm_box=1
  command -v incus >/dev/null 2>&1 || fail "--isolation vm needs Incus (and the foreman-env image)"
fi

compose=$(docker compose version --short 2>/dev/null || true)
[ -n "$compose" ] || fail "the Docker Compose plugin is required"
# The overlay uses the `!reset` tag, reliable from Compose 2.24.
compose_version=${compose#v}
compose_major=${compose_version%%.*}
compose_minor=${compose_version#*.}
compose_minor=${compose_minor%%.*}
case "$compose_major$compose_minor" in
  *[!0-9]* | "") fail "couldn't read the Docker Compose version ($compose)" ;;
esac
if [ "$compose_major" -lt 2 ] || { [ "$compose_major" -eq 2 ] && [ "$compose_minor" -lt 24 ]; }; then
  fail "Docker Compose $compose is too old; 2.24 or newer is needed. Install Docker from Docker's apt repository (https://docs.docker.com/engine/install/), which ships a current docker-compose-plugin"
fi

case "$(uname -m)" in
  x86_64) target=linux-amd64 ;;
  aarch64 | arm64) target=linux-arm64 ;;
  *) fail "unsupported architecture $(uname -m)" ;;
esac

echo "foreman: creating the foreman user"
id foreman >/dev/null 2>&1 || useradd --system --home-dir /var/lib/foreman-agent --shell /usr/sbin/nologin foreman
usermod -aG docker foreman
# incus-admin is root-equivalent, like docker; the agent needs it to run VMs.
if [ -n "$vm_box" ]; then usermod -aG incus-admin foreman; fi

install -d -m 0700 -o foreman -g foreman /var/lib/foreman-agent
install -d -m 0755 -o foreman -g foreman /srv/foreman /srv/foreman/envs
install -d -m 0755 -o foreman -g foreman /opt/foreman-agent /opt/foreman-agent/releases
install -d -m 0750 -o root -g foreman /etc/foreman-agent

# Secrets live on tmpfs (/run), recreated at boot.
cat > /etc/tmpfiles.d/foreman.conf <<EOF
d /run/foreman 0711 foreman foreman -
d /run/foreman/envs 0700 foreman foreman -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/foreman.conf

echo "foreman: installing the devcontainer CLI $DEVCONTAINER_CLI_VERSION"
npm install --prefix /opt/foreman-agent/node --no-fund --no-audit --silent "@devcontainers/cli@$DEVCONTAINER_CLI_VERSION"

echo "foreman: downloading the agent for $target"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -D "$tmp/headers" -o "$tmp/agent.tar.gz" "$FOREMAN_URL/agent/releases/latest/$target" ||
  fail "couldn't download the agent from $FOREMAN_URL (has a release been published for $target?)"
version=$(sed -n 's/^x-foreman-version: *\([^[:space:]]*\).*/\1/ip' "$tmp/headers" | tail -1)
sha=$(sed -n 's/^x-foreman-sha256: *\([0-9a-f]*\).*/\1/ip' "$tmp/headers" | tail -1)
if [ -z "$version" ] || [ -z "$sha" ]; then
  fail "the release download is missing its version or digest"
fi
printf '%s  %s\n' "$sha" "$tmp/agent.tar.gz" | sha256sum -c - >/dev/null || fail "the download doesn't match its digest"

dest="/opt/foreman-agent/releases/$version"
# Unpack beside the release and swap it in: on a re-run the agent may be
# running from $dest, and deleting it under the running agent breaks it.
new="$dest.new.$$"
rm -rf "$new"
install -d -o foreman -g foreman "$new"
tar -xzf "$tmp/agent.tar.gz" -C "$new"
chown -R foreman:foreman "$new"
rm -rf "$dest.old"
if [ -d "$dest" ]; then mv "$dest" "$dest.old"; fi
mv "$new" "$dest"
ln -sfn "releases/$version" /opt/foreman-agent/current
chown -h foreman:foreman /opt/foreman-agent/current
# A fresh install isn't an update waiting to be confirmed.
rm -f /opt/foreman-agent/previous /opt/foreman-agent/update-pending

if [ -n "$enroll" ] && [ -e "$IDENTITY" ]; then
  # Keep the old identity aside rather than deleting a key.
  mv "$IDENTITY" "$IDENTITY.replaced-$(date +%s)"
fi

umask 077
join_token=""
if [ -n "$enroll" ]; then join_token="$TOKEN"; fi
cat > /etc/foreman-agent/agent.env <<EOF
FOREMAN_URL=$FOREMAN_URL
FOREMAN_JOIN_TOKEN=$join_token
FOREMAN_DEVCONTAINER_CLI=/opt/foreman-agent/node/node_modules/.bin/devcontainer
FOREMAN_POLICY=$POLICY
HOME=/var/lib/foreman-agent
RELEASE_TMP=/var/lib/foreman-agent/tmp
EOF
if [ -n "$kept" ]; then printf '%s\n' "$kept" >> /etc/foreman-agent/agent.env; fi
chgrp foreman /etc/foreman-agent/agent.env
chmod 0640 /etc/foreman-agent/agent.env
umask 022

cat > /etc/systemd/system/foreman-agent.service <<'EOF'
[Unit]
Description=Foreman agent
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service
OnFailure=foreman-agent-rollback.service
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
User=foreman
Group=foreman
EnvironmentFile=/etc/foreman-agent/agent.env
ExecStart=/opt/foreman-agent/current/bin/foreman_agent start
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/foreman-agent /srv/foreman /run/foreman /opt/foreman-agent

[Install]
WantedBy=multi-user.target
EOF

# Self-update keeps the version it replaced in `previous` until the new one
# joins the control plane. If the new one keeps crashing, switch back to
# it. (One that runs but never joins rolls itself back.) A first install
# has nothing to go back to; the agent's own unit already shows that
# failure.
cat > /etc/systemd/system/foreman-agent-rollback.service <<'EOF'
[Unit]
Description=Roll the Foreman agent back to its previous release

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'cd /opt/foreman-agent && if [ -L previous ]; then ln -sfn "$(readlink previous)" current && rm -f previous update-pending && systemctl reset-failed foreman-agent && systemctl start foreman-agent; else echo "no previous release to roll back to"; fi'
EOF

systemctl daemon-reload
systemctl enable foreman-agent
# Restart, not start: on a re-run the agent may already be running (or
# have hit its start limit) with the old settings and join token.
systemctl reset-failed foreman-agent 2>/dev/null || true
systemctl restart foreman-agent
rm -rf "$dest.old"

if [ -z "$enroll" ]; then
  echo "foreman: updated; this box keeps its enrollment ($IDENTITY)."
  echo "foreman: if it was revoked in Foreman, re-run with --reenroll and a new --token."
  exit 0
fi

echo "foreman: waiting for the agent to enroll"
i=0
while [ $i -lt 30 ]; do
  if [ -s "$IDENTITY" ]; then
    # The join token is spent; don't leave it lying around.
    sed -i '/^FOREMAN_JOIN_TOKEN=/d' /etc/foreman-agent/agent.env
    echo "foreman: enrolled. This box should show as online in Foreman."
    exit 0
  fi
  sleep 2
  i=$((i + 1))
done

fail "the agent didn't enroll within a minute; see: journalctl -u foreman-agent"
