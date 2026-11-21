#!/bin/sh
# End-to-end run of a Flatcar box: the control plane release image, and a
# box made by vm.sh (QEMU with KVM) on this Linux machine, booted for
# real. Covers the launcher, the box's first boot (Ignition, the
# extensions, provisioning, enrollment), what's on the box (the VM helper
# and firewall included), the box reporting it can run environment VMs
# (nested), a reboot from the box's page, an agent self-update, a Flatcar
# OS update waiting for that reboot (E2E_OS_UPDATE=1; it moves the box to
# the beta channel), and the launcher's stop, start and uninstall.
# Environments themselves run in e2e/vm/run.sh. Mac boxes aren't supported
# until environment VMs run on Apple's hypervisor (ntodd/foreman#180).
#
#   e2e/flatcar/run.sh            build, run, tear the box down after
#   e2e/flatcar/run.sh --down     remove the stack, its volumes and the box
#   e2e/flatcar/run.sh --logs     the control plane's logs and the box's console
#
# With FOREMAN_TAILSCALE_CLIENT_ID and FOREMAN_TAILSCALE_CLIENT_SECRET (an
# OAuth client that can make keys tagged tag:foreman-box), the control
# plane mints the box a key and the run checks the box joined the
# tailnet, and logs it out at the end; the box still reaches the control
# plane through this machine.
#
# E2E_PROJECT (default foreman-flatcar) names the compose project, the
# images and the box's systemd unit, so a run doesn't touch a real box on
# this machine. KEEP_BOX=1 leaves the box running. It uses sudo for vm.sh.
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

[ "$(uname -s)" = Linux ] || {
  echo "e2e/flatcar/run.sh needs Linux with KVM (Mac boxes come back with ntodd/foreman#180)" >&2
  exit 1
}
# QEMU's user-mode network reaches this machine's loopback here.
export E2E_GUEST_HOST=10.0.2.2 E2E_BIND=127.0.0.1
box_dir=/var/lib/$project
export E2E_CP_IMAGE="$project-cp" E2E_CP_PORT="${E2E_CP_PORT:-4180}" E2E_GIT_PORT="${E2E_GIT_PORT:-4181}"
compose="docker compose -p $project -f e2e/flatcar/compose.yml --env-file $work/env"
cp_url="http://127.0.0.1:$E2E_CP_PORT"

# The launcher's management command, for this run's box.
foreman_box() {
  sudo FOREMAN_BOX_DIR="$box_dir" FOREMAN_BOX_UNIT="$project" "/usr/local/sbin/$project" "$@"
}

remove_box() {
  [ ! -x "/usr/local/sbin/$project" ] || foreman_box uninstall --yes >/dev/null 2>&1 || true
}

case "${1:-}" in
  --down)
    remove_box
    $compose down --volumes --remove-orphans
    exit 0
    ;;
  --logs)
    $compose logs --no-color --timestamps
    sudo cat "$box_dir/serial.log" 2>/dev/null || true
    exit 0
    ;;
esac

say() { printf '\n== %s\n' "$*"; }
fail() {
  printf '\nFAILED: %s\n' "$*" >&2
  echo "the box's console (e2e/flatcar/run.sh --logs for the rest):" >&2
  sudo tail -n 30 "$box_dir/serial.log" >&2 2>/dev/null || true
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
  echo "$out" | grep -E '^(ENV|BOX|  OP|queued|set |desired|published|revoked|REBOOT|COOKIE=|BOX_ID=|VM)' || true
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

say "a bad token fails before anything is installed, and leaves nothing behind"
# The log is ours, not root's.
# shellcheck disable=SC2024
curl -fsSL "$cp_url/agent/vm.sh" |
  sudo FOREMAN_BOX_DIR="$box_dir-bad" FOREMAN_BOX_UNIT="$project-bad" sh -s -- --url "$cp_url" --token fj_not_a_token \
  > "$work/bad.log" 2>&1 && fail "the launcher took a bad token"
[ ! -e "$box_dir-bad" ] || fail "a failed launcher left $box_dir-bad"
[ ! -e "/etc/systemd/system/$project-bad.service" ] || fail "a failed launcher left its unit"
[ ! -e "/usr/local/sbin/$project-bad" ] || fail "a failed launcher left its command"
grep -q "Foreman said 401" "$work/bad.log" || { cat "$work/bad.log" >&2; fail "the launcher didn't say why"; }
echo "ok: refused with Foreman's answer, nothing left"

say "the launcher makes the box, which enrolls on its first boot"
start=$(date +%s)
curl -fsSL "$cp_url/agent/vm.sh" |
  sudo FOREMAN_BOX_DIR="$box_dir" FOREMAN_BOX_UNIT="$project" sh -s -- \
    --url "$cp_url" --token "$token" --cpus "${E2E_CPUS:-4}" --memory "${E2E_MEMORY:-8}" --disk 40 --ssh-port 2299 |
  tee "$work/launcher.log"
grep -q "foreman-box: done" "$work/launcher.log" || fail "the launcher didn't finish"
echo "ok: enrolled $(($(date +%s) - start))s after the launcher started"
wait_for "agent joined" 60 joined_more flatbox 0 0.1.0

say "the box"
wait_for "ssh to the box" 60 box_up
[ "$(box '. /etc/os-release && echo "$ID"')" = flatcar ] || fail "not Flatcar"
box 'docker compose version' | grep -q 'v5\.' || fail "Compose isn't the extension's"
box 'tailscale version' >/dev/null || fail "no tailscale"
for unit in docker tailscaled foreman-agent foreman-firewall foreman-restart.path foreman-vmctl.socket foreman-flatcar-update.timer systemd-sysupdate.timer; do
  [ "$(box "systemctl is-active $unit")" = active ] || fail "$unit isn't active"
done
box 'sudo nft list table inet foreman' | grep -q 'fm-\*' || fail "the box's firewall isn't loaded"
box 'sudo nft list table inet foreman_guests' >/dev/null || fail "the firewall's table for environment VMs isn't loaded"
[ "$(box 'stat -c %U /etc/foreman-agent/vmctl')" = root ] || fail "the VM helper isn't root's"
# The firewall's reload timer ticks every 15 seconds; let it, then nothing
# on the box may have failed.
sleep 20
[ "$(box 'systemctl show -p Result --value foreman-firewall-check.service')" = success ] ||
  fail "the firewall's reload check fails"
failed=$(box 'systemctl list-units --failed --no-legend --plain')
[ -z "$failed" ] || fail "failed units on the box: $failed"
box 'grep -qx REBOOT_STRATEGY=off /etc/flatcar/update.conf' || fail "Flatcar's reboot manager is on"
box 'test ! -e /etc/foreman-box/provision.env && test ! -e /etc/foreman-box/tailscale-authkey' ||
  fail "the join token was left on the box"
box '! command -v node' >/dev/null || fail "the box has a Node of its own"
box '! ls -d /opt/foreman-agent/current/lib/foreman_agent-*/priv/tools/node 2>/dev/null' >/dev/null ||
  fail "the agent release carries a Node"
if [ -n "${FOREMAN_TAILSCALE_CLIENT_ID:-}" ]; then
  box 'tailscale status --json' | grep -q '"BackendState": *"Running"' || fail "the box isn't on the tailnet"
  echo "ok: on the tailnet as $(box 'tailscale status --json' | sed -n 's/.*"DNSName": *"\([^"]*\)".*/\1/p' | head -1)"
fi
[ "$(reboot_field can_restart)" = true ] || fail "the agent says it can't reboot the box"
boot1=$(reboot_field boot)
[ -n "$boot1" ] || fail "no boot id reported"
echo "ok: Flatcar with Compose $(box 'docker compose version --short'), Tailscale $(box 'tailscale version | head -1'), the firewall, the restart unit and no Node"

say "the box can run environment VMs, nested"
vm_ready() { cp_eval 'E2E.vm_status()' | grep -q '^VM ready=true nested=true'; }
wait_for "the box's VM report" 60 vm_ready
echo "ok: $(cp_eval 'E2E.vm_status()')"

say "reboot the box from its page"
cookie=$(cp_eval 'E2E.session_cookie()' | sed -n 's/^COOKIE=//p')
box_id=$(cp_eval 'E2E.box_id()' | sed -n 's/^BOX_ID=//p')
n=$(joins flatbox)
node e2e/lv-click.mjs "$cp_url" "$cookie" "/boxes/$box_id" run '{"type":"box.restart"}' | grep -q "Rebooting flatbox" ||
  fail "the Reboot button didn't send the reboot"
wait_for "agent rejoined after the reboot" 300 joined_more flatbox "$n"
boot2=$(reboot_field boot)
if [ -z "$boot2" ] || [ "$boot2" = "$boot1" ]; then fail "the box is on the same boot ($boot1)"; fi
wait_for "the box's VM report after the reboot" 60 vm_ready
echo "ok: rebooted, rejoined on a new boot, VMs still runnable"

say "the VM's process dies, and systemd brings the box back"
n=$(joins flatbox)
qemu_pid=$(systemctl show -p MainPID --value "$project")
[ "${qemu_pid:-0}" -gt 0 ] || fail "no QEMU to kill"
sudo kill -9 "$qemu_pid"
wait_for "agent rejoined after the VM died" 300 joined_more flatbox "$n"
echo "ok: the box came back on its own"

say "running the launcher again updates it and keeps the box"
n=$(joins flatbox)
curl -fsSL "$cp_url/agent/vm.sh" | sudo FOREMAN_BOX_DIR="$box_dir" FOREMAN_BOX_UNIT="$project" sh -s -- --url "$cp_url" |
  tee "$work/update.log"
grep -q "the box keeps its disk and enrollment" "$work/update.log" || fail "the launcher didn't update in place"
sleep 10
[ "$(joins flatbox)" = "$n" ] || fail "updating the launcher restarted the box"
box true || fail "the box isn't up after the update"
echo "ok: updated in place, the box untouched"

say "self-update to 0.1.1"
cp_eval 'E2E.desire_version("0.1.0")'
publish 0.1.1
cp_eval 'E2E.desire_version("0.1.1")'
box 'sudo systemctl restart foreman-agent'
wait_for "agent on 0.1.1" 300 joined_more flatbox 0 0.1.1
echo "ok: self-updated on Flatcar"

if [ "${E2E_OS_UPDATE:-}" = 1 ]; then
  say "a Flatcar update waits for a reboot from the box's page"
  os1=$(box '. /etc/os-release && echo $VERSION_ID')
  box 'echo GROUP=beta | sudo tee -a /etc/flatcar/update.conf >/dev/null && sudo systemctl restart update-engine && sleep 3 && sudo update_engine_client -check_for_update' >/dev/null 2>&1 || true
  # update-engine creates the flag itself; the check timer (every minute)
  # adds what asked for it.
  i=0
  until reboot_field packages | grep -q 'flatcar-'; do
    i=$((i + 15)); [ $i -lt 1500 ] || fail "the update was never flagged ($(reboot_field required), $(reboot_field packages))"; sleep 15
  done
  [ "$(reboot_field required)" = true ] || fail "the update's package came without the flag"
  packages=$(reboot_field packages)
  echo "ok: flagged as a reboot the box needs ($packages); the box stays up"
  n=$(joins flatbox)
  node e2e/lv-click.mjs "$cp_url" "$cookie" "/boxes/$box_id" run '{"type":"box.restart"}' >/dev/null
  wait_for "agent rejoined after the update" 600 joined_more flatbox "$n"
  os2=$(box '. /etc/os-release && echo $VERSION_ID')
  [ "$os2" != "$os1" ] || fail "still on Flatcar $os1"
  [ "$(reboot_field required)" = false ] || fail "the reboot flag outlived the reboot"
  echo "ok: Flatcar $os1 to $os2, the flag cleared"
fi

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
[ -z "${FOREMAN_TAILSCALE_CLIENT_ID:-}" ] || box 'sudo tailscale logout' || true
foreman_box uninstall --yes
[ ! -e "$box_dir" ] || fail "the box's files are still there"
systemctl cat "$project" >/dev/null 2>&1 && fail "systemd still has the box"
echo "ok: removed"

say "PASSED"
