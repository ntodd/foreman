#!/bin/sh
# Installs the Foreman agent on a Linux box and enrolls it.
#
#   curl -fsSL __FOREMAN_URL__/agent/install.sh | sudo sh -s -- --token fj_...
#
# Re-running it on an enrolled box updates the agent and keeps the box's
# identity (no token needed). To enroll again, for
# example after the box was revoked, pass --reenroll with a new token.
#
# It also installs the box's firewall, which keeps environments (and
# Docker's default bridge, where image builds run) from reaching the
# tailnet as this box. --default-bridge-reaches-tailnet leaves the
# default bridge out, for a box whose other containers need the tailnet
# there; builds can then reach it too.
#
# Needs: systemd, Docker Engine with Compose v2.24+, git and nftables. The
# agent release carries its own Node and devcontainer CLI. The agent runs
# as the `foreman` user, which
# joins the docker group: that is root-equivalent on this box, so only
# install it on boxes whose owner you trust with every environment on it.
set -eu

FOREMAN_URL="__FOREMAN_URL__"
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
# The release carries the devcontainer CLI and the Node it runs on; this
# script no longer installs them. One that doesn't (an agent older than
# this script, served to a box pinned to it) wouldn't run environments.
set -- "$new"/lib/foreman_agent-*/priv/tools/bin/devcontainer
[ -x "$1" ] || { rm -rf "$new"; fail "agent $version doesn't carry the devcontainer CLI; install a newer agent (unpin this box in Foreman, or publish the release that came with this control plane)"; }
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
# A box in a VM (a Flatcar box from the Mac or Linux launcher) has the
# machine it runs on as its gateway, and under QEMU's user-mode network
# the gateway's address is that machine's loopback, where services expect
# only local clients. Environments, and image builds unless the default
# bridge is left out, don't reach it, apart from DNS (vmnet's resolver is
# there).
if systemd-detect-virt --vm --quiet 2>/dev/null; then
  gateway=$(ip -4 route show default 2>/dev/null | awk '$1 == "default" && $2 == "via" { print $3; exit }')
  case "$gateway" in *[!0-9.]*) gateway="" ;; esac
  if [ -n "$gateway" ]; then
    builds=""
    if [ -n "$DEFAULT_BRIDGE_FILTER" ]; then builds="iifname \"$default_bridge\" jump environment"; fi
    cat >> /etc/foreman-agent/firewall.nft.new <<EOF

# This box is a VM; $gateway, its gateway, is the machine it runs on.
table inet foreman_vm
delete table inet foreman_vm

table inet foreman_vm {
	chain environment {
		ip daddr $gateway udp dport 53 accept
		ip daddr $gateway tcp dport 53 accept
		ip daddr $gateway reject with icmpx type admin-prohibited
	}

	chain forward {
		type filter hook forward priority filter - 10; policy accept;
		iifname "fm-*" jump environment
		$builds
	}
}
EOF
  fi
fi
"$nft" -c -f /etc/foreman-agent/firewall.nft.new || fail "nftables rejected the firewall rules"
chmod 0644 /etc/foreman-agent/firewall.nft.new
mv /etc/foreman-agent/firewall.nft.new /etc/foreman-agent/firewall.nft
# What the agent reports to the control plane: which rules these came
# from (an agent that updated itself past them reports them outdated),
# and whether the default bridge is left out. The unit puts it in /run
# while the rules are loaded.
if [ -n "$DEFAULT_BRIDGE_FILTER" ]; then bridge_mode=filtered; else bridge_mode=reaches_tailnet; fi
printf 'source_sha256=%s\ndefault_bridge=%s\n' "$(sha256sum < "$1" | cut -d' ' -f1)" "$bridge_mode" \
  > /etc/foreman-agent/firewall.info
chmod 0644 /etc/foreman-agent/firewall.info

cat > /etc/systemd/system/foreman-firewall.service <<EOF
[Unit]
Description=Foreman box firewall (environments stay off the tailnet)
After=nftables.service
Before=docker.service foreman-agent.service

[Service]
Type=oneshot
RemainAfterExit=yes
RuntimeDirectory=foreman-firewall
ExecStart=$nft -f /etc/foreman-agent/firewall.nft
ExecStartPost=/bin/cp /etc/foreman-agent/firewall.info /run/foreman-firewall/loaded

[Install]
WantedBy=multi-user.target
EOF

# Loads the rules again every tick, whatever removed or changed them:
# the file deletes and re-adds the table in one transaction, so there's no
# gap. The marker the agent reports tracks whether that worked; the agent
# watches it and tells the control plane.
cat > /etc/foreman-agent/firewall-check <<EOF
#!/bin/sh
set -u
marker=/run/foreman-firewall/loaded
# Stopped on purpose: leave it stopped.
systemctl is-active --quiet foreman-firewall || exit 0
if $nft -f /etc/foreman-agent/firewall.nft; then
  [ -e "\$marker" ] || cp /etc/foreman-agent/firewall.info "\$marker"
else
  rm -f "\$marker"
  exit 1
fi
EOF
chmod 0755 /etc/foreman-agent/firewall-check

cat > /etc/systemd/system/foreman-firewall-check.service <<'EOF'
[Unit]
Description=Load the Foreman box firewall again
After=foreman-firewall.service

[Service]
Type=oneshot
# Through sh: /etc is mounted noexec on Flatcar.
ExecStart=/bin/sh /etc/foreman-agent/firewall-check
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

# Reboots the box when an admin asks for it in Foreman (box.restart). The
# agent can't: it runs unprivileged. It writes /run/foreman/restart, and
# this root unit reboots the box a few seconds later, which leaves the
# agent time to answer. Environments only see their own directories below
# /run/foreman/envs, so nothing they run can ask.
cat > /etc/systemd/system/foreman-restart.path <<'EOF'
[Unit]
Description=Reboot the box when the Foreman agent asks

[Path]
PathExists=/run/foreman/restart

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/foreman-restart.service <<'EOF'
[Unit]
Description=Reboot the box for the Foreman agent

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'rm -f /run/foreman/restart; sleep 5; exec systemctl reboot'
EOF

# Flatcar applies OS updates to its other partition by itself, and its
# reboot manager would then reboot the box whenever it liked. Foreman
# shows the update as a reboot the box needs instead (the flag the agent
# reports), and the box reboots when an admin asks.
os_id=$(sed -n 's/^ID=//p' /etc/os-release /usr/lib/os-release 2>/dev/null | head -n 1 | tr -d '"')
if [ "$os_id" = flatcar ]; then
  echo "foreman: Flatcar: OS updates wait for a reboot from Foreman"
  install -d -m 0755 /etc/flatcar
  { grep -v '^REBOOT_STRATEGY=' /etc/flatcar/update.conf 2>/dev/null || true; echo REBOOT_STRATEGY=off; } \
    > /etc/flatcar/update.conf.new
  mv /etc/flatcar/update.conf.new /etc/flatcar/update.conf
  systemctl try-restart locksmithd.service 2>/dev/null || true

  cat > /etc/foreman-agent/flatcar-update-check <<'EOF'
#!/bin/sh
# Flags an OS update update-engine has applied, which takes effect on the
# next boot, the way Debian flags one: /run/reboot-required, with what
# asked for it in /run/reboot-required.pkgs. The agent reports both.
set -u
status=$(update_engine_client -status 2>/dev/null) || exit 0
case "$status" in
  *UPDATE_STATUS_UPDATED_NEED_REBOOT*) ;;
  *) exit 0 ;;
esac
version=$(printf '%s\n' "$status" | sed -n 's/^NEW_VERSION=//p')
line="flatcar-${version:-update}"
grep -qxF "$line" /run/reboot-required.pkgs 2>/dev/null || echo "$line" >> /run/reboot-required.pkgs
[ -e /run/reboot-required ] || echo "*** System restart required ***" > /run/reboot-required
EOF
  chmod 0755 /etc/foreman-agent/flatcar-update-check

  cat > /etc/systemd/system/foreman-flatcar-update.service <<'EOF'
[Unit]
Description=Flag a Flatcar update waiting for a reboot
After=update-engine.service

[Service]
Type=oneshot
# Through sh: Flatcar mounts /etc noexec.
ExecStart=/bin/sh /etc/foreman-agent/flatcar-update-check
EOF

  cat > /etc/systemd/system/foreman-flatcar-update.timer <<'EOF'
[Unit]
Description=Check for a Flatcar update waiting for a reboot

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF
fi

systemctl daemon-reload
systemctl enable foreman-firewall foreman-agent
systemctl enable --now foreman-firewall-check.timer foreman-restart.path
if [ "$os_id" = flatcar ]; then systemctl enable --now foreman-flatcar-update.timer; fi
# Loads the rules again on a re-run, in case they changed.
systemctl restart foreman-firewall
# Restart, not start: on a re-run the agent may already be running (or
# have hit its start limit) with the old settings and join token.
systemctl reset-failed foreman-agent 2>/dev/null || true
systemctl restart foreman-agent
rm -rf "$dest.old"
# Install scripts before the release carried the devcontainer CLI put one
# here with npm.
rm -rf /opt/foreman-agent/node

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
