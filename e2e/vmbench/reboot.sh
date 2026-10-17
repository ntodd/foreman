#!/bin/bash
# A box reboot with an environment of each kind running: before and after
# halves, with the reboot itself in between (on the testbed, `limactl
# stop fbox && limactl start fbox` from the Mac).
#   e2e/vmbench/reboot.sh before     create both, set a secret, enable boot units
#   e2e/vmbench/reboot.sh after      wait for both to be running again; check the secret
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bench.sh
source "$here/bench.sh"
set +e
state="$WORK/results/reboot.env"
BENCH_CPUS=2 REPS=1

secret_in() { # box id
  local x
  x=$(app_exec "$1" "$2" | sed 's|-w /workspaces/vmbench|-w /|')
  $x grep -q reboot-secret-0123456789 /run/foreman/secrets.env </dev/null
}

case "${1:-}" in
  before)
    sh "$here/../make-git-fixture.sh" "$WORK/git" >/dev/null
    : > "$state"
    for box in bench-ct bench-vm; do
      read -r id slug < <(create_env "$box" 2 4096 acme/hello)
      wait_op "$slug" 1800
      cp_eval "Bench.secret(\"$slug\", \"REBOOT_SECRET\", \"reboot-secret-0123456789\")" >/dev/null
      echo "$box $id $slug" >> "$state"
    done
    for _ in $(seq 120); do
      ok=1
      while read -r box id slug; do secret_in "$box" "$id" || ok=0; done < "$state"
      [ $ok = 1 ] && break
      sleep 2
    done
    [ $ok = 1 ] && echo "PASS: both environments have the secret before the reboot" || echo "FAIL: secret before reboot"
    # What a real box has: everything comes back by itself.
    docker update --restart unless-stopped vmbench-cp >/dev/null
    systemctl enable foreman-agent-ct foreman-agent-vm >/dev/null 2>&1
    incus list -f csv -c ns </dev/null
    date +%s > "$WORK/results/reboot.at"
    ;;
  after)
    systemctl is-active --quiet vmbench-git || systemd-run --unit vmbench-git --quiet python3 -m http.server "$GIT_PORT" --bind 0.0.0.0 --directory "$WORK/git"
    up=$(awk '{print int($1)}' /proc/uptime)
    echo "box up ${up}s"
    incus list -f csv -c ns </dev/null | sed 's/^/before the control plane acts: /'
    while read -r box id slug; do
      t=$SECONDS
      for _ in $(seq 300); do
        cp_eval 'Bench.status()' | grep -q "ENV $slug desired=running observed=running" && break
        sleep 2
      done
      if cp_eval 'Bench.status()' | grep -q "ENV $slug desired=running observed=running"; then
        echo "PASS: $box: $slug is running again ($((up + SECONDS - t))s after boot at most)"
      else
        echo "FAIL: $box: $slug isn't running: $(cp_eval 'Bench.status()' | grep "ENV $slug")"
      fi
      for _ in $(seq 60); do secret_in "$box" "$id" && break; sleep 2; done
      secret_in "$box" "$id" && echo "PASS: $box: its secret is back" || echo "FAIL: $box: no secret after the reboot"
      cp_eval "Bench.ops(\"$slug\")" | grep '^OP' | tail -3 | sed "s/^/  $box /"
    done < "$state"
    ;;
  *) sed -n '2,7p' "$0"; exit 64 ;;
esac
