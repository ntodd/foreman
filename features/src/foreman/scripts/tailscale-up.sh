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
dns_check_host=${FOREMAN_DNS_CHECK_HOST:-}
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

# Userspace networking is a fallback, not the default: without a TUN device
# the tailnet is only reachable through the proxy on localhost:1055.
start_daemon() {
  if [ -c /dev/net/tun ]; then
    set -- --tun=tailscale0
  else
    log "no /dev/net/tun; using userspace networking (proxy on localhost:1055)"
    set -- --tun=userspace-networking --socks5-server=localhost:1055 \
      --outbound-http-proxy-listen=localhost:1055
  fi

  nohup tailscaled --state=/var/lib/tailscale/tailscaled.state --socket="$sock" "$@" \
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

state=$(backend_state)
if [ "$state" = "Running" ]; then
  log "already up as $(tailscale --socket="$sock" ip -4 2>/dev/null | head -1)"
  exit 0
fi

# A node that has joined before only needs `up`; a new one needs the key.
set -- --hostname="$ts_hostname" --ssh --accept-dns="$accept_dns" --netfilter-mode=off --reset
if [ "$state" = "NeedsLogin" ] || [ "$state" = "NoState" ]; then
  if [ ! -s "$authkey_file" ]; then
    log "not logged in and no auth key at $authkey_file; Foreman writes one when the environment is created"
    exit 0
  fi
  # file: rather than the key itself, so it never lands in argv.
  set -- "$@" --auth-key="file:$authkey_file"
fi

# --netfilter-mode=off: tailscaled's default rules drop traffic to
# 100.64.0.0/10 that it can't carry itself, which includes the host's own
# tailnet address. This node only needs inbound tailnet traffic, and
# tailnet ACLs are still enforced by tailscaled either way.
if ! tailscale --socket="$sock" up "$@"; then
  log "tailscale up failed: expired or revoked auth key, or tags the key's owner can't assign?"
  exit 0
fi

log "joined as $ts_hostname ($(tailscale --socket="$sock" ip -4 2>/dev/null | head -1))"

# --accept-dns points resolv.conf at MagicDNS, which forwards other names
# to Docker's resolver. If that ever breaks, compose service names stop
# resolving with nothing pointing back at Tailscale, so say so here.
if [ "$accept_dns" = "true" ] && [ -n "$dns_check_host" ]; then
  if ! getent hosts "$dns_check_host" >/dev/null 2>&1; then
    log "'$dns_check_host' no longer resolves: MagicDNS is not forwarding to Docker's resolver."
    log "Set the feature's acceptDns option to false and use tailnet IPs instead."
  fi
fi

exit 0
