# Shared setup for the control plane installer's tests. The installer is
# sourced (FOREMAN_INSTALLER_SOURCED keeps main from running), its paths
# point into the test's temp dir, and docker, tailscale, ss and friends
# are stubs on PATH that log their arguments to $STUB_LOG.

bats_require_minimum_version 1.5.0

INSTALLER="$BATS_TEST_DIRNAME/../../scripts/install-control-plane.sh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures"

setup_installer() {
  # Nothing from the developer's shell leaks into a test.
  local var
  for var in $(compgen -v FOREMAN_); do unset "$var"; done
  export FOREMAN_INSTALLER_SOURCED=1
  export FOREMAN_ETC="$BATS_TEST_TMPDIR/etc"
  export FOREMAN_OPT="$BATS_TEST_TMPDIR/opt"
  export FOREMAN_BACKUPS="$BATS_TEST_TMPDIR/backups"
  export FOREMAN_NONINTERACTIVE=1
  STUBS="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBS"
  export PATH="$STUBS:$PATH"
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  : > "$STUB_LOG"
  # shellcheck source=../../scripts/install-control-plane.sh
  source "$INSTALLER"
}

# stub NAME BODY: an executable NAME on PATH that logs "NAME args" and
# then runs BODY (bash, with the arguments in "$@").
stub() {
  {
    echo '#!/usr/bin/env bash'
    echo 'echo "'"$1"' $*" >> "$STUB_LOG"'
    printf '%s\n' "$2"
  } > "$STUBS/$1"
  chmod +x "$STUBS/$1"
}

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
inode_of() { ls -i "$1" | awk '{print $1}'; }
