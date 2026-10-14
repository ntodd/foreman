#!/bin/sh
# Installs the Foreman agent on a Linux box and enrolls it.
#
#   curl -fsSL __FOREMAN_URL__/agent/install.sh | sudo sh -s -- --token fj_...
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

while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --policy) POLICY="$2"; shift 2 ;;
    --url) FOREMAN_URL="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

fail() { echo "foreman: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "run this as root (sudo)"
[ -n "$TOKEN" ] || fail "--token is required (create one on the Boxes page)"
command -v systemctl >/dev/null 2>&1 || fail "systemd is required"
command -v docker >/dev/null 2>&1 || fail "Docker Engine is required"
command -v git >/dev/null 2>&1 || fail "git is required"
command -v npm >/dev/null 2>&1 || fail "Node.js (with npm) is required for the devcontainer CLI"

compose=$(docker compose version --short 2>/dev/null || true)
[ -n "$compose" ] || fail "the Docker Compose plugin is required"
case "$compose" in
  1.* | 2.[0-9].* | 2.1[0-9].* | 2.2[0-3].*) fail "Docker Compose $compose is too old; 2.24 or newer is needed" ;;
esac

case "$(uname -m)" in
  x86_64) target=linux-amd64 ;;
  aarch64 | arm64) target=linux-arm64 ;;
  *) fail "unsupported architecture $(uname -m)" ;;
esac

echo "foreman: creating the foreman user"
id foreman >/dev/null 2>&1 || useradd --system --home-dir /var/lib/foreman-agent --shell /usr/sbin/nologin foreman
usermod -aG docker foreman

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
rm -rf "$dest"
install -d -o foreman -g foreman "$dest"
tar -xzf "$tmp/agent.tar.gz" -C "$dest"
chown -R foreman:foreman "$dest"
ln -sfn "releases/$version" /opt/foreman-agent/current
chown -h foreman:foreman /opt/foreman-agent/current

umask 077
cat > /etc/foreman-agent/agent.env <<EOF
FOREMAN_URL=$FOREMAN_URL
FOREMAN_JOIN_TOKEN=$TOKEN
FOREMAN_DEVCONTAINER_CLI=/opt/foreman-agent/node/node_modules/.bin/devcontainer
FOREMAN_POLICY=$POLICY
HOME=/var/lib/foreman-agent
RELEASE_TMP=/var/lib/foreman-agent/tmp
EOF
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

# Self-update keeps the version it replaced in `previous`. If the new one
# keeps failing, switch back to it.
cat > /etc/systemd/system/foreman-agent-rollback.service <<'EOF'
[Unit]
Description=Roll the Foreman agent back to its previous release

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'cd /opt/foreman-agent && [ -L previous ] && ln -sfn "$(readlink previous)" current && rm previous && systemctl reset-failed foreman-agent && systemctl start foreman-agent'
EOF

systemctl daemon-reload
systemctl enable foreman-agent
# Restart, not start: on a re-run the agent may already be running (or
# have hit its start limit) with the old settings and join token.
systemctl reset-failed foreman-agent 2>/dev/null || true
systemctl restart foreman-agent

echo "foreman: waiting for the agent to enroll"
i=0
while [ $i -lt 30 ]; do
  if [ -s /var/lib/foreman-agent/identity.json ]; then
    # The join token is spent; don't leave it lying around.
    sed -i '/^FOREMAN_JOIN_TOKEN=/d' /etc/foreman-agent/agent.env
    echo "foreman: enrolled. This box should show as online in Foreman."
    exit 0
  fi
  sleep 2
  i=$((i + 1))
done

fail "the agent didn't enroll within a minute; see: journalctl -u foreman-agent"
