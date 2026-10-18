#!/usr/bin/env bats
# Tracing (bash -x) must never print a secret: it's off unless
# FOREMAN_TRACE=1, and even then the functions that handle secrets run
# untraced.

load helpers

setup() {
  setup_installer
  ENV_FILE="$FOREMAN_ETC/foreman.env"
  mkdir -p "$FOREMAN_ETC" "$FOREMAN_OPT"
  export ENV_FILE
  export STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STATE"
  # The foreman container runs with $STATE/container-env, and its log is
  # boot.log (with a setup token in it).
  stub docker 'case "$1 $2" in
  "inspect -f") [ -e "$STATE/container-env" ] && cat "$STATE/container-env" ;;
  "volume inspect") exit 0 ;;
  "logs "*) cat "'"$FIXTURES"'/boot.log" ;;
  *) exit 1 ;;
esac'
  printf '%s\n' PATH=/usr/bin FOREMAN_ENCRYPTION_KEY=live-enc-secret SECRET_KEY_BASE=live-skb-secret > "$STATE/container-env"
}

# traced SCRIPT [FUNCTION...]: runs SCRIPT in bash with the installer
# sourced under FOREMAN_TRACE=1 and the FUNCTIONs (stand-ins defined in
# the test) redefined, then echoes traced-after; the trace is in $output.
traced() {
  local script=$1
  shift
  run bash -c 'FOREMAN_TRACE=1; source "$1"; '"$([ $# -eq 0 ] || declare -f "$@")"'
'"$script"'
echo traced-after' _ "$INSTALLER"
}

# Tracing is on outside the functions that handle secrets, and comes back
# on after them.
assert_traced() {
  [[ "$output" == *"+ echo traced-after"* ]] || false
}

@test "bash -x doesn't trace the installer without FOREMAN_TRACE=1" {
  run bash -x -c 'source "$1"; settle_secrets "$2"; echo done' _ "$INSTALLER" "$ENV_FILE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *done* ]] || false
  [[ "$output" != *"+ settle_secrets"* ]] || false
  [[ "$output" != *live-enc-secret* ]] || false
  [ "$(env_get "$ENV_FILE" FOREMAN_ENCRYPTION_KEY)" = live-enc-secret ]
}

@test "--help documents FOREMAN_TRACE" {
  FOREMAN_INSTALLER_SOURCED= run bash "$INSTALLER" --help
  [[ "$output" == *FOREMAN_TRACE=1* ]] || false
}

@test "FOREMAN_TRACE=1 traces settle_secrets without the secrets it adopts or makes" {
  traced 'settle_secrets "$ENV_FILE"; ensure_secrets "$FOREMAN_ETC/fresh.env"'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_traced
  [[ "$output" == *"+ settle_secrets"* ]] || false
  [[ "$output" != *live-enc-secret* ]] || false
  [[ "$output" != *live-skb-secret* ]] || false
  for key in SECRET_KEY_BASE FOREMAN_ENCRYPTION_KEY; do
    value=$(env_get "$FOREMAN_ETC/fresh.env" "$key")
    [ -n "$value" ]
    [[ "$output" != *"$value"* ]] || false
  done
}

@test "FOREMAN_TRACE=1 doesn't trace a secret read from the terminal or saved to the settings file" {
  unset FOREMAN_NONINTERACTIVE
  export FOREMAN_TTY="$BATS_TEST_TMPDIR/tty"
  printf '%s\n' tskey-from-terminal > "$FOREMAN_TTY"
  apply_control_plane() { :; }
  check_tailscale_oauth() { :; }
  export FOREMAN_TAILSCALE_CLIENT_ID=k123
  traced 'HOST_PORT=4100; save_tailscale_oauth; env_set "$ENV_FILE" A=1' apply_control_plane check_tailscale_oauth
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_traced
  [ "$(env_get "$ENV_FILE" FOREMAN_TAILSCALE_CLIENT_SECRET)" = tskey-from-terminal ]
  [[ "$output" != *tskey-from-terminal* ]] || false
}

@test "FOREMAN_TRACE=1 doesn't trace the OAuth secrets it compares" {
  printf '%s\n' FOREMAN_TAILSCALE_CLIENT_ID=k1 FOREMAN_TAILSCALE_CLIENT_SECRET=tskey-old-secret > "$ENV_FILE"
  apply_control_plane() { :; }
  check_tailscale_oauth() { :; }
  export FOREMAN_TAILSCALE_CLIENT_SECRET=tskey-new-secret
  traced 'HOST_PORT=4100; configure_tailscale_oauth' apply_control_plane check_tailscale_oauth
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_traced
  [ "$(env_get "$ENV_FILE" FOREMAN_TAILSCALE_CLIENT_SECRET)" = tskey-new-secret ]
  [[ "$output" != *tskey-old-secret* ]] || false
  [[ "$output" != *tskey-new-secret* ]] || false
}

@test "FOREMAN_TRACE=1 doesn't trace the GHCR token" {
  # The first pull is refused for want of a login; the one after works.
  stub docker 'case "$1" in
  image) exit 1 ;;
  pull) [ -e "$STATE/logged-in" ] || { echo "unauthorized" >&2; exit 1; } ;;
  login) cat > "$STATE/logged-in" ;;
esac'
  export FOREMAN_GHCR_TOKEN=ghp-secret-token FOREMAN_GHCR_USER=octocat
  traced 'ensure_image ghcr.io/ntodd/foreman:0.3.0'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_traced
  [ "$(cat "$STATE/logged-in")" = ghp-secret-token ]
  [[ "$output" != *ghp-secret-token* ]] || false
}

@test "FOREMAN_TRACE=1 doesn't trace a box's join token" {
  echo "TOKEN fj_join_secret_token" > "$STATE/mint"
  cp_eval() { cat "$STATE/mint"; }
  http_status() { echo 200; }
  stub curl 'while [ $# -gt 0 ]; do if [ "$1" = -o ]; then out=$2; fi; shift; done
printf "%s\n" "TOKEN=\"\${FOREMAN_JOIN_TOKEN:-}\"" "echo \"\$TOKEN\" > \"\$STATE/token\"" > "$out"'
  export FOREMAN_ADMINS=octocat FOREMAN_BOX_NAME=dev AGENT_IDENTITY="$BATS_TEST_TMPDIR/identity.json"
  traced 'HOST_PORT=4100 BASE_URL=https://h ARCH=amd64 AGENT_IDENTITY=$AGENT_IDENTITY; enroll_box' cp_eval http_status
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_traced
  [ "$(cat "$STATE/token")" = fj_join_secret_token ]
  [[ "$output" != *fj_join_secret_token* ]] || false
}

@test "FOREMAN_TRACE=1 doesn't trace the setup token in the control plane's log" {
  traced check_control_plane_log
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_traced
  [[ "$output" != *newsetuptoken* ]] || false
}

@test "FOREMAN_TRACE=1 doesn't trace a Postgres URL's password" {
  echo 'DATABASE_URL=ecto://u:pg-secret-password@db/foreman' > "$ENV_FILE"
  traced 'refuse_postgres "$ENV_FILE" || true'
  [[ "$output" != *pg-secret-password* ]] || false
}
