#!/usr/bin/env bash
#
# Checks what the models say.
#
# ops.qnt: every invariant holds for the code as it is, and without the
# fixes for #31 and #95 (the code as of v0.4.3) the ones they fixed break
# again, so the model still tells the difference.
#
# updates.qnt: the code as it is (v0.4.3 here) breaks the invariants #24 is
# about, and the three proposed fixes together make every one hold, while
# any two of them leave something broken.
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

# Prints ok or violated; anything else is an error.
check() {
  local out
  out=$($quint run "$1" --invariant="$2" --max-samples="$samples" --max-steps="$3" --seed=1 2>&1 || true)
  case $out in
    *"No violation"*) echo ok ;;
    *"Invariant violated"*) echo violated ;;
    *) echo "quint failed on $2:" >&2; echo "$out" >&2; exit 2 ;;
  esac
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
echo "updates.qnt, the code as it is:"
expect updates.qnt neverStranded violated
expect updates.qnt badNeverKept violated
expect updates.qnt rollbackInTime violated
expect updates.qnt boundedRetries ok
expect updates.qnt succeededSticks ok

echo "updates.qnt with FIX_CONFIRM, FIX_WATCHDOG and FIX_ROLLBACK_UNIT:"
expect "$(variant updates.qnt FIX_CONFIRM=true FIX_WATCHDOG=true FIX_ROLLBACK_UNIT=true)" allInvariants ok

echo "updates.qnt without FIX_ROLLBACK_UNIT (the watchdog's exit can still hit the start limit):"
expect "$(variant updates.qnt FIX_CONFIRM=true FIX_WATCHDOG=true FIX_ROLLBACK_UNIT=false)" neverStranded violated

exit $failed
