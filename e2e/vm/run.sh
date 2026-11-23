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
#   E2E_VM_THROWAWAY=1 e2e/vm/run.sh
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
  i=0 retries=0
  until [ "$(env_observed "$1")" = "$2" ]; do
    if [ "$(env_observed "$1")" = error ]; then
      if [ "$retries" -lt 2 ] && rate_limited "$1"; then
        retries=$((retries + 1))
        echo "a registry limited pulls; trying $1 again ($retries)" >&2
        sleep 30
        cp_eval "E2E.retry_failed(\"$1\")" >/dev/null
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
mkdir -p "$work/overlay/.devcontainer"
cat > "$work/overlay/.devcontainer/devcontainer.json" <<EOF
{
  "name": "hello",
  "dockerComposeFile": ["docker-compose.yml"],
  "service": "app",
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
    image: public.ecr.aws/docker/library/docker:29-dind
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
rm -rf "$work/git"
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
box_id=$(cp_eval 'E2E.box_id()' | sed -n 's/^BOX_ID=//p')
repo_id=$(cp_eval 'E2E.repo_id()' | sed -n 's/^REPO_ID=//p')
create_env() { # slug it gets; prints its id
  lv_click /environments/new submit:create \
    "{\"environment\":{\"repo_id\":\"$repo_id\",\"box_id\":\"$box_id\"}}" >/dev/null ||
    fail "couldn't create $1"
  cp_eval "E2E.env_id(\"$1\")" | sed -n 's/^ENV=//p'
}

say "create an environment"
first=$(create_env hello-1)
[ -n "$first" ] || fail "no environment"
wait_for_env hello-1 running 900
unit=foreman-vm-$first.service
systemctl is-active --quiet "$unit" || fail "$unit isn't running"
[ "$(systemctl show -p User --value "$unit")" = foreman ] || fail "the VM doesn't run as foreman"
[ "$(systemctl show -p MemoryMax --value "$unit")" = $(((3072 + 512) * 1024 * 1024)) ] || fail "the VM's memory isn't limited"
[ "$(systemctl show -p CPUQuotaPerSecUSec --value "$unit")" = 2s ] || fail "the VM's CPU isn't limited"
group=$(systemctl show -p Group --value "$unit")
case "$group" in foreman-tap[0-9]*) ;; *) fail "the VM has no dedicated tap group" ;; esac
gid=$(getent group "$group" | cut -d: -f3)
[ -n "$gid" ] || fail "the VM tap group does not exist"
[ "$(cat "/sys/class/net/fm-vm${group#foreman-tap}/group")" = "$gid" ] ||
  fail "the tap does not require the VM's group"
[ "$(systemctl show -p ProtectProc --value "$unit")" = ptraceable ] ||
  fail "the VM can enumerate other processes"
pid=$(systemctl show -p MainPID --value "$unit")
grep -q '^CapEff:\s*0000000000000000$' "/proc/$pid/status" || fail "the VM has capabilities"
grep -q '^NoNewPrivs:\s*1$' "/proc/$pid/status" || fail "the VM can gain privileges"
grep -q '^Seccomp:\s*2$' "/proc/$pid/status" || fail "the VM has no seccomp filter"
tr '\0' '\n' < "/proc/$pid/cmdline" | grep -qx -- --landlock || fail "the VM was started without Landlock"
landlocked "$first" || fail "the VM wrote a snapshot outside its own directory: it isn't confined by Landlock"
echo "ok: the VM runs as foreman in $unit, limited, without capabilities, under seccomp and Landlock"
cp_eval 'E2E.log("hello-1", "create")' > "$work/create.log"
grep "^PROBE" "$work/create.log" || fail "the probe didn't run"
probe() { grep -q "^PROBE $1 $2\$" "$work/$3.log" || fail "probe $1: wanted $2, got $(grep "^PROBE $1 " "$work/$3.log")"; }
probe user vscode create
probe secrets-owner self create
probe workspace-writable 0 create
probe gateway 124 create
probe box 124 create
probe internet 0 create
probe lan 0 create
probe dind 0 create
echo "ok: the environment reaches the internet and the LAN, not the box, and runs docker-in-docker"

say "a second environment can't reach the first"
E2E_COOKIE="$cookie" public_api login
second=$(public_api create)
[ -n "$second" ] || fail "the API did not reserve the second environment"
wait_for_env hello-2 running 600
public_api ready
cp_eval 'E2E.log("hello-2", "create")' > "$work/create2.log"
probe first-guest 124 create2
probe gateway 124 create2
echo "ok: environments don't reach each other"

say "the API stops and starts the same workspace disk"
marker=$(sed -n 's/^PROBE workspace-marker //p' "$work/create2.log" | tail -1)
[ -n "$marker" ] || fail "the API-created workspace never wrote its marker"
public_api stop
wait_for_env hello-2 stopped 180
public_api not_ready
sudo test -s "/srv/foreman/vms/$second/data.raw" || fail "stop removed the workspace disk"
public_api start
wait_for_env hello-2 running 300
public_api ready
cp_eval 'E2E.log("hello-2", "start")' > "$work/start2.log"
probe workspace-marker "$marker" start2

say "secrets survive a stop and start"
cp_eval 'E2E.secret("hello-1", "SIDECAR_TOKEN", "vm-secret-1")' >/dev/null
sleep 5
lv_click "/environments/$first" action '{"do":"stop"}' >/dev/null || fail "couldn't stop hello-1"
wait_for_env hello-1 stopped 180
systemctl is-active --quiet "$unit" && fail "the VM is still running after stop"
echo "ok: stopped, VM off"
lv_click "/environments/$first" action '{"do":"start"}' >/dev/null || fail "couldn't start hello-1"
wait_for_env hello-1 running 300
systemctl is-active --quiet "$unit" || fail "the VM didn't boot again"
cp_eval 'E2E.log("hello-1", "start")' > "$work/start.log"
want=$(printf %s vm-secret-1 | sha256sum | cut -c1-16)
probe secret "$want" start
echo "ok: the secret reached the environment after a boot"

say "suspend and resume"
# The heartbeat's latest line: "<boot id> <guest clock>", from the
# environment page's Container logs.
beat() {
  previous=$(cp_eval 'E2E.last_logs("hello-1")' | sed -n 's/^LAST=//p')
  lv_click "/environments/$first" action '{"do":"logs"}' >/dev/null || fail "couldn't ask for the logs"
  cp_eval "E2E.await_logs(\"hello-1\", \"$previous\")" > "$work/beat.log"
  grep -q '^LOGS succeeded' "$work/beat.log" || { tail -20 "$work/beat.log" >&2; fail "couldn't read the heartbeat's logs"; }
  sed -n 's/.*PROBE beat //p' "$work/beat.log" | tail -1
}
read -r boot_before _ <<EOF
$(beat)
EOF
[ -n "$boot_before" ] || fail "no heartbeat before the suspend"
lv_click "/environments/$first" action '{"do":"suspend"}' >/dev/null || fail "couldn't suspend hello-1"
wait_for_env hello-1 suspended 180
systemctl is-active --quiet "$unit" && fail "the VM is still running after suspend"
sudo test -f "/srv/foreman/vms/$first/snapshot/config.json" || fail "no snapshot"
echo "ok: suspended, VM off, snapshot on disk"
# Long enough that a clock nobody put right would show it.
sleep 45
lv_click "/environments/$first" action '{"do":"start"}' >/dev/null || fail "couldn't start hello-1"
wait_for_env hello-1 running 300
cp_eval 'E2E.log("hello-1", "start")' > "$work/resume.log"
if grep -q "Couldn't resume" "$work/resume.log"; then
  grep -A2 "Couldn't resume" "$work/resume.log" >&2
  fail "the VM didn't resume, and was booted instead"
fi
# A beat or two from after the agent put the clock right.
sleep 5
read -r boot_after clock_after <<EOF
$(beat)
EOF
if [ -z "$boot_after" ] || [ "$boot_after" != "$boot_before" ]; then
  fail "the VM booted again ($boot_before, then $boot_after) instead of resuming"
fi
skew=$(( $(date +%s) - clock_after ))
if [ "$skew" -ge 20 ]; then
  # Stalled, or running on a clock nobody put right?
  sleep 10
  read -r _ clock_later <<EOF
$(beat)
EOF
  grep 'PROBE beat' "$work/beat.log" | tail -3 >&2
  if [ "$clock_later" = "$clock_after" ]; then
    fail "the heartbeat stopped after the resume: its last line is ${skew}s old"
  fi
  fail "the guest's clock is ${skew}s behind after the resume, and still moving"
fi
sudo test -e "/srv/foreman/vms/$first/snapshot" && fail "the snapshot outlived the resume"
landlocked "$first" || fail "the resumed VM wrote a snapshot outside its own directory: it isn't confined by Landlock"
echo "ok: resumed on the same boot, its VMM thread under Landlock, clock within ${skew}s, snapshot gone"

say "restarting the agent leaves the VMs running"
before=$(systemctl show -p MainPID --value "$unit")
sudo systemctl restart foreman-agent
wait_for "the agent rejoined" 60 sh -c "docker logs $cp_name 2>&1 | grep -c 'agent vmbox joined' | grep -q '^[2-9]'"
[ "$(systemctl show -p MainPID --value "$unit")" = "$before" ] || fail "the VM restarted with the agent"
sleep 20
[ "$(env_observed hello-1)" = running ] || fail "hello-1 isn't running after the agent restart"
echo "ok: same VM process, environment still running"

say "an environment from a prebuild"
build_prebuild() {
  lv_click "/repos/$repo_id" build_prebuild "{\"box\":\"$box_id\"}" | grep -q "Building a prebuild" ||
    fail "the prebuild didn't start"
  prebuild=$(cp_eval 'E2E.latest_prebuild()' | sed -n 's/^PREBUILD=//p')
}
build_prebuild
prebuild_ready() { cp_eval "E2E.prebuild_status(\"$prebuild\")" | grep -q '^PREBUILD ready'; }
i=0 retries=0
until prebuild_ready; do
  if cp_eval "E2E.prebuild_status(\"$prebuild\")" > "$work/prebuild.status" &&
    grep -q '^PREBUILD failed' "$work/prebuild.status"; then
    # A registry limiting the runner's pulls, as for environments above.
    if [ "$retries" -lt 2 ] && grep -qiE "toomanyrequests|too many requests|rate exceeded" "$work/prebuild.status"; then
      retries=$((retries + 1))
      echo "a registry limited pulls; building the prebuild again ($retries)" >&2
      sleep 30
      build_prebuild
      continue
    fi
    tail -60 "$work/prebuild.status" >&2
    fail "the prebuild failed"
  fi
  i=$((i + 5))
  [ $i -lt 900 ] || fail "timed out waiting for the prebuild"
  sleep 5
done
cp_eval "E2E.prebuild_status(\"$prebuild\")" | grep '^PREBUILD'
sudo test -f "/srv/foreman/prebuilds/$prebuild/data.raw" || fail "no prebuild disk on the box"
sudo test -e "/srv/foreman/vms/$prebuild" && fail "the prebuild's VM outlived the build"
ip -br link | grep -c '^fm-vm' | grep -qx 2 || fail "the prebuild's tap outlived the build"
echo "ok: built, its VM gone, its disk kept"

[ -n "$(create_env hello-3)" ] || fail "no environment from the prebuild"
wait_for_env hello-3 running 600
cp_eval 'E2E.log("hello-3", "create")' > "$work/create3.log"
grep -q "Starting from a prebuild" "$work/create3.log" || fail "the box didn't start hello-3's disk from the prebuild"
grep -q "Starting from the prebuild" "$work/create3.log" || fail "the guest didn't take over the prebuild's clone"
grep -q "Cloning acme/hello" "$work/create3.log" && fail "hello-3 cloned again"
grep -q "Container prebuild-" "$work/create3.log" && fail "the prebuild's containers came back in hello-3's VM"
probe secrets-owner self create3
probe first-guest 124 create3
cold=$(cp_eval 'E2E.took("hello-2", "create")' | sed -n 's/^TOOK //p')
warm=$(cp_eval 'E2E.took("hello-3", "create")' | sed -n 's/^TOOK //p')
echo "create took ${cold}s from scratch, ${warm}s from the prebuild"
[ "$warm" -lt "$cold" ] || fail "the create from the prebuild wasn't faster"
echo "ok: hello-3 started from the prebuild, without cloning"

say "release the other VMs before testing the memory reserve"
public_api destroy
cp_eval 'E2E.act("hello-3", "destroy")' >/dev/null
wait_for_env hello-2 destroyed 180
public_api destroyed
sudo test ! -e "/srv/foreman/vms/$second" || fail "API destroy left the workspace on disk"
wait_for_env hello-3 destroyed 180

say "the slice contains an OOM and the environment page records the cause"
slice=/sys/fs/cgroup/foreman.slice
limit=$(cat "$slice/memory.max")
case "$limit" in ''|*[!0-9]*) fail "foreman.slice has no memory ceiling" ;; esac
total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
# Allow for page rounding when systemd converts the configured percentage.
expected=$((total * 1024 * 90 / 100))
if [ "$limit" -lt $((expected - 1048576)) ] || [ "$limit" -gt $((expected + 1048576)) ]; then
  fail "unexpected default VM memory ceiling: $limit bytes"
fi
agent_pid=$(systemctl show foreman-agent -p MainPID --value)
[ "$agent_pid" -gt 0 ] || fail "agent is offline before the pressure test"
# Limit only the disposable VM slice. The agent and the control plane
# stay outside it. Restore its normal limit as soon as the kernel acts.
oom_count() { awk '$1 == "oom_kill" { print $2 }' "$slice/memory.events"; }
before=$(oom_count)
killed() { [ "$(oom_count)" -gt "$before" ]; }
(
  trap 'sudo systemctl set-property --runtime foreman.slice "MemoryMax=${limit}"' EXIT
  sudo systemctl set-property --runtime foreman.slice MemoryMax=64M
  wait_for "the VM slice recorded an OOM kill" 30 killed
)
oom_visible() {
  curl -fsS -b "$cookie" "$url/environments/$first" | grep 'id="vm-oom"' >/dev/null
}
wait_for "the environment page shows the box-reported OOM" 90 oom_visible
[ "$(systemctl show foreman-agent -p MainPID --value)" = "$agent_pid" ] ||
  fail "the agent restarted under pressure"

say "destroy"
cp_eval 'E2E.act("hello-1", "destroy")' >/dev/null
wait_for_env hello-1 destroyed 180

say "expiry survives a control-plane restart and an offline box"
# Both policies are submitted through the API and come due on the wall
# clock. Leave time for both prebuilt guests to boot before stopping the
# agent. The control plane restarts against its original data volume.
service_api() { python3 "$root/e2e/vm/public_api.py" "$url" "$work/service-client.json" "$@"; }
(umask 077; cp_eval 'E2E.service_client()' | sed -n 's/^E2E_SERVICE=//p' > "$work/service-client.json")
[ -s "$work/service-client.json" ] || fail "the service account fixture was not created"
expires=$(date -u -d '5 minutes' '+%Y-%m-%dT%H:%M:%SZ')
keep=$(public_api create --workspace keep --expiry stop "$expires")
drop=$(service_api create --expiry destroy "$expires" --hidden "$keep")
public_api ready --workspace keep --wait 240 --hidden "$drop"
service_api ready --wait 240
service_api marker >/dev/null
marker=$(public_api marker --workspace keep)
sudo systemctl stop foreman-agent
docker restart "$cp_name" >/dev/null
wait_for "the restarted control plane" 120 curl -fsS "$url/healthz"
public_api pending-expiry --workspace keep
service_api pending-expiry
sudo test -s "/srv/foreman/vms/$keep/data.raw" || fail "offline stop lost its disk"
sudo test -s "/srv/foreman/vms/$drop/data.raw" || fail "offline destroy reported premature cleanup"
sudo systemctl start foreman-agent
public_api not_ready --workspace keep --wait 180
wait_for "the expired destroy removed the VM disk" 180 sudo test ! -e "/srv/foreman/vms/$drop"
wait_for "the API records the expiry destroy" 60 service_api destroyed
sudo test -s "/srv/foreman/vms/$keep/data.raw" || fail "expiry stop removed the workspace disk"
public_api start --workspace keep
public_api ready --workspace keep --wait 300
[ "$(public_api marker --workspace keep)" = "$marker" ] || fail "the workspace changed after expiry stop"
public_api destroy --workspace keep
wait_for "the restarted workspace is destroyed" 180 sudo test ! -e "/srv/foreman/vms/$keep"
wait_for "the API records manual destroy" 60 public_api destroyed --workspace keep
public_api logout
service_api logout

lv_click "/repos/$repo_id" delete_prebuild "{\"id\":\"$prebuild\"}" >/dev/null ||
  fail "couldn't delete the prebuild"
[ -z "$(ls -A /srv/foreman/vms 2>/dev/null)" ] || fail "VM disks left behind: $(ls /srv/foreman/vms)"
wait_for "the prebuild's disk is deleted" 30 sh -c "[ -z \"\$(sudo ls -A /srv/foreman/prebuilds)\" ]"
ip -br link | grep -q '^fm-vm' && fail "taps left behind"
echo "ok: nothing left on the box"

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
