# Sourced by e2e/vm/run.sh on the disposable VM host.
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

# The box is still unreachable from inside, as above. The API is asked of
# the guest agent over a socket, and the box relays it.
probe api-socket self:600 create
probe api-me 200 create
probe api-is this-environment create
probe api-environments "200 1" create
probe api-repos 403 create
probe api-boxes 403 create
probe api-user-secrets 403 create
probe api-outside 400 create
echo "ok: the environment reaches Foreman's API as itself, with no token, and nothing beyond itself"

say "a second environment can't reach the first"
create_primary hello-2
cp_eval 'E2E.log("hello-2", "create")' > "$work/create2.log"
probe first-guest 124 create2
probe gateway 124 create2
# Each asks as itself, with the other running beside it on the same box.
probe api-is this-environment create2
probe api-environments "200 1" create2
echo "ok: environments don't reach each other"

say "the API stops and starts the same workspace disk"
marker=$(sed -n 's/^PROBE workspace-marker //p' "$work/create2.log" | tail -1)
[ -n "$marker" ] || fail "the API-created workspace never wrote its marker"
if [ -n "${FOREMAN_CLI:-}" ]; then
  E2E_COOKIE="$cookie" public_api cli-stop
else
  public_api stop
fi
wait_for_env hello-2 stopped 180
public_api not_ready
wait_for "API stop powered off the VM" 30 vm_powered_off "$primary"
sudo test -s "/srv/foreman/vms/$primary/data.raw" || fail "stop removed the workspace disk"
public_api start
wait_for_env hello-2 running 300
public_api ready --retry-operation "$retry_operation"
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
public_api stop
cp_eval 'E2E.act("hello-3", "destroy")' >/dev/null
wait_for_env hello-2 stopped 180
public_api not_ready
wait_for "the no-deadline VM is off before memory pressure" 30 vm_powered_off "$primary"
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

# Check the no-deadline workspace and its disk marker after memory pressure.
public_api start
wait_for_env hello-2 running 300
public_api ready --retry-operation "$retry_operation"
[ "$(public_api marker)" = "$marker" ] || fail "the primary workspace lost its marker"
