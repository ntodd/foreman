#!/bin/sh
# End-to-end run of a Flatcar box: the control plane release image, and a
# box made by the launcher for this machine, booted for real: mac.sh
# (vfkit, Apple's hypervisor) on macOS, vm.sh (QEMU with KVM) on Linux.
# Covers the launcher, the box's first boot (Ignition, the extensions,
# provisioning, enrollment), what's on the box, an environment on it,
# a reboot from the box's page, a Mac going to sleep (macOS), an agent
# self-update, a Flatcar OS update waiting for that reboot
# (E2E_OS_UPDATE=1; it moves the box to the beta channel), destroy, and
# the launcher's stop, start and uninstall.
#
#   e2e/flatcar/run.sh            build, run, tear the box down after
#   e2e/flatcar/run.sh --down     remove the stack, its volumes and the box
#   e2e/flatcar/run.sh --logs     the control plane's logs and the box's console
#
# E2E_PROJECT (default foreman-flatcar) names the compose project, the
# images and the box's launchd label or systemd unit, so a run doesn't
# touch a real box on this machine. KEEP_BOX=1 leaves the box running.
# On Linux it uses sudo for vm.sh; on macOS, run it logged in to the Mac
# (launchd starts the VM in your session).
#
# The commands in single quotes run on the box.
# shellcheck disable=SC2016
set -eu

cd "$(dirname "$0")/../.."
root=$(pwd)
project=${E2E_PROJECT:-foreman-flatcar}
work=tmp/$project
mkdir -p "$work"
touch "$work/env"

case "$(uname -s)" in
  Darwin)
    launcher=mac
    # vmnet's gateway, where a VM reaches the Mac.
    export E2E_GUEST_HOST=192.168.64.1 E2E_BIND=0.0.0.0
    box_home="$root/$work/box-home"
    ;;
  Linux)
    launcher=vm
    # QEMU's user-mode network reaches this machine's loopback here.
    export E2E_GUEST_HOST=10.0.2.2 E2E_BIND=127.0.0.1
    box_dir=/var/lib/$project
    ;;
  *) echo "unsupported: $(uname -s)" >&2; exit 1 ;;
esac
export E2E_CP_IMAGE="$project-cp" E2E_CP_PORT="${E2E_CP_PORT:-4180}" E2E_GIT_PORT="${E2E_GIT_PORT:-4181}"
compose="docker compose -p $project -f e2e/flatcar/compose.yml --env-file $work/env"
cp_url="http://127.0.0.1:$E2E_CP_PORT"

# The launcher's management command, for this run's box.
foreman_box() {
  if [ "$launcher" = mac ]; then
    FOREMAN_BOX_HOME=$box_home FOREMAN_BOX_LABEL=$project "$box_home/bin/foreman-box" "$@"
  else
    sudo FOREMAN_BOX_DIR="$box_dir" FOREMAN_BOX_UNIT="$project" "/usr/local/sbin/$project" "$@"
  fi
}

remove_box() {
  if [ "$launcher" = mac ]; then
    [ ! -x "$box_home/bin/foreman-box" ] || foreman_box uninstall --yes >/dev/null 2>&1 || true
    launchctl bootout "gui/$(id -u)/$project" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$project.plist"
    rm -rf "$box_home"
  else
    [ ! -x "/usr/local/sbin/$project" ] || foreman_box uninstall --yes >/dev/null 2>&1 || true
  fi
}

case "${1:-}" in
  --down)
    remove_box
    $compose down --volumes --remove-orphans
    exit 0
    ;;
  --logs)
    $compose logs --no-color --timestamps
    if [ "$launcher" = mac ]; then cat "$box_home/box/serial.log" 2>/dev/null || true; else sudo cat "$box_dir/serial.log" 2>/dev/null || true; fi
    exit 0
    ;;
esac

say() { printf '\n== %s\n' "$*"; }
fail() {
  printf '\nFAILED: %s\n' "$*" >&2
  echo "the box's console (e2e/flatcar/run.sh --logs for the rest):" >&2
  if [ "$launcher" = mac ]; then tail -n 30 "$box_home/box/serial.log" >&2 2>/dev/null || true; else sudo tail -n 30 "$box_dir/serial.log" >&2 2>/dev/null || true; fi
  exit 1
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

# eval inside the control plane image, without starting a second HTTP server.
cp_eval() {
  out=$($compose exec -T cp env -u PHX_SERVER /app/bin/foreman eval "Code.eval_file(\"/e2e/linux/eval.exs\"); $1" 2>&1) ||
    { echo "$out" >&2; fail "eval failed: $1"; }
  echo "$out" | grep -E '^(ENV|BOX|  OP|queued|set |desired|published|revoked|REBOOT|COOKIE=|BOX_ID=)' || true
}

env_observed() { cp_eval 'E2E.status()' | grep "ENV $1 " | sed 's/.*observed=\([a-z]*\).*/\1/'; }
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

joins() { $compose logs cp | grep -c "agent $1 joined (${2:-}" || true; }
joined_more() { [ "$(joins "$1" "${3:-}")" -gt "$2" ]; }
reboot_field() { cp_eval 'E2E.reboot_status()' | sed -n "s/.*$1=\([^ ]*\).*/\1/p"; }

# On the box, as core.
box() { foreman_box ssh -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR "$@"; }
box_up() { box true; }

# mise if it's there (it pins Elixir for this repo), otherwise the mix on
# PATH, otherwise the agent's build image, which has both.
if command -v mise >/dev/null 2>&1; then
  mix_in_agent() { (cd apps/foreman_agent && mise x -- mix "$@"); }
elif command -v mix >/dev/null 2>&1; then
  mix_in_agent() { (cd apps/foreman_agent && mix "$@"); }
else
  mix_in_agent() {
    docker run --rm -e FOREMAN_RELEASE_PRIVATE_KEY -e MIX_ENV=prod -v "$root:/repo:ro" -w /src/apps/foreman_agent \
      "$project-agent-build" mix "$@"
  }
fi

arch=$(docker version -f '{{.Server.Arch}}')
target=linux-$arch

# Agent $1, built and signed the way release.yml does it.
agent_release() {
  assets=$work/release-$1
  tarball=$assets/foreman_agent-$1-$target.tar.gz
  rm -rf "$assets" && mkdir -p "$assets"
  docker build -q -f docker/box.Dockerfile --target agent-tarball \
    --build-arg "FOREMAN_AGENT_VERSION=$1" --build-arg "FOREMAN_RELEASE_PUBLIC_KEY=$FOREMAN_RELEASE_PUBLIC_KEY" \
    -o "$assets/out" . >/dev/null
  mv "$assets/out/foreman_agent.tar.gz" "$tarball"
  rmdir "$assets/out"
  if command -v mise >/dev/null 2>&1 || command -v mix >/dev/null 2>&1; then
    FOREMAN_RELEASE_PRIVATE_KEY=$FOREMAN_RELEASE_PRIVATE_KEY mix_in_agent foreman_agent.sign "$1" "$target" "$root/$tarball" | tail -1 > "$tarball.sig"
  else
    FOREMAN_RELEASE_PRIVATE_KEY=$FOREMAN_RELEASE_PRIVATE_KEY mix_in_agent foreman_agent.sign "$1" "$target" "/repo/$tarball" | tail -1 > "$tarball.sig"
  fi
}

publish() {
  PATH="$root/e2e/linux/bin:$PATH" E2E_RELEASE_ASSETS="$work/release-$1" FOREMAN_CONTAINER="$($compose ps -q cp)" \
    scripts/publish-agent-release.sh "$1" 2>&1 | grep "published agent $1 for $target" || fail "publish-agent-release.sh $1"
}

say "keys and fixtures"
if ! command -v mise >/dev/null 2>&1 && ! command -v mix >/dev/null 2>&1; then
  docker build -q -f docker/box.Dockerfile --target agent -t "$project-agent-build" . >/dev/null
fi
if [ ! -s "$work/release-keys.env" ]; then
  mix_in_agent foreman_agent.sign --keygen | grep FOREMAN_ > "$work/release-keys.env.new"
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

# SKIP_BUILD=1 reuses everything; SKIP_BUILD=agents rebuilds only the
# control plane image.
if [ "${SKIP_BUILD:-}" != "1" ]; then
  say "build the control plane image"
  docker build -q -f docker/control-plane.Dockerfile -t "$E2E_CP_IMAGE" . >/dev/null
fi
if [ "${SKIP_BUILD:-}" != "1" ] && [ "${SKIP_BUILD:-}" != agents ]; then
  say "build agents 0.1.0 and 0.1.1 ($target)"
  agent_release 0.1.0
  agent_release 0.1.1
fi

say "start the control plane"
remove_box
$compose down --volumes --remove-orphans >/dev/null 2>&1 || true
$compose create --quiet-pull cp git
docker cp e2e/. "$($compose ps -aq cp):/e2e"
# The launchers and the install script as they are in this checkout, so a
# run with SKIP_BUILD=1 still tests them.
for script in apps/foreman/priv/agent/*.sh; do
  docker cp "$script" "$($compose ps -aq cp):/app/lib/foreman-0.1.0/priv/agent/"
done
docker cp "$work/git/." "$($compose ps -aq git):/srv"
$compose up -d cp git
wait_for "control plane listening" 120 curl -fsS "$cp_url/healthz"

say "seed an admin, the fixture repo and a join token; publish agent 0.1.0"
token=$($compose exec -T cp env -u PHX_SERVER E2E_ADMIN=e2e E2E_BOX=flatbox /app/bin/foreman eval 'Code.eval_file("/e2e/seed.exs")' 2>/dev/null |
  sed -n 's/^E2E_JOIN_TOKEN=//p')
[ -n "$token" ] || fail "no join token"
publish 0.1.0

say "the launcher makes the box, which enrolls on its first boot"
start=$(date +%s)
if [ "$launcher" = mac ]; then
  curl -fsSL "$cp_url/agent/mac.sh" |
    FOREMAN_BOX_HOME=$box_home FOREMAN_BOX_LABEL=$project sh -s -- \
      --url "$cp_url" --token "$token" --cpus "${E2E_CPUS:-4}" --memory "${E2E_MEMORY:-8}" --disk 40 |
    tee "$work/launcher.log"
else
  curl -fsSL "$cp_url/agent/vm.sh" |
    sudo FOREMAN_BOX_DIR="$box_dir" FOREMAN_BOX_UNIT="$project" sh -s -- \
      --url "$cp_url" --token "$token" --cpus "${E2E_CPUS:-4}" --memory "${E2E_MEMORY:-8}" --disk 40 --ssh-port 2299 |
    tee "$work/launcher.log"
fi
grep -q "foreman-box: done" "$work/launcher.log" || fail "the launcher didn't finish"
echo "ok: enrolled $(($(date +%s) - start))s after the launcher started"
wait_for "agent joined" 60 joined_more flatbox 0 0.1.0

say "the box"
wait_for "ssh to the box" 60 box_up
[ "$(box '. /etc/os-release && echo "$ID"')" = flatcar ] || fail "not Flatcar"
box 'docker compose version' | grep -q 'v5\.' || fail "Compose isn't the extension's"
box 'tailscale version' >/dev/null || fail "no tailscale"
for unit in docker tailscaled foreman-agent foreman-firewall foreman-restart.path foreman-flatcar-update.timer systemd-sysupdate.timer; do
  [ "$(box "systemctl is-active $unit")" = active ] || fail "$unit isn't active"
done
box 'sudo nft list table inet foreman' | grep -q 'fm-\*' || fail "the box's firewall isn't loaded"
box 'grep -qx REBOOT_STRATEGY=off /etc/flatcar/update.conf' || fail "Flatcar's reboot manager is on"
box 'test ! -e /etc/foreman-box/provision.env && test ! -e /etc/foreman-box/tailscale-authkey' ||
  fail "the join token was left on the box"
box '! command -v node' >/dev/null || fail "the box has a Node of its own"
box 'ls /opt/foreman-agent/current/lib/foreman_agent-*/priv/tools/bin/devcontainer' >/dev/null ||
  fail "the agent release has no devcontainer CLI"
[ "$(reboot_field can_restart)" = true ] || fail "the agent says it can't reboot the box"
boot1=$(reboot_field boot)
[ -n "$boot1" ] || fail "no boot id reported"
echo "ok: Flatcar with Compose $(box 'docker compose version --short'), Tailscale $(box 'tailscale version | head -1'), the firewall, the restart unit and no Node"

say "an environment on the box"
# The fixture repo's host, which the agent refuses by default.
box "sudo mkdir -p /etc/systemd/system/foreman-agent.service.d && printf '[Service]\nEnvironment=FOREMAN_ALLOWED_GIT_HOSTS=$E2E_GUEST_HOST FOREMAN_INSECURE_GIT_HOSTS=$E2E_GUEST_HOST\n' | sudo tee /etc/systemd/system/foreman-agent.service.d/e2e.conf >/dev/null && sudo systemctl daemon-reload && sudo systemctl restart foreman-agent"
n=$(joins flatbox)
wait_for "agent rejoined" 60 joined_more flatbox "$n"
start=$(date +%s)
cp_eval 'E2E.create()'
wait_for_env hello-1 running 1200
echo "ok: created in $(($(date +%s) - start))s"
app=$(box 'docker ps -q --filter label=foreman.env_id --filter label=com.docker.compose.service=app')
[ -n "$app" ] || fail "no app container"
[ "$(box "docker exec $app id -u vscode")" = "$(box 'id -u foreman')" ] || fail "the container user isn't the agent's uid"
box "docker exec -u root $app sh -c 'touch /run/foreman/x'" 2>/dev/null && fail "the secrets mount is writable"
cp_eval 'E2E.secret("hello-1", "SIDECAR_TOKEN", "flatcar-secret-1")'
i=0
until box "docker exec -u vscode $app bash -lc 'echo \$SIDECAR_TOKEN'" 2>/dev/null | grep -q flatcar-secret-1; do
  i=$((i + 5)); [ $i -lt 120 ] || fail "the secret didn't reach a login shell"; sleep 5
done
echo "ok: the environment runs, as the agent's uid, with read-only secrets that reach new shells"

say "reboot the box from its page"
cookie=$(cp_eval 'E2E.session_cookie()' | sed -n 's/^COOKIE=//p')
box_id=$(cp_eval 'E2E.box_id()' | sed -n 's/^BOX_ID=//p')
n=$(joins flatbox)
node e2e/lv-click.mjs "$cp_url" "$cookie" "/boxes/$box_id" run '{"type":"box.restart"}' | grep -q "Rebooting flatbox" ||
  fail "the Reboot button didn't send the reboot"
wait_for "agent rejoined after the reboot" 300 joined_more flatbox "$n"
boot2=$(reboot_field boot)
[ -n "$boot2" ] && [ "$boot2" != "$boot1" ] || fail "the box is on the same boot ($boot1)"
wait_for_env hello-1 running 600
box "docker exec -u vscode \$(docker ps -q --filter label=foreman.env_id --filter label=com.docker.compose.service=app) bash -lc 'echo \$SIDECAR_TOKEN'" |
  grep -q flatcar-secret-1 || fail "secrets not back after the reboot"
echo "ok: rebooted, rejoined on a new boot, environment and secrets back"

if [ "$launcher" = mac ]; then
  say "the Mac sleeps: the VM stops for 90 seconds"
  rest() { curl -fsS --unix-socket "$box_home/box/rest.sock" "$@"; }
  n=$(joins flatbox)
  rest -X POST -d '{"state":"Pause"}' http://localhost/vm/state >/dev/null
  sleep 90
  rest -X POST -d '{"state":"Resume"}' http://localhost/vm/state >/dev/null
  # The connection may have outlived the pause; a restart of the agent
  # then shows a fresh join with the box's clock put right.
  i=0
  until box 'journalctl -u foreman-clock --no-pager | grep -q "clock was"' 2>/dev/null; do
    i=$((i + 5)); [ $i -lt 60 ] || fail "the box's clock wasn't put right"; sleep 5
  done
  echo "ok: $(box 'journalctl -u foreman-clock --no-pager -o cat | grep "clock was" | tail -1')"
  box 'sudo systemctl restart foreman-agent'
  wait_for "agent joined after the sleep" 120 joined_more flatbox "$n"
  echo "ok: the box's clock was put right and the agent joined"
fi

say "self-update to 0.1.1"
cp_eval 'E2E.desire_version("0.1.0")'
publish 0.1.1
cp_eval 'E2E.desire_version("0.1.1")'
box 'sudo systemctl restart foreman-agent'
wait_for "agent on 0.1.1" 300 joined_more flatbox 0 0.1.1
wait_for_env hello-1 running 120
echo "ok: self-updated on Flatcar, environment still running"

if [ "${E2E_OS_UPDATE:-}" = 1 ]; then
  say "a Flatcar update waits for a reboot from the box's page"
  os1=$(box '. /etc/os-release && echo $VERSION_ID')
  box 'echo GROUP=beta | sudo tee -a /etc/flatcar/update.conf >/dev/null && sudo systemctl restart update-engine && sleep 3 && sudo update_engine_client -check_for_update' >/dev/null 2>&1 || true
  i=0
  until [ "$(reboot_field required)" = true ]; do
    i=$((i + 15)); [ $i -lt 1500 ] || fail "the update was never flagged"; sleep 15
  done
  packages=$(reboot_field packages)
  echo "$packages" | grep -q '^flatcar-\|,flatcar-' || fail "flagged without the Flatcar version: $packages"
  echo "ok: flagged as a reboot the box needs ($packages); the box stays up"
  n=$(joins flatbox)
  node e2e/lv-click.mjs "$cp_url" "$cookie" "/boxes/$box_id" run '{"type":"box.restart"}' >/dev/null
  wait_for "agent rejoined after the update" 600 joined_more flatbox "$n"
  os2=$(box '. /etc/os-release && echo $VERSION_ID')
  [ "$os2" != "$os1" ] || fail "still on Flatcar $os1"
  [ "$(reboot_field required)" = false ] || fail "the reboot flag outlived the reboot"
  wait_for_env hello-1 running 600
  echo "ok: Flatcar $os1 to $os2, the flag cleared, the environment back"
fi

say "destroy"
cp_eval 'E2E.act("hello-1", "destroy")'
wait_for_env hello-1 destroyed 300
[ -z "$(box 'docker ps -aq --filter label=foreman.env_id')" ] || fail "containers left behind"
echo "ok: nothing left on the box"

say "the launcher: stop, start, status"
foreman_box stop
foreman_box status | grep -q 'box: *flatbox' || fail "status doesn't name the box"
n=$(joins flatbox)
foreman_box start
wait_for "agent rejoined after a start" 300 joined_more flatbox "$n"
echo "ok: stopped and started"

if [ "${KEEP_BOX:-}" = 1 ]; then
  say "PASSED (the box is still running: e2e/flatcar/run.sh --down removes it)"
  exit 0
fi

say "uninstall"
foreman_box uninstall --yes
if [ "$launcher" = mac ]; then
  [ ! -e "$box_home" ] || fail "the box's files are still there"
  launchctl print "gui/$(id -u)/$project" >/dev/null 2>&1 && fail "launchd still has the box"
else
  [ ! -e "$box_dir" ] || fail "the box's files are still there"
  systemctl cat "$project" >/dev/null 2>&1 && fail "systemd still has the box"
fi
echo "ok: removed"

say "PASSED"
