#!/bin/bash
# What works on each kind of box, beyond speed: docker-in-docker, secrets
# delivery and Restart affected, stop and start with secrets restored,
# and environments surviving an agent restart. Run as root after
# `bench.sh setup`. Prints PASS/FAIL per check.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bench.sh
source "$here/bench.sh"
set +e

passed=0 failed=0
pass() { echo "PASS: $*"; passed=$((passed + 1)); }
flunk() { echo "FAIL: $*"; failed=$((failed + 1)); }
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else flunk "$desc"; fi; }

last_op() { cp_eval "Bench.state(\"$1\")" | grep '^STATE'; }
wait_done() { # slug -> prints final STATE line
  local line
  for _ in $(seq 900); do
    line=$(last_op "$1")
    case "$line" in *" succeeded" | *" failed" | *" cancelled") echo "$line"; return ;; esac
    sleep 2
  done
  echo "$line"
}
in_vm_app() { # env_id cmd...
  local id=$1; shift
  local c
  c=$(incus exec "fm-$id" -- docker ps -q --filter "label=foreman.env_id=$id" --filter label=com.docker.compose.service=app </dev/null)
  incus exec "fm-$id" -- docker exec -u vscode "$c" "$@" </dev/null
}

say "fixture: docker-in-docker repo"
sh "$here/make-dind-repo.sh" "$WORK/git" >/dev/null
docker exec -e E2E_ADMIN=bench -e E2E_REPO=acme/dind -e E2E_BOX=unused vmbench-cp \
  env -u PHX_SERVER /app/bin/foreman eval 'Code.eval_file("/e2e/seed.exs")' >/dev/null 2>&1

say "docker-in-docker on the container box"
read -r ct_id ct_slug < <(create_env bench-ct nil nil acme/dind)
line=$(wait_done "$ct_slug")
if [[ "$line" == *" failed" ]]; then
  pass "the container box refuses a privileged devcontainer (as today)"
else
  flunk "the container box ran a privileged devcontainer: $line"
fi
cp_eval "Bench.act(\"$ct_slug\", \"destroy\")" >/dev/null

say "docker-in-docker on the VM box"
read -r id slug < <(create_env bench-vm 4 8192 acme/dind)
line=$(wait_done "$slug")
if [[ "$line" == *" succeeded" ]]; then
  pass "the VM box runs the docker-in-docker feature"
  check "docker run works inside the environment" in_vm_app "$id" docker run --rm hello-world
  check "and builds images" in_vm_app "$id" sh -c 'printf "FROM alpine:3.22\nRUN echo built\n" | docker build -q -'
  check "the privileged container is still inside its own VM (the box's Docker can't see it)" \
    sh -c "! docker ps -a --format '{{.Labels}}' | grep -q $id"
else
  flunk "the VM box couldn't create the docker-in-docker environment: $line"
  cp_eval "Bench.log(\"$slug\")" | tail -20
fi

say "secrets and Restart affected"
cp_eval "Bench.secret(\"$slug\", \"BENCH_SECRET\", \"vm-secret-0123456789\")" >/dev/null
# Changes made through `bin/foreman eval` reach the box on the control
# plane's next sweep, within a minute.
for _ in $(seq 90); do grep -q vm-secret-0123456789 "/run/foreman-vm/envs/$id/secrets.env" 2>/dev/null && break; sleep 1; done
check "a new secret reaches the environment" in_vm_app "$id" grep -q vm-secret-0123456789 /run/foreman/secrets.env
check "the host keeps its copy for restarts" grep -q vm-secret-0123456789 "/run/foreman-vm/envs/$id/secrets.env"
cp_eval "Bench.act(\"$slug\", \"restart_affected\")" >/dev/null
line=$(wait_done "$slug")
[[ "$line" == *" succeeded" ]] && pass "Restart affected" || flunk "Restart affected: $line"

say "agent restart"
before=$(incus exec "fm-$id" -- docker ps --format '{{.Status}}' </dev/null | head -1)
systemctl restart foreman-agent-vm
sleep 25
check "the VM keeps running when the agent restarts" sh -c "incus list fm-$id -f csv -c s </dev/null | grep -q RUNNING"
after=$(incus exec "fm-$id" -- docker ps --format '{{.Status}}' </dev/null | head -1)
[ -n "$after" ] && [ "$after" != "Exited" ] && pass "its containers keep running ($before -> $after)" || flunk "containers after agent restart: $after"
sees_running() { cp_eval 'Bench.status()' | grep -q "ENV $slug desired=running observed=running"; }
check "the control plane still sees it running" sees_running

say "stop and start"
cp_eval "Bench.act(\"$slug\", \"stop\")" >/dev/null
line=$(wait_done "$slug")
[[ "$line" == *" succeeded" ]] && pass "stop" || flunk "stop: $line"
check "stop shuts the VM down (its memory goes back to the box)" sh -c "incus list fm-$id -f csv -c s </dev/null | grep -q STOPPED"
cp_eval "Bench.act(\"$slug\", \"start\")" >/dev/null
line=$(wait_done "$slug")
[[ "$line" == *" succeeded" ]] && pass "start" || flunk "start: $line"
check "secrets are back after the VM booted again" in_vm_app "$id" grep -q vm-secret-0123456789 /run/foreman/secrets.env

say "destroy"
cp_eval "Bench.act(\"$slug\", \"destroy\")" >/dev/null
for _ in $(seq 120); do incus list "fm-$id" -f csv </dev/null | grep -q . || break; sleep 2; done
check "destroy deletes the VM" sh -c "! incus list fm-$id -f csv </dev/null | grep -q ."
check "and the host's secrets copy" test ! -e "/run/foreman-vm/envs/$id"

echo
echo "$passed passed, $failed failed"
