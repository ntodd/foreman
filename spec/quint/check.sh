#!/usr/bin/env bash
#
# Checks what the models say.
#
# ops.qnt: every invariant holds for the code as it is, and without the
# fixes for #31 and #95 (the code as of v0.4.3) the ones they fixed break
# again, so the model still tells the difference.
#
# updates.qnt, for systemd before 254 and from 254: the code as it is
# (v0.4.3 here) breaks the invariants #24 is about, and the three proposed
# fixes together make every one hold. Before 254 leaving out any of them
# breaks something again.
#
#   ./check.sh            QUINT="quint" to use an installed one
#   SAMPLES=100000 ./check.sh

set -euo pipefail

cd "$(dirname "$0")"
quint=${QUINT:-npx --yes @informalsystems/quint}
samples=${SAMPLES:-30000}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# variant <model> NAME=value...: a copy of the model with those switches set.
variant() {
  local model=$1 out args=()
  shift
  out="$tmp/$(basename "$model" .qnt)_$(echo "$*" | tr ' =' '__').qnt"
  for kv in "$@"; do
    args+=(-e "s/pure val ${kv%%=*} = [a-z]*/pure val ${kv%%=*} = ${kv#*=}/")
  done
  sed "${args[@]}" "$model" >"$out"
  echo "$out"
}

# Prints ok or violated (on any of three seeds); anything else is an error.
check() {
  local out seed
  for seed in 1 2 3; do
    out=$($quint run "$1" --invariant="$2" --max-samples="$samples" --max-steps="$3" --seed=$seed 2>&1 || true)
    case $out in
      *"No violation"*) ;;
      *"Invariant violated"*) echo violated; return ;;
      *) echo "quint failed on $2:" >&2; echo "$out" >&2; exit 2 ;;
    esac
  done
  echo ok
}

failed=0
steps=40
expect() {
  local file=$1 inv=$2 want=$3 got
  got=$(check "$file" "$inv" "$steps")
  if [ "$got" = "$want" ]; then
    printf '  %-22s %s\n' "$inv" "$got"
  else
    printf '  %-22s %s (expected %s)\n' "$inv" "$got" "$want"
    failed=1
  fi
}

echo "ops.qnt, the code as it is:"
expect ops.qnt allInvariants ok
echo "Reachable (witnesses, so the above isn't passing for want of them):"
expect ops.qnt noTimeouts violated
expect ops.qnt noTombstones violated
expect ops.qnt noReruns violated

old=$(variant ops.qnt FIX_RESEND_CLOCK=false FIX_CANCEL=false)
echo "ops.qnt as of v0.4.3, before the fixes for #31 and #95:"
expect "$old" noPrematureTimeout violated
expect "$old" noResendAfterCancel violated
expect "$old" noStartAfterStop violated
expect "$old" atMostOncePerLife ok
expect "$old" noStuckWhenQuiet ok
expect "$old" succeededMeansRan ok

steps=80
for systemd in false true; do
  if [ "$systemd" = true ]; then label="systemd 254 and later"; else label="systemd before 254"; fi
  model=$(variant updates.qnt SYSTEMD_254=$systemd)
  fixed=$(variant updates.qnt SYSTEMD_254=$systemd FIX_CONFIRM=true FIX_WATCHDOG=true FIX_ROLLBACK_UNIT=true)

  echo "updates.qnt, $label, the code as it is:"
  expect "$model" backOnline violated
  expect "$model" badNeverKept violated
  if [ "$systemd" = true ]; then
    expect "$model" updateSettles ok
  else
    expect "$model" updateSettles violated
  fi
  expect "$model" boundedInstalls ok
  expect "$model" succeededSticks ok

  echo "updates.qnt, $label, with FIX_CONFIRM, FIX_WATCHDOG and FIX_ROLLBACK_UNIT:"
  expect "$fixed" allInvariants ok
  expect "$fixed" noRollbacks violated
  expect "$fixed" noUpdates violated
done

echo "updates.qnt, systemd before 254, leaving one fix out:"
expect "$(variant updates.qnt FIX_CONFIRM=false FIX_WATCHDOG=true FIX_ROLLBACK_UNIT=true)" badNeverKept violated
expect "$(variant updates.qnt FIX_CONFIRM=true FIX_WATCHDOG=false FIX_ROLLBACK_UNIT=true)" updateSettles violated
expect "$(variant updates.qnt FIX_CONFIRM=true FIX_WATCHDOG=true FIX_ROLLBACK_UNIT=false)" backOnline violated

exit $failed
