#!/usr/bin/env bash
# Starts the control plane on the Amp Box, reachable only on the tailnet:
# tailscaled runs in userspace mode as the deployment's account, Foreman
# listens on loopback, and `tailscale serve` gives it HTTPS on the tailnet,
# the same shape as docs/setup/personal.md. The deployment's public URL is
# served by placeholder.mjs instead.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
data=$AMP_DEPLOYMENT_DATA_DIRECTORY
state=$data/tailscale
sock=$state/tailscaled.sock
mkdir -p "$state" "$data/tmp" "$data/agent-releases"

ts() { "$here/bin/tailscale" --socket="$sock" "$@"; }

"$here/bin/tailscaled" --tun=userspace-networking --statedir="$state" --socket="$sock" --port=0 \
  >>"$state/tailscaled.log" 2>&1 &
tailscaled=$!
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
until [ -S "$sock" ]; do sleep 0.5; done

# The auth key is only needed the first time; the login is kept in $state.
ts up --hostname="${FOREMAN_TS_HOSTNAME:-foreman}" ${TS_AUTHKEY:+--authkey="$TS_AUTHKEY"}
ts serve --bg --https=443 "http://127.0.0.1:$FOREMAN_PORT"

host=$(ts status --json --peers=false | node -e \
  'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).Self.DNSName.replace(/\.$/,"")))')
echo "Foreman is at https://$host"

export PHX_HOST=$host PHX_SERVER=true PORT=$FOREMAN_PORT \
  DATABASE_PATH=$data/foreman.db \
  FOREMAN_AGENT_RELEASE_DIR=$data/agent-releases \
  RELEASE_TMP=$data/tmp LANG=C.UTF-8
"$here/foreman/bin/foreman" start &
foreman=$!

# Either one stopping takes the service down, and systemd restarts both.
wait -n "$tailscaled" "$foreman"
exit 1
