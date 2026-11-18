#!/bin/sh
# End-to-end run on Linux: the control plane release image, and a box
# (a privileged container booting systemd) running the agent release.
# Covers enrollment, the box saying it can't run environment VMs without
# KVM (CI's Crew VMs have none; e2e/vm/run.sh runs environments for real),
# a reboot of the box, self-update, re-enrollment and a rollback.
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
  echo "$out" | grep -E '^(ENV|BOX|  OP|queued|set |desired|published|revoked|VM|REFUSED)' || true
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
install_agent --token "$token" | tee "$work/install.log"
grep -q "foreman: enrolled" "$work/install.log" || fail "install.sh didn't enroll"
wait_for "agent joined" 60 joined_more box1 0 0.1.0
[ "$(box systemctl is-enabled foreman-agent)" = enabled ] || fail "foreman-agent isn't enabled"
[ "$(box stat -c %a /var/lib/foreman-agent/identity.json)" = "600" ] || fail "identity file isn't 0600"
box grep -qx 'FOREMAN_JOIN_TOKEN=' /etc/foreman-agent/install.env || fail "the spent join token was kept"
[ "$(box stat -c '%a %U' /run/foreman /run/foreman/envs)" = "$(printf '711 foreman\n700 foreman')" ] ||
  fail "tmpfiles didn't create /run/foreman"
echo "ok: enrolled, the unit enabled, the token removed, /run/foreman created"
identity=$(box sha256sum /var/lib/foreman-agent/identity.json)

say "the join token is spent"
again=$($compose exec -T box sh -c "curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{\"join_token\":\"$token\",\"public_key\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\"}' http://cp:4000/api/agents/enroll")
[ "$again" = "401" ] || fail "reusing the join token returned $again"
echo "ok: reused join token refused"

say "re-running the install script keeps the enrollment and restarts the agent"
box sh -c 'printf "%s\n" "# local git fixture" FOREMAN_ALLOWED_GIT_HOSTS=git FOREMAN_INSECURE_GIT_HOSTS=git >> /etc/foreman-agent/agent.env'
local_settings=$(box sha256sum /etc/foreman-agent/agent.env)
cp_eval 'E2E.desire_version("0.1.0")'
publish 0.1.1
n=$(joins box1)
install_agent | tee "$work/install.log"
grep -q "keeps its enrollment" "$work/install.log" || fail "the re-run didn't keep the enrollment"
wait_for "agent rejoined" 60 joined_more box1 "$n"
[ "$(box sha256sum /var/lib/foreman-agent/identity.json)" = "$identity" ] || fail "the re-run changed the identity"
[ "$(box sha256sum /etc/foreman-agent/agent.env)" = "$local_settings" ] || fail "the re-run changed local settings"
current_is 0.1.0 || fail "the re-run moved off the installed release"
echo "ok: same identity, settings and installed release after a re-run"

say "a box without KVM says so, and gets no environments"
vm_status() { cp_eval 'E2E.vm_status()' | grep "^VM"; }
vm_reported() { vm_status | grep -q '^VM ready=false'; }
wait_for "the box's VM report" 60 vm_reported
# No /dev/kvm here, or (on an arm64 runner) an architecture without VMs yet.
reason=$(vm_status | sed -n 's/.* reason="\(.*\)"$/\1/p')
[ -n "$reason" ] || fail "the box didn't say why it can't run VMs: $(vm_status)"
cp_eval 'E2E.try_create()' | grep -qF "can't run environments: $reason" ||
  fail "an environment was placed on a box that can't run VMs"
echo "ok: $(vm_status)"
box test -S /run/foreman-vmctl.sock || fail "the VM helper's socket isn't there"
[ "$(box stat -c '%U %a' /etc/foreman-agent/vmctl)" = "root 755" ] || fail "the VM helper isn't root's"
box id -nG foreman | grep -qw docker && fail "the agent is still in the docker group"
echo "ok: the VM helper is root's, and the agent isn't in the docker group"

say "reboot the box: the agent comes back"
n=$(joins box1)
$compose restart box
wait_for "agent rejoined" 180 joined_more box1 "$n"
echo "ok: rejoined after a reboot"

say "self-update to 0.1.1"
cp_eval 'E2E.desire_version("0.1.1")'
# The running control plane sends the update on the agent's next connect.
box systemctl restart foreman-agent
wait_for "agent on 0.1.1" 240 joined_more box1 0 0.1.1
current_is 0.1.1 || fail "current isn't 0.1.1"
# Once the new release has joined, the agent clears the rollback state, so
# a crash much later can't roll it back to a stale release.
wait_for "rollback state cleared after the join" 60 no_rollback_state
echo "ok: self-updated"

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
