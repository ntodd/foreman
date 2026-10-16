#!/bin/sh
# Checks an environment on a real tailnet, which the other end-to-end runs
# can't: Tailscale SSH into the devcontainer, reaching its ports, compose
# DNS left alone, and the device removed on destroy.
#
# Runs a dev control plane (with your Tailscale OAuth client) and a local
# agent against this machine's Docker, creates an environment from the
# fixture repo, checks it from this machine over the tailnet, and destroys
# it. The run has its own database, repo name and compose project, and
# never sweeps the tailnet, so it leaves your dev database, your other
# compose projects and your tailnet's other devices alone.
#
#   FOREMAN_TAILSCALE_CLIENT_ID=... FOREMAN_TAILSCALE_CLIENT_SECRET=... e2e/tailnet.sh
#
# Needs: Docker, mise (or Elixir and Node on PATH), Python 3, Perl, and
# Tailscale running on this machine, signed in to the same tailnet. The
# OAuth client needs the auth_keys and devices scopes and must own
# tag:foreman-env, and the tailnet policy must let you SSH to
# tag:foreman-env as vscode (see docs/setup/tailscale.md).
set -eu

cd "$(dirname "$0")/.."
root=$(pwd)
work=$root/tmp/e2e-tailnet
port=4100
git_port=8899

: "${FOREMAN_TAILSCALE_CLIENT_ID:?set FOREMAN_TAILSCALE_CLIENT_ID}"
: "${FOREMAN_TAILSCALE_CLIENT_SECRET:?set FOREMAN_TAILSCALE_CLIENT_SECRET}"

say() { printf '\n== %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

passed=0
failed=0
check() {
  desc=$1
  shift
  if "$@" >"$work/check.out" 2>&1; then
    echo "PASS: $desc"
    passed=$((passed + 1))
  else
    echo "FAIL: $desc"
    sed 's/^/      /' "$work/check.out"
    failed=$((failed + 1))
  fi
}

wait_for() {
  desc=$1 timeout=$2
  shift 2
  i=0
  until "$@" >/dev/null 2>&1; do
    i=$((i + 5))
    [ $i -lt "$timeout" ] || fail "timed out waiting for: $desc"
    sleep 5
  done
  echo "ok: $desc"
}

ts=$(command -v tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)
[ -x "$ts" ] || fail "can't find the tailscale CLI"
"$ts" status >/dev/null 2>&1 || fail "Tailscale isn't running or signed in on this machine"
docker info >/dev/null 2>&1 || fail "Docker isn't running"
command -v python3 >/dev/null || fail "python3 is needed to serve the fixture repo"
command -v perl >/dev/null || fail "perl is needed to run background jobs in their own process groups"
for p in $port $git_port; do
  if lsof -i ":$p" -sTCP:LISTEN >/dev/null 2>&1; then fail "port $p is in use"; fi
done

# A name nothing else on this machine or tailnet uses: the repo, and so the
# compose project and the tailnet hostname.
name=foreman-check-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')
slug=$name-1
if docker ps -aq --filter "label=com.docker.compose.project=$slug" | grep -q . ||
  docker volume ls -q --filter "label=com.docker.compose.project=$slug" | grep -q .; then
  fail "a compose project named $slug already exists here; run again"
fi
if "$ts" status | grep -qw "$slug"; then fail "a tailnet device named $slug already exists; run again"; fi

devcontainer_cli=$root/.tools/node_modules/.bin/devcontainer
if [ ! -x "$devcontainer_cli" ]; then
  say "installing the devcontainer CLI into .tools"
  npm install --prefix .tools --no-fund --no-audit --silent @devcontainers/cli@0.89.0
fi

if command -v mise >/dev/null 2>&1; then
  mix() { mise x -- mix "$@"; }
  mix="mise x -- mix"
else
  mix=mix
fi

rm -rf "$work"
mkdir -p "$work"

# Everything this run starts: a dev build on its own database, the fixture
# repo under this run's name, and no tailnet sweep (with an empty database
# it would delete every environment node it doesn't know about).
unset FOREMAN_DB DATABASE_URL
export MIX_ENV=dev FOREMAN_DEV_DATABASE="$work/foreman.db" FOREMAN_TAILNET_SWEEP=false
export E2E_ADMIN=e2e E2E_REPO="acme/$name"

pids=""
env_id=""
cleaned=""

# Starts a background job as the leader of its own process group, so
# cleanup can stop everything under it (mix runs its VM under mise), with
# or without a terminal.
bg() {
  perl -e 'setpgrp(0, 0); exec @ARGV or die "exec $ARGV[0]: $!\n"' -- "$@" &
  pids="$pids $!"
}

stop_jobs() {
  for pid in $pids; do kill -TERM -- "-$pid" 2>/dev/null; done
  i=0
  while [ $i -lt 20 ]; do
    alive=""
    for pid in $pids; do kill -0 -- "-$pid" 2>/dev/null && alive=1; done
    [ -n "$alive" ] || return 0
    sleep 1
    i=$((i + 1))
  done
  for pid in $pids; do kill -KILL -- "-$pid" 2>/dev/null; done
}

cleanup() {
  [ -z "$cleaned" ] || return 0
  cleaned=1
  set +e
  # Only containers this run made, found by its environment's id.
  if [ -n "$env_id" ] && docker ps -aq --filter "label=foreman.env_id=$env_id" | grep -q .; then
    echo "removing this run's containers ($slug)"
    docker compose -p "$slug" down -v >/dev/null 2>&1
  fi
  stop_jobs
  if [ -n "$env_id" ] && "$ts" status 2>/dev/null | grep -qw "$slug"; then
    echo "note: $slug is still on the tailnet; remove it in the Tailscale admin console"
  fi
  echo "logs: $work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

say "fixture repo ($E2E_REPO)"
e2e/make-git-fixture.sh "$work/git" "$name" >/dev/null
bg sh -c "cd '$work/git' && exec python3 -m http.server $git_port --bind 127.0.0.1 >'$work/git.log' 2>&1"

say "control plane"
cd apps/foreman
mix ecto.setup >"$work/setup.log" 2>&1 || fail "mix ecto.setup failed, see $work/setup.log"
token=$(mix run ../../e2e/seed.exs 2>/dev/null | sed -n 's/^E2E_JOIN_TOKEN=//p')
[ -n "$token" ] || fail "the seed didn't print a join token"
bg env PORT=$port FOREMAN_GIT_BASE_URL=http://127.0.0.1:$git_port sh -c "$mix phx.server >'$work/cp.log' 2>&1"
wait_for "control plane up" 240 curl -fs "http://localhost:$port/healthz"

say "agent"
cd "$root/apps/foreman_agent"
bg env FOREMAN_URL=http://localhost:$port FOREMAN_JOIN_TOKEN="$token" \
  FOREMAN_AGENT_DATA_DIR="$work/agent" FOREMAN_ENVS_ROOT="$work/envs" \
  FOREMAN_SECRETS_ROOT="$work/run" FOREMAN_RELEASE_ROOT="$work/opt" \
  FOREMAN_DEVCONTAINER_CLI="$devcontainer_cli" \
  FOREMAN_ALLOWED_GIT_HOSTS=127.0.0.1 FOREMAN_INSECURE_GIT_HOSTS=127.0.0.1 \
  sh -c "$mix run --no-halt >'$work/agent.log' 2>&1"
wait_for "agent joined" 180 grep -q "joined (" "$work/cp.log"

cd "$root/apps/foreman"
cp_eval() { mix run -e "Code.eval_file(\"../../e2e/linux/eval.exs\"); $1" 2>/dev/null; }
observed() { cp_eval 'E2E.status()' | grep "ENV $slug " | sed 's/.*observed=\([a-z]*\).*/\1/'; }
is_running() { [ "$(observed)" = running ]; }

say "create an environment (the first build pulls images)"
created=$(cp_eval 'E2E.create()')
env_id=$(echo "$created" | sed -n 's/^ENV=\([^ ]*\) .*/\1/p')
[ -n "$env_id" ] || fail "couldn't create an environment"
echo "$created" | grep -q "SLUG=$slug\$" || fail "expected the environment to be $slug: $created"
echo "environment $slug"
wait_for "$slug running" 900 is_running
app=$(docker ps -q --filter "label=foreman.env_id=$env_id" --filter "label=com.docker.compose.service=app")
[ -n "$app" ] || fail "no app container for $slug"
wait_for "$slug on the tailnet" 180 sh -c "'$ts' status | grep -qw '$slug'"
ip=$("$ts" ip -4 "$slug")
echo "tailnet address $ip"

ssh_env() {
  ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$work/known_hosts" "vscode@$slug" "$@"
}
expect_output() {
  want=$1
  shift
  out=$("$@") || { echo "$out"; return 1; }
  echo "$out"
  echo "$out" | grep -q -- "$want"
}

say "checks"
check "the devcontainer has no NET_ADMIN" sh -c "
  hex=\$(docker exec -u root $app sed -n 's/^CapBnd:[[:space:]]*//p' /proc/1/status)
  [ \$(( 0x\$hex & (1 << 12) )) -eq 0 ]"
check "the devcontainer has no /dev/net/tun" sh -c "! docker exec -u root $app test -e /dev/net/tun"
# tailscale-up.sh runs in the background at container start, logging to
# /var/log or (when it went through sudo) /tmp.
check "Tailscale runs in userspace mode" sh -c "
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    docker exec -u root $app sh -c 'cat /var/log/foreman-tailscale.log /tmp/foreman-tailscale.log 2>/dev/null' |
      grep -q 'userspace networking' && exit 0
    sleep 3
  done
  exit 1"
check "Tailscale SSH lands in the app container as vscode" \
  expect_output "repo-ok" ssh_env "whoami; test -d /workspaces/$name && echo repo-ok"
check "a login shell over SSH gets Foreman's environment" \
  expect_output "FOREMAN_ENV=$slug" ssh_env "bash -lc 'echo FOREMAN_ENV=\$FOREMAN_ENV'"
check "a plain SSH command gets it too" \
  expect_output "$slug" ssh_env 'printenv FOREMAN_ENV'
check "compose service names still resolve inside" docker exec "$app" getent hosts sidecar

# A tiny web server (perl is in the image): address, port, reply.
# shellcheck disable=SC2016
serve() {
  docker exec -d -u vscode "$app" perl -MIO::Socket::INET -e '
    $s = IO::Socket::INET->new(LocalAddr => shift, LocalPort => shift, Listen => 5, ReuseAddr => 1)
      or die "listen: $!";
    $m = shift;
    while ($c = $s->accept) { <$c>; print $c "HTTP/1.0 200 OK\r\n\r\n$m\n"; close $c }' "$@"
}
serve 0.0.0.0 8000 foreman-port-ok
serve 127.0.0.1 8001 foreman-loopback-ok
sleep 2
check "a port is reachable by name (http://$slug:8000)" \
  expect_output "foreman-port-ok" curl -fsS --max-time 15 "http://$slug:8000/"
check "a port is reachable by address (http://$ip:8000)" \
  expect_output "foreman-port-ok" curl -fsS --max-time 15 "http://$ip:8000/"
# Userspace Tailscale delivers tailnet connections to 127.0.0.1, so a
# localhost-only server is reachable too, and the proxy (on 127.0.0.2)
# must not be.
check "a server bound to 127.0.0.1 is reachable too" \
  expect_output "foreman-loopback-ok" curl -fsS --max-time 15 "http://$ip:8001/"
check "the outbound proxy isn't reachable from the tailnet" \
  sh -c "! curl -sS --max-time 10 -o /dev/null http://$ip:1055/"

if command -v code >/dev/null 2>&1 && [ -t 0 ]; then
  echo
  echo "To check VS Code by hand before the environment is destroyed:"
  echo "  code --remote ssh-remote+vscode@$slug /workspaces/$name"
  printf "Press Enter to destroy %s and finish... " "$slug"
  read -r _
fi

say "destroy"
cp_eval "E2E.act(\"$slug\", \"destroy\")" >/dev/null
wait_for "$slug containers removed" 300 sh -c "! docker ps -aq --filter 'label=foreman.env_id=$env_id' | grep -q ."
check "the device leaves the tailnet" sh -c "
  i=0
  while '$ts' status | grep -qw '$slug'; do
    i=\$((i + 5)); [ \$i -lt 180 ] || exit 1; sleep 5
  done"
env_id=""

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
