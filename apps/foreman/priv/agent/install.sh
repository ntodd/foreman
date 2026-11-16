#!/bin/sh
# Installs the Foreman agent on a Linux box and enrolls it.
#
#   curl -fsSL __FOREMAN_URL__/agent/install.sh | sudo sh -s -- --token fj_...
#
# Re-running it on an enrolled box updates the agent and keeps the box's
# identity (no token needed). To enroll again, for
# example after the box was revoked, pass --reenroll with a new token.
#
# Every environment runs in a VM of its own (Cloud Hypervisor, which the
# agent release carries), with its own kernel and Docker. The agent runs
# as the unprivileged `foreman` user; foreman-vmctl, a small root helper
# this script installs, gives each VM its tap, address and systemd unit.
#
# It also installs the box's firewall, which keeps environments off the
# tailnet as this box and off each other and the box itself, and (with
# Docker on the box) keeps Docker's default bridge, where image builds
# run, off the tailnet. --default-bridge-reaches-tailnet leaves the
# default bridge out, for a box whose other containers need the tailnet
# there. --block-lan keeps environments off this box's LAN too (DNS
# aside); by default they reach it. --vm-subnet A.B gives VMs addresses
# from A.B.0.0/16 instead of 10.250.0.0/16.
#
# Needs: systemd, nftables, iproute2, e2fsprogs and KVM (/dev/kvm; a box
# that is itself a VM needs nested virtualization). amd64 only for now.
# Docker isn't needed. /srv/foreman holds the VMs' disks: on XFS (or
# btrfs) a new environment's disk is a reflink, made at once; on ext4 it's
# a full copy.
set -eu

FOREMAN_URL="__FOREMAN_URL__"
TOKEN=""
POLICY=""
REENROLL=""
DEFAULT_BRIDGE_FILTER=1
BLOCK_LAN=""
VM_SUBNET=10.250
IDENTITY=/var/lib/foreman-agent/identity.json

while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --policy) POLICY="$2"; shift 2 ;;
    --url) FOREMAN_URL="$2"; shift 2 ;;
    --reenroll) REENROLL=1; shift ;;
    --default-bridge-reaches-tailnet) DEFAULT_BRIDGE_FILTER=""; shift ;;
    --block-lan) BLOCK_LAN=1; shift ;;
    --vm-subnet) VM_SUBNET="$2"; shift 2 ;;
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
command -v systemd-run >/dev/null 2>&1 || fail "systemd-run is required"
command -v ip >/dev/null 2>&1 || fail "iproute2 is required (apt install iproute2)"
command -v mkfs.ext4 >/dev/null 2>&1 || fail "e2fsprogs is required (apt install e2fsprogs)"
command -v flock >/dev/null 2>&1 || fail "flock is required (apt install util-linux)"
nft=$(command -v nft 2>/dev/null || true)
[ -n "$nft" ] || fail "nftables is required for the box's firewall (apt install nftables)"
case "$VM_SUBNET" in
  *.*.* | *[!0-9.]*) fail "--vm-subnet takes the first two octets of a private /16, like 10.250" ;;
  10.[0-9] | 10.[1-9][0-9] | 10.1[0-9][0-9] | 10.2[0-4][0-9] | 10.25[0-5] | 172.1[6-9] | 172.2[0-9] | 172.3[01] | 192.168) ;;
  *) fail "--vm-subnet takes the first two octets of a private /16, like 10.250" ;;
esac
# Its own VMs' taps aside: a re-run finds those.
if ip -4 route show 2>/dev/null | grep -v ' dev fm-vm' | grep -q "^$VM_SUBNET\\."; then
  fail "$VM_SUBNET.0.0/16 is already routed on this box; pick another with --vm-subnet"
fi
if [ ! -e /dev/kvm ]; then
  echo "foreman: warning: this box has no /dev/kvm, so it can't run environments until KVM is on (or, for a VM, nested virtualization)" >&2
fi
# The firewall rejects environment traffic out of tailscale0, which on a
# box using an exit node is all of it.
if command -v tailscale >/dev/null 2>&1 && tailscale status --json 2>/dev/null | grep -q '"ExitNodeStatus"'; then
  fail "this box sends its traffic through a Tailscale exit node, and the box's firewall would cut environments off from the internet; turn it off with: tailscale set --exit-node="
fi

case "$(uname -m)" in
  x86_64) target=linux-amd64 ;;
  aarch64 | arm64)
    target=linux-arm64
    echo "foreman: warning: environment VMs aren't supported on arm64 yet; this box enrolls but can't run environments" >&2
    ;;
  *) fail "unsupported architecture $(uname -m)" ;;
esac

echo "foreman: creating the foreman user"
id foreman >/dev/null 2>&1 || useradd --system --home-dir /var/lib/foreman-agent --shell /usr/sbin/nologin foreman
# Agents before environment VMs ran environments on the box's Docker, as
# a member of the docker group, which is root in all but name. This one
# doesn't need it.
if id -nG foreman 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
  gpasswd -d foreman docker >/dev/null
  echo "foreman: took the foreman user out of the docker group"
fi

install -d -m 0700 -o foreman -g foreman /var/lib/foreman-agent
install -d -m 0755 -o foreman -g foreman /srv/foreman
install -d -m 0700 -o foreman -g foreman /srv/foreman/vms /srv/foreman/guest /srv/foreman/agent-disks
install -d -m 0700 -o root -g root /var/lib/foreman-vmctl
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
set -- "$new"/lib/foreman_agent-*/priv/vm/vmctl
[ -f "$1" ] || { rm -rf "$new"; fail "agent $version doesn't run environment VMs; install a newer agent (unpin this box in Foreman)"; }
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

# Install scripts before the release carried the devcontainer CLI put one
# here with npm and named it in agent.env. A box pinned to an agent from
# then is moved back to it after this script, and that agent still needs
# both. An agent that carries its own CLI ignores this path.
legacy_cli=/opt/foreman-agent/node/node_modules/.bin/devcontainer
legacy_cli_env=""
if [ -x "$legacy_cli" ]; then legacy_cli_env="FOREMAN_DEVCONTAINER_CLI=$legacy_cli"; fi

umask 077
join_token=""
if [ -n "$enroll" ]; then join_token="$TOKEN"; fi
cat > /etc/foreman-agent/agent.env <<EOF
FOREMAN_URL=$FOREMAN_URL
FOREMAN_JOIN_TOKEN=$join_token
$legacy_cli_env
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
rules=$1
# --block-lan keeps the lines marked for it; by default they go.
if [ -n "$BLOCK_LAN" ]; then
  sed 's/ # block-lan$//' "$rules" > /etc/foreman-agent/firewall.nft.src
else
  sed '/# block-lan$/d' "$rules" > /etc/foreman-agent/firewall.nft.src
fi
set -- /etc/foreman-agent/firewall.nft.src
# A box without Docker has no default bridge to filter.
no_docker=""
if [ -n "$DEFAULT_BRIDGE_FILTER" ] && ! command -v docker >/dev/null 2>&1; then
  DEFAULT_BRIDGE_FILTER=""
  no_docker=1
fi
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
# A Flatcar box in a VM (from the Mac or Linux launcher, or on another
# hypervisor) has the machine it runs on as its gateway, and under QEMU's
# user-mode network the gateway's address is that machine's loopback,
# where services expect only local clients. Environments, and image
# builds unless the default bridge is left out, don't reach it, apart
# from DNS (vmnet's resolver is there). Only on Flatcar: a box someone
# set up on another Linux in a VM may have environments that use
# something on its gateway, and re-running this script mustn't cut that
# off.
os_id=$(sed -n 's/^ID=//p' /etc/os-release /usr/lib/os-release 2>/dev/null | head -n 1 | tr -d '"')
if [ "$os_id" = flatcar ] && systemd-detect-virt --vm --quiet 2>/dev/null; then
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
rm -f /etc/foreman-agent/firewall.nft.src
if [ -n "$DEFAULT_BRIDGE_FILTER" ] || [ -n "$no_docker" ]; then bridge_mode=filtered; else bridge_mode=reaches_tailnet; fi
printf 'source_sha256=%s\ndefault_bridge=%s\n' "$(sha256sum < "$rules" | cut -d' ' -f1)" "$bridge_mode" \
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
ExecStartPost=/bin/sh /etc/foreman-agent/guest-forward
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
if $nft -f /etc/foreman-agent/firewall.nft && sh /etc/foreman-agent/guest-forward; then
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

# Environment VMs are routed through the box, which needs IPv4
# forwarding. On from boot (before the network is up), not just when the
# firewall loads: turning it on later makes the kernel switch LRO off on
# every NIC, and some drivers (atlantic, for one) reset the link to do it.
printf '# Written by the Foreman install script: environment VMs are routed through this box.\nnet.ipv4.ip_forward = 1\n' \
  > /etc/sysctl.d/90-foreman.conf

# Environment VMs: the root helper and what it reads. Root's own copies,
# outside anything the agent can write, so the agent can't change what
# runs as root.
set -- "$dest"/lib/foreman_agent-*/priv/vm
install -m 0755 -o root -g root "$1/vmctl" /etc/foreman-agent/vmctl
install -m 0755 -o root -g root "$1/guest-forward" /etc/foreman-agent/guest-forward
cat > /etc/foreman-agent/vmctl.conf <<EOF
# Read by /etc/foreman-agent/vmctl, as root. Written by install.sh.
SRV=/srv/foreman
AGENT_ROOT=/opt/foreman-agent
AGENT_USER=foreman
POOL=$VM_SUBNET
STATE=/var/lib/foreman-vmctl
EOF
chmod 0644 /etc/foreman-agent/vmctl.conf

cat > /etc/systemd/system/foreman-vmctl.socket <<'EOF'
[Unit]
Description=Foreman VM helper socket

[Socket]
ListenStream=/run/foreman-vmctl.sock
SocketUser=root
SocketGroup=foreman
SocketMode=0660
Accept=yes
MaxConnections=32

[Install]
WantedBy=sockets.target
EOF

cat > /etc/systemd/system/foreman-vmctl@.service <<'EOF'
[Unit]
Description=Foreman VM helper

[Service]
# Through sh: /etc is mounted noexec on Flatcar.
ExecStart=/bin/sh /etc/foreman-agent/vmctl
StandardInput=socket
StandardOutput=socket
StandardError=journal
RuntimeMaxSec=120
EOF

cat > /etc/systemd/system/foreman-agent.service <<'EOF'
[Unit]
Description=Foreman agent
After=network-online.target foreman-firewall.service foreman-vmctl.socket
Wants=network-online.target foreman-vmctl.socket
Requires=foreman-firewall.service
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
systemctl enable --now foreman-firewall-check.timer foreman-restart.path foreman-vmctl.socket
if [ "$os_id" = flatcar ]; then systemctl enable --now foreman-flatcar-update.timer; fi
# Loads the rules again on a re-run, in case they changed.
systemctl restart foreman-firewall
# Restart, not start: on a re-run the agent may already be running (or
# have hit its start limit) with the old settings and join token.
systemctl reset-failed foreman-agent 2>/dev/null || true
systemctl restart foreman-agent
rm -rf "$dest.old"

# Whether a new environment's disk is a reflink or a full copy.
probe=/srv/foreman/.reflink-probe
echo probe > "$probe"
if cp --reflink=always "$probe" "$probe.copy" 2>/dev/null; then
  echo "foreman: /srv/foreman can reflink: new environments' disks are made at once"
else
  echo "foreman: /srv/foreman can't reflink (XFS or btrfs can): each new environment's disk is a full copy"
fi
rm -f "$probe" "$probe.copy"

if [ -d /srv/foreman/envs ] && [ -n "$(ls -A /srv/foreman/envs 2>/dev/null)" ]; then
  echo "foreman: environments from before VMs are still in /srv/foreman/envs and Docker; push their work, then destroy and recreate them in Foreman"
fi

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
