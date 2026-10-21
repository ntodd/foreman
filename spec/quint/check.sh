#!/usr/bin/env bash
#
# Checks what ops.qnt says about the code: the invariants the current code
# breaks (they should still break, until the code is fixed and the model
# updated to match), and that every invariant holds with the fixes on.
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
  sed -e "s/pure val FIX_RESEND_CLOCK = false/pure val FIX_RESEND_CLOCK = $1/" \
      -e "s/pure val FIX_CANCEL = false/pure val FIX_CANCEL = $2/" ops.qnt >"$tmp/ops_$1_$2.qnt"
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

current=$(variant false false)
echo "Current code:"
expect "$current" noPrematureTimeout violated
expect "$current" noResendAfterCancel violated
expect "$current" noStartAfterStop violated
expect "$current" atMostOncePerLife ok
expect "$current" noStuckWhenQuiet ok
expect "$current" succeededMeansRan ok

echo "With FIX_RESEND_CLOCK and FIX_CANCEL:"
expect "$(variant true true)" allInvariants ok

exit $failed
