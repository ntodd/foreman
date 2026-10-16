#!/bin/sh
# Joins this environment to the tailnet. Started in the background by
# entrypoint.sh on every container start, as root, and idempotent.
#
# The node's identity lives in /var/lib/tailscale, a named volume, so the
# auth key at /run/foreman/ts-authkey is only needed the first time.
# Rebuilds keep the same node and hostname.
#
# Best effort: every failure path logs and exits 0.

# shellcheck source=/dev/null
. /usr/local/share/foreman/options 2>/dev/null || true

log() { echo "tailscale-up: $*"; }

ts_hostname=${TS_HOSTNAME:-${FOREMAN_ENV:-$(hostname)}}
authkey_file=/run/foreman/ts-authkey
accept_dns=${FOREMAN_ACCEPT_DNS:-true}
sock=/var/run/tailscale/tailscaled.sock

mkdir -p /var/lib/tailscale /var/run/tailscale

# Liveness by asking the daemon rather than by pgrep: procps isn't in
# every base image, and a stale socket file would fool a bare -S test.
daemon_running() {
  [ -S "$sock" ] || return 1
  tailscale --socket="$sock" status --json 2>/dev/null | grep -q '"BackendState"'
}

# Running / NeedsLogin / Stopped / NoState, read without jq.
backend_state() {
  tailscale --socket="$sock" status --json 2>/dev/null |
    grep -o '"BackendState"[[:space:]]*:[[:space:]]*"[^"]*"' |
    head -1 |
    sed 's/.*"\(.*\)"$/\1/'
}

# Userspace networking, always: tailscaled needs no TUN device and no
# NET_ADMIN, and never touches the container's routes, firewall or DNS.
# Connections into the environment (Tailscale SSH, its ports, `tailscale
# serve`) work as usual. Connections out to other tailnet machines go
# through the proxy on 127.0.0.2:1055.
#
# Not 127.0.0.1: tailscaled hands connections from the tailnet to
# 127.0.0.1:<port>, so a proxy there would let any peer the ACL lets in
# reach the compose network and the box's.
proxy=127.0.0.2:1055
start_daemon() {
  log "starting tailscaled with userspace networking (outbound proxy on $proxy)"
  nohup tailscaled --state=/var/lib/tailscale/tailscaled.state --socket="$sock" \
    --tun=userspace-networking --socks5-server="$proxy" \
    --outbound-http-proxy-listen="$proxy" \
    >>/var/log/tailscaled.log 2>&1 &

  i=0
  while [ $i -lt 30 ]; do
    daemon_running && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

if ! daemon_running; then
  if ! start_daemon; then
    log "tailscaled did not come up within 15s, see /var/log/tailscaled.log"
    exit 0
  fi
fi

# A node that has joined before says NoState for a moment after tailscaled
# starts, while it loads its saved profile; a new one says NeedsLogin at
# once. Deciding during that moment would log a joined node in again.
state=$(backend_state)
i=0
while [ "$state" = "NoState" ] && [ $i -lt 30 ]; do
  sleep 0.5
  i=$((i + 1))
  state=$(backend_state)
done

if [ "$state" = "Running" ] || [ "$state" = "Starting" ]; then
  log "already up as $(tailscale --socket="$sock" ip -4 2>/dev/null | head -1)"
  exit 0
fi

# A node that has joined before only needs `up`; a new one needs the key.
set -- --hostname="$ts_hostname" --ssh --accept-dns="$accept_dns" --reset
if [ "$state" = "NeedsLogin" ] || [ "$state" = "NoState" ]; then
  if [ ! -s "$authkey_file" ]; then
    log "not logged in and no auth key at $authkey_file; Foreman writes one when the environment is created"
    exit 0
  fi
  # file: rather than the key itself, so it never lands in argv.
  set -- "$@" --auth-key="file:$authkey_file"
fi

# Best effort means never hanging the background job either.
if ! tailscale --socket="$sock" up --timeout=60s "$@"; then
  log "tailscale up failed: expired or revoked auth key, or tags the key's owner can't assign?"
  exit 0
fi

log "joined as $ts_hostname ($(tailscale --socket="$sock" ip -4 2>/dev/null | head -1))"

exit 0
