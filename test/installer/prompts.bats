#!/usr/bin/env bats

load helpers

setup() { setup_installer; }

# An answers file stands in for /dev/tty.
answers() {
  unset FOREMAN_NONINTERACTIVE
  export FOREMAN_TTY="$BATS_TEST_TMPDIR/tty"
  printf '%s\n' "$@" > "$FOREMAN_TTY"
}

@test "ask uses the environment variable without prompting" {
  answers should-not-be-read
  export FOREMAN_ADMINS=octocat
  ask FOREMAN_ADMINS "Your GitHub login"
  [ "$FOREMAN_ADMINS" = octocat ]
}

@test "ask takes the default when non-interactive" {
  ask FOREMAN_BOX_NAME "Box name" dev
  [ "$FOREMAN_BOX_NAME" = dev ]
}

@test "ask fails non-interactive with no default, naming the variable" {
  run ask FOREMAN_ADMINS "Your GitHub login"
  [ "$status" -eq 1 ]
  [[ "$output" == *FOREMAN_ADMINS* ]]
}

@test "ask reads answers from the terminal, one per question" {
  answers octocat ""
  ask FOREMAN_ADMINS "Your GitHub login"
  ask FOREMAN_BOX_NAME "Box name" dev
  [ "$FOREMAN_ADMINS" = octocat ]
  [ "$FOREMAN_BOX_NAME" = dev ]
}

@test "ask asks again when a required answer is empty" {
  answers "" octocat
  ask FOREMAN_ADMINS "Your GitHub login"
  [ "$FOREMAN_ADMINS" = octocat ]
}

@test "ask_secret doesn't echo what was typed" {
  answers hunter2-not-a-token
  run ask_secret FOREMAN_GHCR_TOKEN "Token"
  [ "$status" -eq 0 ]
  [[ "$output" != *hunter2* ]]
  ask_secret FOREMAN_GHCR_TOKEN "Token" 2>/dev/null
  [ "$FOREMAN_GHCR_TOKEN" = hunter2-not-a-token ]
}

@test "ask_secret fails non-interactive without the variable" {
  run ask_secret FOREMAN_GHCR_TOKEN "Token"
  [ "$status" -eq 1 ]
  [[ "$output" == *FOREMAN_GHCR_TOKEN* ]]
}

@test "confirm reads yes/no from the environment" {
  FOREMAN_INSTALL_NODE=yes
  confirm FOREMAN_INSTALL_NODE "Install Node?" n
  FOREMAN_INSTALL_NODE=no
  run confirm FOREMAN_INSTALL_NODE "Install Node?" y
  [ "$status" -eq 1 ]
}

@test "confirm takes the default when non-interactive" {
  confirm FOREMAN_X "Go?" y
  run confirm FOREMAN_X "Go?" n
  [ "$status" -eq 1 ]
}

@test "confirm reads the terminal" {
  answers n y ""
  run confirm FOREMAN_X "Go?" y
  [ "$status" -eq 1 ]
}

@test "without a terminal the installer is non-interactive" {
  unset FOREMAN_NONINTERACTIVE
  export FOREMAN_TTY="$BATS_TEST_TMPDIR/missing/tty"
  run ask FOREMAN_ADMINS "Your GitHub login"
  [ "$status" -eq 1 ]
  [[ "$output" == *FOREMAN_ADMINS* ]]
}

@test "parse_args maps flags onto the variables" {
  parse_args --version v0.4.0 --image foreman-smoke:0.3.0 --port 4100 --https-port 8443 \
    --admin octocat --public-key abc+/= --github-app manual --github-key /tmp/app.pem \
    --box-name dev --skip-box --skip-tailscale --non-interactive
  [ "$FOREMAN_VERSION" = v0.4.0 ]
  [ "$FOREMAN_IMAGE" = foreman-smoke:0.3.0 ]
  [ "$FOREMAN_PORT" = 4100 ]
  [ "$FOREMAN_HTTPS_PORT" = 8443 ]
  [ "$FOREMAN_ADMINS" = octocat ]
  [ "$FOREMAN_AGENT_RELEASE_PUBLIC_KEY" = abc+/= ]
  [ "$FOREMAN_GITHUB_APP" = manual ]
  [ "$FOREMAN_GITHUB_KEY_FILE" = /tmp/app.pem ]
  [ "$FOREMAN_BOX_NAME" = dev ]
  [ "$FOREMAN_BOX" = skip ]
  [ "$FOREMAN_TAILSCALE" = skip ]
  [ "$FOREMAN_NONINTERACTIVE" = 1 ]
}

@test "parse_args rejects an unknown option with 64" {
  run parse_args --frobnicate
  [ "$status" -eq 64 ]
  run parse_args --github-app sideways
  [ "$status" -eq 64 ]
}
