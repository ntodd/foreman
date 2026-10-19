#!/bin/sh
# End-to-end run on Linux: the control plane release image, and a box
# (docker-in-docker) running the agent release. Covers enrollment,
# create, secrets delivery, a reboot of the box, self-update and destroy.
#
#   e2e/linux/run.sh            build images, run, leave the stack up
#   e2e/linux/run.sh --down     tear the stack down (and its volumes)
set -eu

cd "$(dirname "$0")/../.."
root=$(pwd)
work=tmp/e2e-linux
compose="docker compose -f e2e/linux/compose.yml --env-file $work/env"
mkdir -p "$work"

if [ "${1:-}" = "--down" ]; then
  $compose --profile box down --volumes --remove-orphans
  exit 0
fi

say() { printf '\n== %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

# eval inside the control plane image, without starting a second HTTP server.
cp_eval() {
  out=$($compose exec -T cp env -u PHX_SERVER /app/bin/foreman eval "Code.eval_file(\"/e2e/linux/eval.exs\"); $1" 2>&1) ||
    { echo "$out" >&2; fail "eval failed: $1"; }
  echo "$out" | grep -E '^(ENV|BOX|  OP|queued|set |desired|published)' || true
}

box() { $compose exec -T box "$@"; }

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

env_observed() { cp_eval 'E2E.status()' | grep "ENV $1 " | sed 's/.*observed=\([a-z]*\).*/\1/'; }
env_is() { [ "$(env_observed "$1")" = "$2" ]; }

say "keys and fixtures"
if [ ! -f "$work/release-keys.env" ]; then
  (cd apps/foreman_agent && mise x -- mix foreman_agent.sign --keygen | grep FOREMAN_) > "$work/release-keys.env"
fi
. "$work/release-keys.env"
if [ ! -f "$work/env" ]; then
  {
    echo "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')"
    echo "FOREMAN_ENCRYPTION_KEY=$(openssl rand -base64 32)"
    echo "FOREMAN_RELEASE_PUBLIC_KEY=$FOREMAN_RELEASE_PUBLIC_KEY"
  } > "$work/env"
fi
e2e/make-git-fixture.sh "$work/git" >/dev/null

if [ "${SKIP_BUILD:-}" != "1" ]; then
  say "build images"
  docker build -q -f docker/control-plane.Dockerfile -t foreman-cp:e2e . >/dev/null
  docker build -q -f docker/box.Dockerfile --target box --build-arg "FOREMAN_RELEASE_PUBLIC_KEY=$FOREMAN_RELEASE_PUBLIC_KEY" -t foreman-box:e2e . >/dev/null
fi

say "start the control plane"
$compose --profile box down --volumes --remove-orphans >/dev/null 2>&1 || true
$compose up -d cp git
wait_for "control plane listening" 120 sh -c "$compose logs cp | grep -q 'Running ForemanWeb.Endpoint'"

say "seed an admin, the fixture repo and a join token"
token=$($compose exec -T cp env -u PHX_SERVER E2E_ADMIN=e2e E2E_BOX=box1 /app/bin/foreman eval 'Code.eval_file("/e2e/seed.exs")' 2>/dev/null | sed -n 's/^E2E_JOIN_TOKEN=//p')
[ -n "$token" ] || fail "no join token"

say "start the box; the agent enrolls with the token"
FOREMAN_JOIN_TOKEN=$token $compose --profile box up -d box
wait_for "agent joined" 180 sh -c "$compose logs cp | grep -q 'agent box1 joined'"
box test -s /var/lib/foreman-agent/identity.json || fail "no agent identity"
[ "$(box stat -c %a /var/lib/foreman-agent/identity.json)" = "600" ] || fail "identity file isn't 0600"

say "the join token is spent"
again=$($compose exec -T box sh -c "curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{\"join_token\":\"$token\",\"public_key\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\"}' http://cp:4000/api/agents/enroll")
[ "$again" = "401" ] || fail "reusing the join token returned $again"
echo "ok: reused join token refused"

say "create an environment"
cp_eval 'E2E.create()'
wait_for "hello-1 running" 900 env_is hello-1 running

app=$(box docker ps -q --filter label=foreman.env_id --filter label=com.docker.compose.service=app)
[ -n "$app" ] || fail "no app container"
echo "ok: app container $app"

say "inside the environment"
box docker exec -u vscode "$app" bash -lc 'git config user.email' | grep -q e2e@example.com || fail "git identity missing"
echo "ok: git identity"
box docker exec "$app" test -f /usr/local/share/foreman/profile.sh || fail "the Foreman feature isn't installed"
box docker exec "$app" sh -c 'command -v tailscale' >/dev/null && fail "tailscale installed though the control plane has no tailnet"
echo "ok: Foreman feature installed (without Tailscale, which isn't configured here)"
box docker exec -u root "$app" sh -c 'touch /run/foreman/x' 2>/dev/null && fail "secrets mount is writable"
echo "ok: /run/foreman is read-only"
ports=$(box docker ps --filter label=foreman.env_id --format '{{.Ports}}' | tr -d '[:space:]')
[ -z "$ports" ] || fail "published ports: $ports"
echo "ok: nothing published"

# On Linux the devcontainer CLI maps the container user to the agent's uid,
# so the workspace and the 0600 secrets are readable without loosening them.
foreman_uid=$(box id -u foreman)
vscode_uid=$(box docker exec "$app" id -u vscode)
[ "$foreman_uid" = "$vscode_uid" ] || fail "vscode is uid $vscode_uid, foreman is $foreman_uid"
echo "ok: container user is the agent's uid ($foreman_uid)"
secrets_dir=$(box sh -c 'ls -d /run/foreman/envs/*')
[ "$(box stat -c %a "$secrets_dir")" = "700" ] || fail "secrets dir isn't 0700"
[ "$(box stat -c %a "$secrets_dir/secrets.env")" = "600" ] || fail "secrets.env isn't 0600"
box su -s /bin/sh nobody -c "cat $secrets_dir/secrets.env" 2>/dev/null && fail "another user on the box can read secrets"
echo "ok: secrets are 0600, unreadable by other box users"
# Tailscale SSH starts a clean login shell; the saved container environment
# fills it in, readable only by the devcontainer's user.
[ "$(box docker exec -u root "$app" stat -c '%u %a' /etc/foreman/container.env)" = "$vscode_uid 600" ] ||
  fail "the saved container environment isn't 0600 and vscode's"
box docker exec -u vscode "$app" env -i HOME=/home/vscode bash -lc 'echo "$FOREMAN_ENV"' | grep -qx hello-1 ||
  fail "a clean login shell doesn't get the container's environment"
echo "ok: a clean login shell gets the container's environment, from a file only vscode can read"

say "a secret change reaches new shells, and marks the environment pending restart"
cp_eval 'E2E.secret("hello-1", "SIDECAR_TOKEN", "linux-secret-1")'
wait_for "secret in a login shell" 120 sh -c "$compose exec -T box docker exec -u vscode $app bash -lc 'echo \$SIDECAR_TOKEN' | grep -q linux-secret-1"
cp_eval 'E2E.status()' | grep -q "ENV hello-1" || fail "status"

say "reboot the box: tmpfs secrets vanish, containers stay stopped until the control plane is back"
$compose restart box
wait_for "agent rejoined" 180 sh -c "[ \$($compose logs cp | grep -c 'agent box1 joined') -ge 2 ]"
wait_for "hello-1 running again" 300 env_is hello-1 running
box docker exec -u vscode "$app" bash -lc 'echo $SIDECAR_TOKEN' | grep -q linux-secret-1 || fail "secrets not restored after reboot"
echo "ok: secrets restored and environment restarted after reboot"

say "self-update to 0.1.1"
docker build -q -f docker/box.Dockerfile --target agent-tarball \
  --build-arg FOREMAN_AGENT_VERSION=0.1.1 --build-arg "FOREMAN_RELEASE_PUBLIC_KEY=$FOREMAN_RELEASE_PUBLIC_KEY" \
  -o "$work/agent-0.1.1" . >/dev/null
target=linux-$(box dpkg --print-architecture)
sig=$(cd apps/foreman_agent && FOREMAN_RELEASE_PRIVATE_KEY=$FOREMAN_RELEASE_PRIVATE_KEY mise x -- mix foreman_agent.sign 0.1.1 "$target" "$root/$work/agent-0.1.1/foreman_agent.tar.gz" | tail -1)
# Pinned to what it runs, so registering 0.1.1 (this image carries no
# agents, so unpinned boxes follow the newest registered) doesn't start the
# update before the reconnect below.
cp_eval 'E2E.desire_version("0.1.0")'
docker cp "$work/agent-0.1.1/foreman_agent.tar.gz" "$($compose ps -q cp):/tmp/foreman_agent-0.1.1.tar.gz"
$compose exec -T cp /app/bin/foreman eval "Foreman.Release.publish_agent(\"0.1.1\", \"$target\", \"/tmp/foreman_agent-0.1.1.tar.gz\", \"$sig\")" 2>/dev/null | grep published
cp_eval 'E2E.desire_version("0.1.1")'
# The running control plane sends the update on the agent's next connect.
box pkill -f beam.smp || true
wait_for "agent on 0.1.1" 240 sh -c "$compose logs cp | grep -q 'agent box1 joined (0.1.1'"
box readlink /opt/foreman-agent/current | grep -q 0.1.1 || fail "current isn't 0.1.1"
# Once the new release has joined, the agent clears the rollback state, so
# a crash much later can't roll it back to a stale release.
wait_for "rollback state cleared after the join" 60 sh -c \
  "! $compose exec -T box test -e /opt/foreman-agent/previous && ! $compose exec -T box test -e /opt/foreman-agent/update-pending"
env_is hello-1 running || fail "environment didn't survive the agent update"
echo "ok: self-updated, environment still running"

say "destroy"
cp_eval 'E2E.act("hello-1", "destroy")'
wait_for "hello-1 destroyed" 240 env_is hello-1 destroyed
[ -z "$(box docker ps -aq --filter label=foreman.env_id)" ] || fail "containers left behind"
[ -z "$(box docker volume ls -q --filter label=com.docker.compose.project=hello-1)" ] || fail "volumes left behind"
[ -z "$(box ls /srv/foreman/envs)" ] || fail "workspace left behind"
echo "ok: nothing left on the box"

say "PASSED"
