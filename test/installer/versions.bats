#!/usr/bin/env bats

load helpers

setup() { setup_installer; }

@test "compose 2.30 and newer pass, including majors above 2" {
  compose_version_ok 2.30.0
  compose_version_ok v2.38.2
  compose_version_ok 2.30
  compose_version_ok 5.6.0
  compose_version_ok v3.0.1
}

@test "compose older than 2.30 is too old" {
  run compose_version_ok 2.29.7
  [ "$status" -eq 1 ]
  run compose_version_ok v2.24.0
  [ "$status" -eq 1 ]
  run compose_version_ok 1.29.2
  [ "$status" -eq 1 ]
}

@test "an unreadable compose version is an error, not a pass" {
  run compose_version_ok ""
  [ "$status" -eq 2 ]
  run compose_version_ok dev
  [ "$status" -eq 2 ]
  run compose_version_ok 2.x
  [ "$status" -eq 2 ]
}

@test "node 20 and newer pass" {
  node_version_ok v20.0.0
  node_version_ok v22.11.0
  node_version_ok 24.1.0
}

@test "node older than 20, or none, fails" {
  run node_version_ok v18.19.1
  [ "$status" -eq 1 ]
  run node_version_ok ""
  [ "$status" -ne 0 ]
}

@test "ensure_node fails with instructions when node is too old and installing is declined" {
  stub node 'echo v18.19.1'
  stub npm 'echo 10.0.0'
  export FOREMAN_SYSTEM_PATH="$STUBS"
  export FOREMAN_INSTALL_NODE=no
  run ensure_node
  [ "$status" -eq 1 ]
  [[ "$output" == *"Node 20"* ]]
  [[ "$output" == *"nodesource"* ]]
}

@test "ensure_node is a no-op when node 22 and npm are on the system PATH" {
  stub node 'echo v22.11.0'
  stub npm 'echo 10.9.0'
  stub apt-get 'exit 1'
  export FOREMAN_SYSTEM_PATH="$STUBS"
  run ensure_node
  [ "$status" -eq 0 ]
  run ! grep -q '^apt-get' "$STUB_LOG"
}

@test "ensure_node doesn't count a node that's only on the caller's PATH (nvm)" {
  stub node 'echo v22.11.0'
  stub npm 'echo 10.9.0'
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  export FOREMAN_SYSTEM_PATH="$BATS_TEST_TMPDIR/empty"
  export FOREMAN_INSTALL_NODE=no
  run ensure_node
  [ "$status" -eq 1 ]
  [[ "$output" == *"system PATH"* ]]
}

# A system PATH with only node on it (no npm), and fake apt and curl for
# the NodeSource install: curl writes a setup script that does nothing.
node_without_npm() {
  SYS="$BATS_TEST_TMPDIR/sys"
  mkdir -p "$SYS"
  printf '#!/bin/sh\necho %s\n' "$1" > "$SYS/node"
  chmod +x "$SYS/node"
  export FOREMAN_SYSTEM_PATH="$SYS"
  stub apt-get 'exit 0'
  stub curl 'while [ $# -gt 0 ]; do if [ "$1" = -o ]; then echo true > "$2"; fi; shift; done'
}

@test "ensure_node says npm is missing, not that Node is too old" {
  node_without_npm v22.23.3
  export FOREMAN_INSTALL_NODE=no
  run ensure_node
  [ "$status" -eq 1 ]
  [[ "$output" == *"npm is missing"* ]]
  [[ "$output" != *"older than 20"* ]]
}

@test "ensure_node says Node is too old when it is" {
  stub node 'echo v18.19.1'
  stub npm 'echo 10.0.0'
  export FOREMAN_SYSTEM_PATH="$STUBS"
  export FOREMAN_INSTALL_NODE=no
  run ensure_node
  [[ "$output" == *"Node v18.19.1 is older than 20"* ]]
  [[ "$output" != *"npm is missing"* ]]
}

@test "ensure_node fails when installing nodejs still leaves no npm" {
  node_without_npm v22.23.3
  export FOREMAN_INSTALL_NODE=yes
  run ensure_node
  [ "$status" -eq 1 ]
  [[ "$output" == *"npm"* ]]
  [[ "$output" != *"installed Node"* ]]
  grep -q '^apt-get .*install .*nodejs' "$STUB_LOG"
}
