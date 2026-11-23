#!/bin/sh
# End-to-end run of environment VMs on a real Linux host: the control
# plane release image in Docker, the agent installed on this machine with
# the served install script, and environments in Cloud Hypervisor VMs.
# Covers enrollment and the box's VM report, a VM's unit and sandbox
# (Landlock included, across a suspend), what an environment can reach
# (the box, another environment, the box's LAN, the internet), secrets
# across a stop and start, an agent restart that leaves VMs running,
# destroy, and a box whose kernel has no Landlock.
#
#   E2E_VM_THROWAWAY=1 e2e/vm/run.sh [all|lifecycle|expiry]
#
# It installs the agent on this machine and changes its network (taps,
# nftables, iptables, a network namespace), so it only runs on a machine
# you're about to throw away: CI's GitHub-hosted runner, or a VM made for
# it. Needs KVM, Docker, sudo, git, python3, openssl, zstd, and Elixir for
# mix foreman_agent.sign (through mise if it's installed).
#
# E2E_AGENT_TARBALL, E2E_GUEST_TAR and E2E_CP_IMAGE use what's already
# built instead of building it; E2E_AGENT_SIG, a signature made with the
# keys in tmp/e2e-vm/release-keys.env, instead of signing it here.
#
# The commands in single quotes run in the control plane.
# shellcheck disable=SC2016
set -eu

scenario=${1-all}
case "$#:$scenario" in
  0:all|1:all|1:lifecycle|1:expiry) ;;
  *) echo "Usage: e2e/vm/run.sh [all|lifecycle|expiry]" >&2; exit 64 ;;
esac

[ "${E2E_VM_THROWAWAY:-}" = 1 ] || {
  echo "e2e/vm/run.sh changes this machine; set E2E_VM_THROWAWAY=1 on one you'll throw away" >&2
  exit 64
}

cd "$(dirname "$0")/../.."
root=$(pwd)
work=$root/tmp/e2e-vm
mkdir -p "$work"
version=0.1.0
cp_name=foreman-e2e-vm-cp
port=4100
url=http://127.0.0.1:$port
lan=192.168.77.2

say() { printf '\n== %s\n' "$*"; }
fail() {
  printf '\nFAILED: %s\n' "$*" >&2
  logs
  exit 1
}

logs() {
  echo "== control plane" >&2
  docker logs --tail 60 "$cp_name" >&2 2>&1 || true
  echo "== agent" >&2
  sudo journalctl --no-pager -n 120 -u foreman-agent >&2 || true
  sudo journalctl --no-pager -n 40 -u 'foreman-vm-*.service' >&2 || true
  # The VMs' directories are the agent's alone.
  sudo sh -c 'for log in /srv/foreman/vms/*/serial.log /srv/foreman/vms/*/ch.log; do
    [ -e "$log" ] || continue
    echo "== $log"
    tail -n 60 "$log"
  done' >&2 || true
}

wait_for() { # description, seconds, command...
  desc=$1 timeout=$2
  shift 2
  i=0
  until "$@" >/dev/null 2>&1; do
    i=$((i + 2))
    [ $i -lt "$timeout" ] || fail "timed out waiting for: $desc"
    sleep 2
  done
  echo "ok: $desc"
}

if command -v mise >/dev/null 2>&1; then mix="mise x -- mix"; else mix=mix; fi

# A click on a page of the running control plane (see e2e/lv-click.mjs),
# for what needs the box's connection, which an eval doesn't have.
lv_click() { # path, event, value-json
  if command -v node >/dev/null && node -e 'process.exit(typeof WebSocket === "function" ? 0 : 1)'; then
    node "$root/e2e/lv-click.mjs" "$url" "$cookie" "$@"
    return
  fi
  docker run --rm --network host -v "$root/e2e:/e2e:ro" public.ecr.aws/docker/library/node:22-alpine \
    node /e2e/lv-click.mjs "$url" "$cookie" "$@"
}
cp_eval() {
  docker exec "$cp_name" env -u PHX_SERVER /app/bin/foreman eval "Code.eval_file(\"/e2e/linux/eval.exs\"); $1" 2>&1
}

env_observed() { cp_eval 'E2E.status()' | grep "^ENV $1 " | sed 's/.*observed=\([a-z]*\).*/\1/'; }
# A registry that limits this machine's pulls (CI runners share addresses)
# fails a create or start; it's tried again, as a user would, twice at most.
rate_limited() { cp_eval "E2E.log(\"$1\")" | grep -qiE "toomanyrequests|too many requests|rate exceeded"; }
wait_for_env() { # slug, state, seconds
  i=0 retries=0 retry_operation=
  until [ "$(env_observed "$1")" = "$2" ]; do
    if [ "$(env_observed "$1")" = error ]; then
      if [ "$retries" -lt 2 ] && rate_limited "$1"; then
        retries=$((retries + 1))
        echo "a registry limited pulls; trying $1 again ($retries)" >&2
        sleep 30
        retry_operation=$(cp_eval "E2E.retry_failed(\"$1\")" | sed -n 's/^RETRY=//p')
        [ -n "$retry_operation" ] || fail "no operation returned by the registry retry for $1"
        j=0
        while [ "$(env_observed "$1")" = error ] && [ $j -lt 300 ]; do sleep 5; j=$((j + 5)); done
        continue
      fi
      cp_eval 'E2E.status()' >&2
      cp_eval "E2E.log(\"$1\")" | tail -60 >&2
      fail "$1 errored waiting for $2"
    fi
    i=$((i + 2))
    [ $i -lt "$3" ] || { cp_eval "E2E.log(\"$1\")" | tail -60 >&2; fail "timed out waiting for $1 $2"; }
    sleep 2
  done
  echo "ok: $1 $2"
}

# -- build -------------------------------------------------------------------
target=linux-amd64
assets=$work/release-$version
mkdir -p "$assets"
tarball=$assets/foreman_agent-$version-$target.tar.gz

if [ -z "${E2E_GUEST_TAR:-}" ]; then
  say "build the guest image"
  guest/build.sh "$work/guest" >/dev/null
  E2E_GUEST_TAR=$work/guest/foreman-guest-linux-amd64.tar
fi
guest_sha=$(sha256sum "$E2E_GUEST_TAR" | cut -d' ' -f1)

say "release keys"
if [ ! -s "$work/release-keys.env" ]; then
  (cd apps/foreman_agent && $mix foreman_agent.sign --keygen | grep FOREMAN_) > "$work/release-keys.env.new"
  mv "$work/release-keys.env.new" "$work/release-keys.env"
fi
# shellcheck source=/dev/null
. "$work/release-keys.env"

# The control plane image builds while the agent does: neither needs the
# other, and each takes about a minute.
cp_build=""
if [ -z "${E2E_CP_IMAGE:-}" ]; then
  say "build the control plane image, while the agent builds"
  E2E_CP_IMAGE=foreman-e2e-vm-cp
  docker build -q -f docker/control-plane.Dockerfile -t "$E2E_CP_IMAGE" . >/dev/null &
  cp_build=$!
fi

if [ -n "${E2E_AGENT_TARBALL:-}" ]; then
  cp "$E2E_AGENT_TARBALL" "$tarball"
else
  say "build agent $version"
  docker build -q -f docker/box.Dockerfile --target agent-tarball \
    --build-arg "FOREMAN_AGENT_VERSION=$version" \
    --build-arg "FOREMAN_RELEASE_PUBLIC_KEY=$FOREMAN_RELEASE_PUBLIC_KEY" \
    -o "$work/agent" . >/dev/null
  cp "$work/agent/foreman_agent.tar.gz" "$tarball"
fi
if [ -n "${E2E_AGENT_SIG:-}" ]; then
  cp "$E2E_AGENT_SIG" "$tarball.sig"
else
  (cd apps/foreman_agent && FOREMAN_RELEASE_PRIVATE_KEY=$FOREMAN_RELEASE_PRIVATE_KEY $mix foreman_agent.sign "$version" "$target" "$tarball" | tail -1) > "$tarball.sig"
fi

if [ -n "$cp_build" ]; then
  wait "$cp_build" || { echo "FAILED: the control plane image didn't build" >&2; exit 1; }
  echo "ok: the control plane image is built"
fi

# What an earlier run on this machine left: its agent (which would start
# its VMs again), its VMs and their taps.
sudo systemctl stop foreman-agent 2>/dev/null || true
for unit in $(systemctl list-units --plain --no-legend 'foreman-vm-*' | awk '{ print $1 }'); do
  sudo systemctl stop "$unit"
done
# The agent disk is made once per version (a release doesn't change), and
# every run here builds 0.1.0 afresh.
sudo rm -rf /srv/foreman/vms /srv/foreman/agent-disks /srv/foreman/prebuilds /var/lib/foreman-vmctl/nets
for tap in $(ip -br link | awk '/^fm-vm/ { print $1 }'); do sudo ip link del "$tap"; done

# -- the box's LAN, with the fixture repo on it -------------------------------
say "a git server on the box's LAN"
# The probe each environment runs when it starts (its postStartCommand),
# printed into the operation's log: what it can reach. Exit status 0 is
# connected, 1 refused (reachable), 124 timed out (dropped).
box_ip=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
# Every cold VM needs the same privileged sidecar. Stage it once on the
# fixture LAN so concurrent guests cannot exhaust a public registry quota.
dind_source=
for registry in public.ecr.aws/docker/library mirror.gcr.io/library docker.io/library; do
  if docker pull "$registry/docker:29-dind"; then
    dind_source=$registry/docker:29-dind
    break
  fi
done
[ -n "$dind_source" ] || fail "couldn't stage the Docker-in-Docker fixture"
rm -rf "$work/git"
mkdir -p "$work/git"
docker save -o "$work/git/dind.tar" "$dind_source"
gzip -1 "$work/git/dind.tar"
# The host and guest can report different IDs for the same image. Key the
# guest's local tag by the archive it actually verified and loaded.
dind_sha=$(sha256sum "$work/git/dind.tar.gz")
dind_sha=${dind_sha%% *}
dind_ref=foreman-e2e-dind:$dind_sha
mkdir -p "$work/overlay/.devcontainer"
cat > "$work/overlay/.devcontainer/load-dind.sh" <<EOF
set -e -o pipefail
if docker image inspect "$dind_ref" >/dev/null 2>&1; then exit 0; fi
archive=\$(mktemp)
trap 'rm -f "\$archive"' EXIT
curl -fsS "http://$lan:8080/dind.tar.gz" -o "\$archive"
printf '%s  %s\n' "$dind_sha" "\$archive" | sha256sum -c -
docker load -i "\$archive"
docker tag "$dind_source" "$dind_ref"
EOF
cat > "$work/overlay/.devcontainer/devcontainer.json" <<EOF
{
  "name": "hello",
  "dockerComposeFile": ["docker-compose.yml"],
  "service": "app",
  "initializeCommand": ["bash", ".devcontainer/load-dind.sh"],
  "workspaceFolder": "/workspaces/\${localWorkspaceFolderBasename}",
  "remoteUser": "vscode",
  "postStartCommand": "bash .devcontainer/probe.sh"
}
EOF
# Docker-in-docker, which needs a privileged container: the environment's
# VM is the boundary now, not a policy on its compose file.
# Real devcontainers can have messagebus or systemd-network at UID 997.
# Give the fixture that collision so a regression fails the write and
# private-secret probes below.
sed '/^  app:$/,/^  sidecar:$/s|^    image: .*|    build: .|' \
  apps/foreman_agent/test/fixtures/repos/hello/.devcontainer/docker-compose.yml \
  > "$work/overlay/.devcontainer/docker-compose.yml"
cat > "$work/overlay/.devcontainer/Dockerfile" <<'EOF'
FROM mcr.microsoft.com/devcontainers/base:debian
USER root
RUN getent passwd 997 >/dev/null || useradd --system --uid 997 --no-create-home fixture-service
EOF
cat >> "$work/overlay/.devcontainer/docker-compose.yml" <<EOF
  # The guest's boot and clock, every second: a resume keeps the
  # containers running, so nothing in the lifecycle runs again to say.
  heartbeat:
    image: mcr.microsoft.com/devcontainers/base:debian
    command: ["sh", "-c", "while :; do echo \"PROBE beat \$\$(cat /proc/sys/kernel/random/boot_id) \$\$(date +%s)\"; sleep 1; done"]
    stop_grace_period: 1s
  dind:
    image: $dind_ref
    pull_policy: never
    privileged: true
    environment:
      DOCKER_TLS_CERTDIR: ""
EOF
cat > "$work/overlay/.devcontainer/probe.sh" <<EOF
#!/bin/bash
try() { timeout 4 bash -c "exec 3<>/dev/tcp/\$2/\$3" 2>/dev/null; echo "PROBE \$1 \$?"; }
echo "PROBE user \$(id -un)"
# The agent brings the devcontainer up itself (its own implementation of
# the devcontainer CLI's \`up\`) and gives the container's user its uid, so
# the 0600 secrets and the clone are the user's own.
[ "\$(stat -c %u /run/foreman/secrets.env)" = "\$(id -u)" ] && echo "PROBE secrets-owner self" || echo "PROBE secrets-owner other"
marker=".workspace-marker-\${FOREMAN_ENV:?}"
[ -s "\$marker" ] || cat /proc/sys/kernel/random/uuid > "\$marker"
echo "PROBE workspace-marker \$(cat "\$marker")"
touch .probe-write 2>/dev/null; echo "PROBE workspace-writable \$?"
secret=\$(. /run/foreman/secrets.env 2>/dev/null; printf %s "\${SIDECAR_TOKEN:-none}" | sha256sum | cut -c1-16)
echo "PROBE secret \$secret"
(
  . /run/foreman/secrets.env
  if [ -n "\${API_TEST_APPROVED:-}" ]; then echo 'PROBE approved-secret present'; else echo 'PROBE approved-secret absent'; fi
  if [ -n "\${API_TEST_UNAPPROVED:-}" ]; then echo 'PROBE unapproved-secret present'; else echo 'PROBE unapproved-secret absent'; fi
)
try gateway 10.250.0.1 1
try box $box_ip 1
try first-guest 10.250.0.2 1
try internet 1.1.1.1 443
try lan $lan 8080
# The docker-in-docker sidecar's daemon, once it's up.
for _ in \$(seq 30); do timeout 2 bash -c "exec 3<>/dev/tcp/dind/2375" 2>/dev/null && break; sleep 1; done
try dind dind 2375
EOF
e2e/make-git-fixture.sh "$work/git" hello "$work/overlay" >/dev/null

sudo ip netns del e2e-lan 2>/dev/null || true
sudo ip link del e2e-lan0 2>/dev/null || true
sudo ip netns add e2e-lan
sudo ip link add e2e-lan0 type veth peer name lan0 netns e2e-lan
sudo ip addr add 192.168.77.1/24 dev e2e-lan0
sudo ip link set e2e-lan0 up
sudo ip netns exec e2e-lan ip link set lo up
sudo ip netns exec e2e-lan ip addr add "$lan/24" dev lan0
sudo ip netns exec e2e-lan ip link set lan0 up
sudo ip netns exec e2e-lan ip route add default via 192.168.77.1
(cd "$work/git" && sudo ip netns exec e2e-lan python3 -m http.server 8080 --bind "$lan" >/dev/null 2>&1 &)

# -- the control plane ---------------------------------------------------------
say "start the control plane"
docker rm -f "$cp_name" >/dev/null 2>&1 || true
docker volume rm -f foreman-e2e-vm-data >/dev/null 2>&1 || true
docker create --name "$cp_name" --network host \
  -e FOREMAN_ADMINS=e2e -e SECRET_KEY_BASE="$(openssl rand -base64 48 | tr -d '\n')" \
  -e FOREMAN_ENCRYPTION_KEY="$(openssl rand -base64 32)" \
  -e FOREMAN_AGENT_RELEASE_PUBLIC_KEY="$FOREMAN_RELEASE_PUBLIC_KEY" \
  -e PHX_HOST=127.0.0.1 -e PORT="$port" -e FOREMAN_LISTEN_IP=127.0.0.1 \
  -e FOREMAN_BASE_URL="$url" -e FOREMAN_FORCE_SSL=false -e FOREMAN_SECURE_COOKIES=false \
  -e FOREMAN_EXTRA_ORIGINS="$url" \
  -e FOREMAN_GIT_BASE_URL="http://$lan:8080" \
  -v foreman-e2e-vm-data:/var/lib/foreman "$E2E_CP_IMAGE" >/dev/null
docker cp e2e/. "$cp_name:/e2e"
docker start "$cp_name" >/dev/null
wait_for "control plane listening" 120 curl -fsS "$url/healthz"

token=$(docker exec "$cp_name" env -u PHX_SERVER E2E_ADMIN=e2e E2E_BOX=vmbox /app/bin/foreman eval 'Code.eval_file("/e2e/seed.exs")' 2>/dev/null |
  sed -n 's/^E2E_JOIN_TOKEN=//p')
[ -n "$token" ] || fail "no join token"
PATH="$root/e2e/linux/bin:$PATH" E2E_RELEASE_ASSETS="$assets" FOREMAN_CONTAINER="$cp_name" \
  scripts/publish-agent-release.sh "$version" | grep -q "published agent $version for $target" ||
  fail "publish-agent-release.sh"

# -- the box -------------------------------------------------------------------
say "install the agent with the served install script"
# Not /tmp or /var/tmp: the agent's unit has private ones.
sudo install -d -m 0755 /var/lib/foreman-e2e
sudo install -m 0644 "$E2E_GUEST_TAR" /var/lib/foreman-e2e/guest.tar
# The fixture repo's host, which the agent refuses by default, and the
# guest image this run built. A drop-in: the install script owns the unit.
sudo mkdir -p /etc/systemd/system/foreman-agent.service.d
printf '[Service]\nEnvironment=FOREMAN_ALLOWED_GIT_HOSTS=%s FOREMAN_INSECURE_GIT_HOSTS=%s FOREMAN_GUEST_URL=file:///var/lib/foreman-e2e/guest.tar FOREMAN_GUEST_SHA256=%s FOREMAN_VM_CPUS=2 FOREMAN_VM_MEMORY_MB=3072 FOREMAN_VM_DISK_GB=20\n' \
  "$lan" "$lan" "$guest_sha" | sudo tee /etc/systemd/system/foreman-agent.service.d/e2e.conf >/dev/null
# A machine an earlier run enrolled with another control plane enrolls again.
reenroll=""
if sudo test -s /var/lib/foreman-agent/identity.json; then reenroll=--reenroll; fi
curl -fsSL "$url/agent/install.sh" | sudo sh -s -- $reenroll --token "$token" | tee "$work/install.log"
grep -q "foreman: enrolled" "$work/install.log" || fail "install.sh didn't enroll"
id -nG foreman | grep -qw docker && fail "the agent is in the docker group"
echo "ok: enrolled, not in the docker group"
[ "$(sudo stat -c '%U %a' /etc/foreman-agent/vmctl)" = "root 755" ] || fail "the VM helper isn't root's"
systemctl is-active --quiet foreman-vmctl.socket || fail "the VM helper's socket isn't listening"
echo "ok: the VM helper is root's and listening"
sudo nft list table inet foreman_guests >/dev/null || fail "the VM firewall table isn't loaded"
echo "ok: the VM firewall table is loaded"

# A unit is created per environment, and MainPID is the Cloud Hypervisor process.
running_vm_pid() {
  vm_pid=$(systemctl show -p MainPID --value "foreman-vm-$1.service") || return 1
  [ "$vm_pid" -gt 0 ] && printf '%s\n' "$vm_pid"
}

# A powered-off transient unit can already have been collected by systemd.
vm_powered_off() {
  units=$(systemctl list-units --all --plain --no-legend "foreman-vm-$1.service") || return 1
  [ -z "$units" ] || [ "$(printf '%s\n' "$units" | awk '{print $3}')" = inactive ]
}
vm_ready() { cp_eval 'E2E.vm_status()' | grep -q "^VM ready=true"; }
# Whether a VM's Cloud Hypervisor is confined by Landlock, by what it can
# do rather than how it was started (a resumed VM takes its settings from
# the snapshot): it can't write a snapshot to its unit's private /var/tmp,
# which is new and empty with each start of the unit, and which it could
# write without Landlock. Only a refusal for permission counts; any other
# failure says nothing. This is the VMM thread: a resumed VM's virtio
# workers start before Cloud Hypervisor applies Landlock
# (cloud-hypervisor#9118), which this can't see.
landlocked() { # env_id
  api=/srv/foreman/vms/$1/api.sock
  sudo curl -fsS -X PUT --unix-socket "$api" http://localhost/api/v1/vm.pause >/dev/null ||
    fail "couldn't pause $1's VM"
  probe=$(sudo curl -sS -X PUT --unix-socket "$api" -H 'Content-Type: application/json' \
    -d '{"destination_url":"file:///var/tmp"}' -w '\nHTTP %{http_code}' \
    http://localhost/api/v1/vm.snapshot 2>&1) || true
  sudo curl -fsS -X PUT --unix-socket "$api" http://localhost/api/v1/vm.resume >/dev/null ||
    fail "couldn't resume $1's VM"
  printf '%s\n' "$probe" | sed 's/^/  /'
  case "$probe" in
    *"HTTP 2"*) return 1 ;;
    *"Permission denied"* | *"os error 13"*) return 0 ;;
    *) fail "the snapshot outside $1's directory failed, but not for permission: can't tell whether it's confined" ;;
  esac
}
wait_for "the box reports it can run VMs" 60 vm_ready
cp_eval 'E2E.vm_status()' | grep "^VM"

# -- an environment --------------------------------------------------------------
# Creating, stopping and starting go through the environment's pages, as a
# user's clicks do, so the running control plane sends them at once. Work
# queued from an eval (a VM of its own) waits for the dispatch sweep, up
# to a minute each time.
public_api() {
  python3 "$root/e2e/vm/public_api.py" "$url" "$work/api-client.json" "$@"
}
cookie=$(cp_eval 'E2E.session_cookie()' | sed -n 's/^COOKIE=//p')
[ -n "$cookie" ] || fail "no session cookie"

create_primary() {
  primary_slug=$1
  E2E_COOKIE="$cookie" public_api login
  cold_started=$(date +%s)
  primary=$(public_api create)
  [ -n "$primary" ] || fail "the API did not reserve the no-deadline environment"
  wait_for_env "$primary_slug" running 600
  public_api ready --retry-operation "$retry_operation"
  cold_elapsed=$(( $(date +%s) - cold_started ))
}

if [ "$scenario" = expiry ]; then
  create_primary hello-1
else
  . ./e2e/vm/lifecycle.sh
fi
if [ "$scenario" != lifecycle ]; then
  . ./e2e/vm/expiry.sh
fi

public_api destroy
wait_for_env "$primary_slug" destroyed 180
public_api destroyed
wait_for "manual destroy powered off the no-deadline VM" 30 vm_powered_off "$primary"
sudo test ! -e "/srv/foreman/vms/$primary" || fail "API destroy left the workspace on disk"
public_api logout

if [ "$scenario" != expiry ]; then
  lv_click "/repos/$repo_id" delete_prebuild "{\"id\":\"$prebuild\"}" >/dev/null ||
    fail "couldn't delete the prebuild"
  wait_for "the prebuild's disk is deleted" 30 sh -c "[ -z \"\$(sudo ls -A /srv/foreman/prebuilds)\" ]"
fi
remaining=$(sudo ls -A /srv/foreman/vms) || fail "could not inspect the VM disks"
[ -z "$remaining" ] || fail "VM disks left behind: $remaining"
ip -br link | grep -q '^fm-vm' && fail "taps left behind"
echo "ok: nothing left on the box"

if [ "$scenario" = expiry ]; then
  say "PASSED"
  exit 0
fi

say "a box whose kernel has no Landlock runs no VMs"
# As if the kernel had none: the helper reads its LSM list from here.
sudo mount --bind /dev/null /sys/kernel/security/lsm
vmctl() { # request
  sudo -u foreman python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect("/run/foreman-vmctl.sock")
s.sendall(sys.argv[1].encode() + b"\n")
print(s.makefile().readline().strip())' "$1"
}
vmctl landlock | grep -q "^error this box's kernel has no Landlock" ||
  fail "the VM helper didn't say the kernel has no Landlock: $(vmctl landlock)"
sudo systemctl restart foreman-agent
vm_no_landlock() { cp_eval 'E2E.vm_status()' | grep -q '^VM ready=false .*no Landlock'; }
wait_for "the box reports it can't run VMs, and why" 90 vm_no_landlock
cp_eval 'E2E.vm_status()' | grep "^VM"
sudo umount /sys/kernel/security/lsm

say "PASSED"
