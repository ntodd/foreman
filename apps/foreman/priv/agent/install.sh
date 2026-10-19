#!/bin/sh
# Installs the Foreman agent on a Linux box and enrolls it.
#
#   curl -fsSL __FOREMAN_URL__/agent/install.sh | sudo sh -s -- --token fj_...
#
# Re-running it on an enrolled box updates the agent and the devcontainer
# CLI and keeps the box's identity (no token needed). To enroll again, for
# example after the box was revoked, pass --reenroll with a new token.
#
# It also installs the box's firewall, which keeps environments (and
# Docker's default bridge, where image builds run) from reaching the
# tailnet as this box. --default-bridge-reaches-tailnet leaves the
# default bridge out, for a box whose other containers need the tailnet
# there; builds can then reach it too.
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
DEFAULT_BRIDGE_FILTER=1
IDENTITY=/var/lib/foreman-agent/identity.json

while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --policy) POLICY="$2"; shift 2 ;;
    --url) FOREMAN_URL="$2"; shift 2 ;;
    --reenroll) REENROLL=1; shift ;;
    --default-bridge-reaches-tailnet) DEFAULT_BRIDGE_FILTER=""; shift ;;
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
nft=$(command -v nft 2>/dev/null || true)
[ -n "$nft" ] || fail "nftables is required for the box's firewall (apt install nftables)"
# The firewall rejects environment traffic out of tailscale0, which on a
# box using an exit node is all of it.
if command -v tailscale >/dev/null 2>&1 && tailscale status --json 2>/dev/null | grep -q '"ExitNodeStatus"'; then
  fail "this box sends its traffic through a Tailscale exit node, and the box's firewall would cut environments off from the internet; turn it off with: tailscale set --exit-node="
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
chgrp foreman /etc/foreman-agent/agent.env
chmod 0640 /etc/foreman-agent/agent.env
umask 022

# The box's firewall: environments don't reach the tailnet as the box
# (the rules explain why). The rules ship with the agent; this copy, with
# the box's name for Docker's default bridge, is what loads. Anything
# that flushes the whole ruleset (nftables.service's stop or reload, on
# Debian) takes the table with it, so a timer loads it again within
# seconds.
set -- "$dest"/lib/foreman_agent-*/priv/firewall/foreman.nft
[ -f "$1" ] || fail "the agent release has no firewall rules"
if [ -n "$DEFAULT_BRIDGE_FILTER" ]; then
  default_bridge=$(docker network inspect bridge --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null || true)
  # Guessing would leave builds unfiltered without a word.
  case "$default_bridge" in
    "") fail "couldn't find the name of Docker's default bridge; if this box has none, pass --default-bridge-reaches-tailnet" ;;
    *[!A-Za-z0-9_.+@-]*) fail "Docker's default bridge is named '$default_bridge', which the firewall rules can't name; rename it, or pass --default-bridge-reaches-tailnet" ;;
  esac
  sed "s/\"docker0\"/\"$default_bridge\"/" "$1" > /etc/foreman-agent/firewall.nft.new
else
  sed '/# default-bridge$/d' "$1" > /etc/foreman-agent/firewall.nft.new
fi
"$nft" -c -f /etc/foreman-agent/firewall.nft.new || fail "nftables rejected the firewall rules"
chmod 0644 /etc/foreman-agent/firewall.nft.new
mv /etc/foreman-agent/firewall.nft.new /etc/foreman-agent/firewall.nft

cat > /etc/systemd/system/foreman-firewall.service <<EOF
[Unit]
Description=Foreman box firewall (environments stay off the tailnet)
After=nftables.service
Before=docker.service foreman-agent.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$nft -f /etc/foreman-agent/firewall.nft

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/foreman-firewall-check.service <<EOF
[Unit]
Description=Load the Foreman box firewall again if something removed it
After=foreman-firewall.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c '$nft list table inet foreman >/dev/null 2>&1 || exec $nft -f /etc/foreman-agent/firewall.nft'
EOF

cat > /etc/systemd/system/foreman-firewall-check.timer <<'EOF'
[Unit]
Description=Check the Foreman box firewall is loaded

[Timer]
OnBootSec=15s
OnUnitActiveSec=15s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/foreman-agent.service <<'EOF'
[Unit]
Description=Foreman agent
After=network-online.target docker.service foreman-firewall.service
Wants=network-online.target
Requires=docker.service foreman-firewall.service
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
systemctl enable foreman-firewall foreman-agent
systemctl enable --now foreman-firewall-check.timer
# Loads the rules again on a re-run, in case they changed.
systemctl restart foreman-firewall
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
