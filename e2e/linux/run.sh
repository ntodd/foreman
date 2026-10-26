#!/bin/sh
# End-to-end run on Linux: the control plane release image, and a box
# (docker-in-docker) running the agent release. Covers enrollment,
# create, secrets delivery, a reboot of the box, self-update and destroy.
#
#   e2e/linux/run.sh            build images, run, leave the stack up
#   e2e/linux/run.sh --down     tear the stack down (and its volumes)
#   e2e/linux/run.sh --logs     print the stack's logs and the box's journal
#
# E2E_PROJECT (default foreman-e2e) names the compose project and the
# images, so runs sharing a Docker daemon don't collide; --down and --logs
# need the same one.
#
# The commands in single quotes run in the box or its containers.
# shellcheck disable=SC2016
set -eu

cd "$(dirname "$0")/../.."
root=$(pwd)
project=${E2E_PROJECT:-foreman-e2e}
work=tmp/$project
export E2E_CP_IMAGE="$project-cp" E2E_BOX_IMAGE="$project-box"
mkdir -p "$work"
touch "$work/env"
compose="docker compose -p $project -f e2e/linux/compose.yml --env-file $work/env"

case "${1:-}" in
  --down)
    $compose --profile box down --volumes --remove-orphans
    exit 0
    ;;
  --logs)
    $compose --profile box logs --no-color --timestamps
    if [ -n "$($compose ps -q box)" ]; then
      echo "== the box's journal"
      $compose exec -T box journalctl --no-pager -o short-iso -u docker -u foreman-agent -u foreman-agent-rollback
    fi
    exit 0
    ;;
esac

# mise if it's there (it pins Elixir for this repo), otherwise the mix on PATH.
if command -v mise >/dev/null 2>&1; then mix="mise x -- mix"; else mix=mix; fi

say() { printf '\n== %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

# eval inside the control plane image, without starting a second HTTP server.
cp_eval() {
  out=$($compose exec -T cp env -u PHX_SERVER /app/bin/foreman eval "Code.eval_file(\"/e2e/linux/eval.exs\"); $1" 2>&1) ||
    { echo "$out" >&2; fail "eval failed: $1"; }
  echo "$out" | grep -E '^(ENV|BOX|  OP|queued|set |desired|published|revoked)' || true
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
# Like wait_for env_is, but gives up as soon as the environment errors.
wait_for_env() {
  i=0
  until [ "$(env_observed "$1")" = "$2" ]; do
    if [ "$(env_observed "$1")" = error ]; then
      cp_eval 'E2E.status()' >&2
      $compose exec -T cp env -u PHX_SERVER /app/bin/foreman eval "Code.eval_file(\"/e2e/linux/eval.exs\"); E2E.log(\"$1\")" 2>&1 | tail -40 >&2
      fail "$1 errored waiting for $2"
    fi
    i=$((i + 5))
    [ $i -lt "$3" ] || fail "timed out waiting for: $1 $2"
    sleep 5
  done
  echo "ok: $1 $2"
}

# How many times box $1 has joined (on version $2, if given). Waits take
# the count before the step and look for more, so a join from an earlier
# step can't satisfy them.
joins() { $compose logs cp | grep -c "agent $1 joined (${2:-}" || true; }
joined_more() { [ "$(joins "$1" "${3:-}")" -gt "$2" ]; }
refusals() { $compose logs cp | grep -c "refused an agent connect" || true; }
refused_more() { [ "$(refusals)" -gt "$1" ]; }

box_is_up() { [ "$(box systemctl is-active docker)" = active ]; }
current_is() { [ "$(box readlink /opt/foreman-agent/current)" = "releases/$1" ]; }
no_rollback_state() { ! box test -e /opt/foreman-agent/previous && ! box test -e /opt/foreman-agent/update-pending; }

# The served install script, run on the box as an operator would.
install_agent() { box sh -c "curl -fsSL http://cp:4000/agent/install.sh | sh -s -- $*"; }

target=linux-$(docker version -f '{{.Server.Arch}}')

# Agent $1 built and signed the way release.yml does it, laid out like a
# GitHub release's assets for the stub gh. A second argument replaces the
# release with a script that exits with that status.
agent_release() {
  assets=$work/release-$1
  tarball=$assets/foreman_agent-$1-$target.tar.gz
  rm -rf "$assets" && mkdir -p "$assets"
  if [ -n "${2:-}" ]; then
    mkdir -p "$assets/rel/bin"
    printf '#!/bin/sh\necho "broken agent $1" >&2\nexit %s\n' "$2" > "$assets/rel/bin/foreman_agent"
    chmod +x "$assets/rel/bin/foreman_agent"
    COPYFILE_DISABLE=1 tar -czf "$tarball" -C "$assets/rel" .
    rm -rf "$assets/rel"
  else
    docker build -q -f docker/box.Dockerfile --target agent-tarball \
      --build-arg "FOREMAN_AGENT_VERSION=$1" --build-arg "FOREMAN_RELEASE_PUBLIC_KEY=$FOREMAN_RELEASE_PUBLIC_KEY" \
      -o "$assets/out" . >/dev/null
    mv "$assets/out/foreman_agent.tar.gz" "$tarball"
    rmdir "$assets/out"
  fi
  (cd apps/foreman_agent && FOREMAN_RELEASE_PRIVATE_KEY=$FOREMAN_RELEASE_PRIVATE_KEY $mix foreman_agent.sign "$1" "$target" "$root/$tarball" | tail -1) > "$tarball.sig"
}

# Registered the way an operator does it by hand, with gh stubbed out.
publish() {
  PATH="$root/e2e/linux/bin:$PATH" E2E_RELEASE_ASSETS="$work/release-$1" FOREMAN_CONTAINER="$($compose ps -q cp)" \
    scripts/publish-agent-release.sh "$1" 2>&1 | grep "published agent $1 for $target" || fail "publish-agent-release.sh $1"
}

say "keys and fixtures"
if [ ! -s "$work/release-keys.env" ]; then
  (cd apps/foreman_agent && $mix foreman_agent.sign --keygen | grep FOREMAN_) > "$work/release-keys.env.new"
  mv "$work/release-keys.env.new" "$work/release-keys.env"
fi
# shellcheck source=/dev/null
. "$work/release-keys.env"
if [ ! -s "$work/env" ]; then
  {
    echo "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')"
    echo "FOREMAN_ENCRYPTION_KEY=$(openssl rand -base64 32)"
    echo "FOREMAN_RELEASE_PUBLIC_KEY=$FOREMAN_RELEASE_PUBLIC_KEY"
  } > "$work/env"
fi
e2e/make-git-fixture.sh "$work/git" >/dev/null

if [ "${SKIP_BUILD:-}" != "1" ]; then
  say "build images and agents 0.1.0 and 0.1.1"
  docker build -q -f docker/control-plane.Dockerfile -t "$E2E_CP_IMAGE" . >/dev/null
  docker build -q -f docker/box.Dockerfile --target box -t "$E2E_BOX_IMAGE" . >/dev/null
fi
agent_release 0.1.0
agent_release 0.1.1

say "start the control plane"
$compose --profile box down --volumes --remove-orphans >/dev/null 2>&1 || true
$compose create --quiet-pull cp git
docker cp e2e/. "$($compose ps -aq cp):/e2e"
docker cp "$work/git/." "$($compose ps -aq git):/srv"
$compose up -d cp git
wait_for "control plane listening" 120 sh -c "$compose logs cp | grep -q 'Running ForemanWeb.Endpoint'"

say "seed an admin, the fixture repo and a join token; publish agent 0.1.0"
seed() {
  $compose exec -T cp env -u PHX_SERVER E2E_ADMIN=e2e "E2E_BOX=$1" /app/bin/foreman eval 'Code.eval_file("/e2e/seed.exs")' 2>/dev/null |
    sed -n 's/^E2E_JOIN_TOKEN=//p'
}
token=$(seed box1)
[ -n "$token" ] || fail "no join token"
publish 0.1.0

say "boot the box and install the agent with the served install script"
$compose --profile box up -d box
wait_for "box booted" 120 box_is_up
# The fixture repo's host, which the agent refuses by default. A drop-in,
# because the install script owns the unit and its env file.
box sh -c 'mkdir -p /etc/systemd/system/foreman-agent.service.d && printf "[Service]\nEnvironment=FOREMAN_ALLOWED_GIT_HOSTS=git FOREMAN_INSECURE_GIT_HOSTS=git\n" > /etc/systemd/system/foreman-agent.service.d/e2e.conf'
install_agent --token "$token" | tee "$work/install.log"
grep -q "foreman: enrolled" "$work/install.log" || fail "install.sh didn't enroll"
wait_for "agent joined" 60 joined_more box1 0 0.1.0
[ "$(box systemctl is-enabled foreman-agent)" = enabled ] || fail "foreman-agent isn't enabled"
[ "$(box stat -c %a /var/lib/foreman-agent/identity.json)" = "600" ] || fail "identity file isn't 0600"
box grep -q '^FOREMAN_JOIN_TOKEN=' /etc/foreman-agent/agent.env && fail "the spent join token is still in agent.env"
[ "$(box stat -c '%a %U' /run/foreman /run/foreman/envs)" = "$(printf '711 foreman\n700 foreman')" ] ||
  fail "tmpfiles didn't create /run/foreman"
echo "ok: enrolled, the unit enabled, the token removed, /run/foreman created"
identity=$(box sha256sum /var/lib/foreman-agent/identity.json)

say "the join token is spent"
again=$($compose exec -T box sh -c "curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{\"join_token\":\"$token\",\"public_key\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\"}' http://cp:4000/api/agents/enroll")
[ "$again" = "401" ] || fail "reusing the join token returned $again"
echo "ok: reused join token refused"

say "re-running the install script keeps the enrollment and restarts the agent"
n=$(joins box1)
install_agent | tee "$work/install.log"
grep -q "keeps its enrollment" "$work/install.log" || fail "the re-run didn't keep the enrollment"
wait_for "agent rejoined" 60 joined_more box1 "$n"
[ "$(box sha256sum /var/lib/foreman-agent/identity.json)" = "$identity" ] || fail "the re-run changed the identity"
echo "ok: same identity after a re-run"

say "create an environment"
cp_eval 'E2E.create()'
wait_for_env hello-1 running 900

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

say "the agent finds the ports listening in the environment"
# A server as the devcontainer's user, the way one started over SSH runs,
# and the installed agent release reading it from the box's /proc.
box docker exec -d -u vscode "$app" perl -MIO::Socket::INET -e \
  'my $s = IO::Socket::INET->new(LocalPort => 4321, Listen => 5, Proto => "tcp", ReuseAddr => 1) or die; sleep 3600'
agent_ports() {
  box runuser -u foreman -- env RELEASE_TMP=/tmp /opt/foreman-agent/current/bin/foreman_agent eval \
    '{:ok, _} = Application.ensure_all_started(:req)
     ctx = %{config: ForemanAgent.Config.get(), docker: ForemanAgent.Docker.Engine}
     {report, _} = ForemanAgent.Ports.collect(ctx, %{})
     IO.inspect(report)'
}
port_named() { agent_ports | grep -q "%{port: $1, process: \"$2\"}"; }
wait_for "port 4321 reported, named perl" 60 port_named 4321 perl

say "a secret change reaches new shells, and marks the environment pending restart"
cp_eval 'E2E.secret("hello-1", "SIDECAR_TOKEN", "linux-secret-1")'
wait_for "secret in a login shell" 120 sh -c "$compose exec -T box docker exec -u vscode $app bash -lc 'echo \$SIDECAR_TOKEN' | grep -q linux-secret-1"
cp_eval 'E2E.status()' | grep -q "ENV hello-1" || fail "status"

say "reboot the box: tmpfs secrets vanish, containers stay stopped until the control plane is back"
n=$(joins box1)
$compose restart box
wait_for "agent rejoined" 180 joined_more box1 "$n"
wait_for_env hello-1 running 300
box docker exec -u vscode "$app" bash -lc 'echo $SIDECAR_TOKEN' | grep -q linux-secret-1 || fail "secrets not restored after reboot"
echo "ok: secrets restored and environment restarted after reboot"

say "self-update to 0.1.1"
# Pinned to what it runs, so registering 0.1.1 (unpinned boxes follow the
# newest registered) doesn't start the update before the reconnect below.
cp_eval 'E2E.desire_version("0.1.0")'
publish 0.1.1
cp_eval 'E2E.desire_version("0.1.1")'
# The running control plane sends the update on the agent's next connect.
box systemctl restart foreman-agent
wait_for "agent on 0.1.1" 240 joined_more box1 0 0.1.1
current_is 0.1.1 || fail "current isn't 0.1.1"
# Once the new release has joined, the agent clears the rollback state, so
# a crash much later can't roll it back to a stale release.
wait_for "rollback state cleared after the join" 60 no_rollback_state
env_is hello-1 running || fail "environment didn't survive the agent update"
echo "ok: self-updated, environment still running"

say "destroy"
cp_eval 'E2E.act("hello-1", "destroy")'
wait_for_env hello-1 destroyed 240
[ -z "$(box docker ps -aq --filter label=foreman.env_id)" ] || fail "containers left behind"
[ -z "$(box docker volume ls -q --filter label=com.docker.compose.project=hello-1)" ] || fail "volumes left behind"
[ -z "$(box ls /srv/foreman/envs)" ] || fail "workspace left behind"
echo "ok: nothing left on the box"

say "revoke the box, then enroll it again with --reenroll and a new token"
# The revoke runs in an eval VM, so its disconnect doesn't reach the
# running control plane; restarting the agent checks that its identity is
# refused from now on.
cp_eval 'E2E.revoke()'
n=$(joins box1)
r=$(refusals)
box systemctl restart foreman-agent
wait_for "the revoked identity refused" 60 refused_more "$r"
[ "$(joins box1)" = "$n" ] || fail "the revoked box joined again"
token=$(seed box2)
[ -n "$token" ] || fail "no join token"
install_agent --reenroll --token "$token" | tee "$work/install.log"
grep -q "foreman: enrolled" "$work/install.log" || fail "install.sh --reenroll didn't enroll"
wait_for "agent joined as box2" 60 joined_more box2 0 0.1.1
[ "$(box sha256sum /var/lib/foreman-agent/identity.json)" != "$identity" ] || fail "--reenroll kept the old identity"
box sh -c 'ls /var/lib/foreman-agent/identity.json.replaced-*' >/dev/null || fail "the old identity wasn't kept aside"
echo "ok: enrolled again with a new identity, the old one kept aside"

say "an update that crash-loops is rolled back by the systemd unit"
agent_release 0.1.2 1
cp_eval 'E2E.desire_version("0.1.1")'
publish 0.1.2
cp_eval 'E2E.desire_version("0.1.2")'
# Counted before the restart, which joins on 0.1.1 once before taking the
# update; the rollback's join is the one after that. Counting later could
# miss a rollback that's already done.
n=$(joins box2 0.1.1)
rollbacks=$(box systemctl show -p InactiveExitTimestampMonotonic --value foreman-agent-rollback)
box systemctl restart foreman-agent
wait_for "0.1.2 installed" 120 box test -d /opt/foreman-agent/releases/0.1.2
# Back to what it ran, so the control plane doesn't send 0.1.2 again once
# it's back.
cp_eval 'E2E.desire_version("0.1.1")'
wait_for "agent rejoined on 0.1.1 after the update" 180 joined_more box2 "$((n + 1))" 0.1.1
[ "$(box systemctl show -p InactiveExitTimestampMonotonic --value foreman-agent-rollback)" != "$rollbacks" ] ||
  fail "the agent came back without the rollback unit"
current_is 0.1.1 || fail "current isn't back on 0.1.1"
no_rollback_state || fail "rollback state left behind"
echo "ok: the rollback unit switched back to 0.1.1, which rejoined"

say "PASSED"
