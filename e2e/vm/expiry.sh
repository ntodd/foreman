# Sourced by e2e/vm/run.sh on the disposable VM host.
say "expiry survives a control-plane restart and an offline box"
# Both API grants build cold. Use this runner's measured API create-to-ready
# time, including any registry retry, for two contending builds. Leave time
# for a delayed pull and for the restart and both offline observations.
service_api() { python3 "$root/e2e/vm/public_api.py" "$url" "$work/service-client.json" "$@"; }
(umask 077; cp_eval 'E2E.service_client()' | sed -n 's/^E2E_SERVICE=//p' > "$work/service-client.json")
[ -s "$work/service-client.json" ] || fail "the service account fixture was not created"
build_seconds=$((2 * cold_elapsed + 90))
build_by=$(( $(date +%s) + build_seconds ))
expires=$(date -u -d "@$((build_by + 90))" '+%Y-%m-%dT%H:%M:%SZ')
echo "Cold API build took ${cold_elapsed}s; expiry at $expires allows ${build_seconds}s for the two builds"
keep=$(public_api create --workspace keep --expiry stop "$expires")
drop=$(service_api create --expiry destroy "$expires" --hidden "$keep")

# Each client owns a separate state file. Follow its original receipt, or
# the exact replacement operation if the registry rejected the image pull.
ready_for_expiry() (
  client=$1
  shift
  retry_operation='' attempts=0
  while [ "$(date +%s)" -lt "$build_by" ]; do
    remaining=$((build_by - $(date +%s)))
    result=0
    failed_id=$("$client" ready --wait "$remaining" --retry-operation "$retry_operation" "$@") || result=$?
    [ "$result" -ne 0 ] || exit 0
    # EX_TEMPFAIL is reserved for a registry rejection in this exact operation's logs.
    [ "$result" -eq 75 ] || exit "$result"
    if [ "$attempts" -ge 2 ] || [ $((build_by - $(date +%s))) -le 30 ]; then
      break
    fi
    attempts=$((attempts + 1))
    echo "Registry limited create $failed_id; retrying ($attempts)" >&2
    sleep 30
    retry_operation=$(cp_eval "E2E.retry_create(\"$failed_id\")" | sed -n 's/^RETRY=//p')
    [ -n "$retry_operation" ] || break
  done
  exit 1
)
ready_for_expiry public_api --workspace keep --hidden "$drop" &
keep_ready=$!
if ! ready_for_expiry service_api; then
  wait "$keep_ready" || true
  fail "service workspace did not finish its cold build before the outage"
fi
wait "$keep_ready" || fail "personal workspace did not finish its cold build before the outage"
service_api marker >/dev/null
keep_marker=$(public_api marker --workspace keep)
primary_pid=$(running_vm_pid "$primary") || fail "the no-deadline VM is not running"
keep_pid=$(running_vm_pid "$keep") || fail "the expiry stop VM is not running"
drop_pid=$(running_vm_pid "$drop") || fail "the expiry destroy VM is not running"
sudo systemctl stop foreman-agent
docker restart "$cp_name" >/dev/null
wait_for "the restarted control plane" 120 curl -fsS "$url/healthz"
# The clients have independent credentials and state files. Both must
# observe the restarted control plane with time remaining on their policy.
public_api pending-expiry --workspace keep &
keep_poll=$!
expiry_failed=0
if ! service_api pending-expiry; then
  expiry_failed=1
fi
wait "$keep_poll" || expiry_failed=1
[ "$expiry_failed" -eq 0 ] || fail "expiry did not queue at the deadline while offline"
cp_eval "E2E.check_expiry_times([\"$keep\", \"$drop\"])" || fail "expiry was queued prematurely"
sudo test -s "/srv/foreman/vms/$keep/data.raw" || fail "offline stop lost its disk"
sudo test -s "/srv/foreman/vms/$drop/data.raw" || fail "offline destroy reported premature cleanup"
[ "$(running_vm_pid "$keep")" = "$keep_pid" ] || fail "the expiry stop VM stopped or restarted while offline"
[ "$(running_vm_pid "$drop")" = "$drop_pid" ] || fail "the expiry destroy VM stopped or restarted while offline"
sudo systemctl start foreman-agent
public_api not_ready --workspace keep --wait 180
wait_for "expiry stop powered off the VM" 30 vm_powered_off "$keep"
public_api ready
[ "$(running_vm_pid "$primary")" = "$primary_pid" ] || fail "the no-deadline VM stopped or restarted"
wait_for "the expired destroy removed the VM disk" 180 sudo test ! -e "/srv/foreman/vms/$drop"
wait_for "expiry destroy powered off the VM" 30 vm_powered_off "$drop"
wait_for "the API records the expiry destroy" 60 service_api destroyed
sudo test -s "/srv/foreman/vms/$keep/data.raw" || fail "expiry stop removed the workspace disk"
public_api start --workspace keep
public_api ready --workspace keep --wait 300
[ "$(public_api marker --workspace keep)" = "$keep_marker" ] || fail "the workspace changed after expiry stop"
public_api destroy --workspace keep
wait_for "the restarted workspace is destroyed" 180 sudo test ! -e "/srv/foreman/vms/$keep"
wait_for "manual destroy powered off the restarted VM" 30 vm_powered_off "$keep"
wait_for "the API records manual destroy" 60 public_api destroyed --workspace keep
service_api logout
