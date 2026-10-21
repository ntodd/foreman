#!/usr/bin/env bash
#
# Checks what ops.qnt says: every invariant holds for the code as it is,
# and without the fixes for #31 and #95 (the code as of v0.4.3) the ones
# they fixed break again, so the model still tells the difference.
#
#   ./check.sh            QUINT="quint" to use an installed one
#   SAMPLES=100000 ./check.sh

set -euo pipefail

cd "$(dirname "$0")"
quint=${QUINT:-npx --yes @informalsystems/quint}
samples=${SAMPLES:-30000}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

variant() {
  sed -e "s/pure val FIX_RESEND_CLOCK = [a-z]*/pure val FIX_RESEND_CLOCK = $1/" \
      -e "s/pure val FIX_CANCEL = [a-z]*/pure val FIX_CANCEL = $2/" ops.qnt >"$tmp/ops_$1_$2.qnt"
  echo "$tmp/ops_$1_$2.qnt"
}

# Prints ok or violated; anything else is an error.
check() {
  local out
  out=$($quint run "$1" --invariant="$2" --max-samples="$samples" --max-steps=40 --seed=1 2>&1 || true)
  case $out in
    *"No violation"*) echo ok ;;
    *"Invariant violated"*) echo violated ;;
    *) echo "quint failed on $2:" >&2; echo "$out" >&2; exit 2 ;;
  esac
}

failed=0
expect() {
  local file=$1 inv=$2 want=$3 got
  got=$(check "$file" "$inv")
  if [ "$got" = "$want" ]; then
    printf '  %-22s %s\n' "$inv" "$got"
  else
    printf '  %-22s %s (expected %s)\n' "$inv" "$got" "$want"
    failed=1
  fi
}

echo "The code as it is:"
expect ops.qnt allInvariants ok
echo "Reachable (witnesses, so the above isn't passing for want of them):"
expect ops.qnt noTimeouts violated
expect ops.qnt noTombstones violated
expect ops.qnt noReruns violated

old=$(variant false false)
echo "As of v0.4.3, before the fixes for #31 and #95:"
expect "$old" noPrematureTimeout violated
expect "$old" noResendAfterCancel violated
expect "$old" noStartAfterStop violated
expect "$old" atMostOncePerLife ok
expect "$old" noStuckWhenQuiet ok
expect "$old" succeededMeansRan ok

exit $failed
