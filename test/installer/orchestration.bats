#!/usr/bin/env bats
# The steps that tie the pieces together, with the container and the
# control plane's evals stubbed out.

load helpers

setup() {
  setup_installer
  ENV_FILE="$FOREMAN_ETC/foreman.env"
  mkdir -p "$FOREMAN_ETC" "$FOREMAN_OPT"
  echo FOREMAN_ENCRYPTION_KEY=k > "$ENV_FILE"
  HOST_PORT=4100 HTTPS_PORT=8443 TS_HOST=dev.example.ts.net TS_TAGS=""
  BASE_URL=https://dev.example.ts.net:8443 ARCH=amd64 FOREMAN_ADMINS=octocat
  AGENT_IDENTITY="$BATS_TEST_TMPDIR/identity.json"
  export STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STATE"
}

# answers LINE...: an answers file stands in for /dev/tty.
answers() {
  unset FOREMAN_NONINTERACTIVE
  export FOREMAN_TTY="$BATS_TEST_TMPDIR/tty"
  printf '%s\n' "$@" > "$FOREMAN_TTY"
}

# -- the Tailscale OAuth client ----------------------------------------------

stub_tailscale_steps() {
  apply_control_plane() { echo "apply" >> "$STUB_LOG"; }
  check_tailscale_oauth() { echo "check" >> "$STUB_LOG"; return "${CHECK_RC:-0}"; }
}

@test "configure_tailscale_oauth skips without a client or a terminal" {
  stub_tailscale_steps
  run configure_tailscale_oauth
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping"* ]]
  run ! grep -q apply "$STUB_LOG"
}

@test "configure_tailscale_oauth saves a client from the environment and checks it" {
  stub_tailscale_steps
  export FOREMAN_TAILSCALE_CLIENT_ID=k123 FOREMAN_TAILSCALE_CLIENT_SECRET=tskey-client-not-real
  run configure_tailscale_oauth
  [ "$status" -eq 0 ]
  [[ "$output" != *tskey-client-not-real* ]]
  [ "$(env_get "$ENV_FILE" FOREMAN_TAILSCALE_CLIENT_ID)" = k123 ]
  [ "$(env_get "$ENV_FILE" FOREMAN_TAILSCALE_CLIENT_SECRET)" = tskey-client-not-real ]
  [ "$(cat "$STUB_LOG")" = "$(printf '%s\n' apply check)" ]
}

@test "configure_tailscale_oauth only checks a configured client the environment repeats" {
  stub_tailscale_steps
  env_set "$ENV_FILE" FOREMAN_TAILSCALE_CLIENT_ID=k123 FOREMAN_TAILSCALE_CLIENT_SECRET=s1
  export FOREMAN_TAILSCALE_CLIENT_ID=k123 FOREMAN_TAILSCALE_CLIENT_SECRET=s1
  run configure_tailscale_oauth
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_LOG")" = check ]
}

@test "configure_tailscale_oauth replaces a configured client with a different one from the environment" {
  stub_tailscale_steps
  env_set "$ENV_FILE" FOREMAN_TAILSCALE_CLIENT_ID=k123 FOREMAN_TAILSCALE_CLIENT_SECRET=s1
  export FOREMAN_TAILSCALE_CLIENT_SECRET=s2-rotated
  run configure_tailscale_oauth
  [ "$status" -eq 0 ]
  [[ "$output" == *"replacing"* ]]
  [[ "$output" != *s2-rotated* ]]
  [ "$(env_get "$ENV_FILE" FOREMAN_TAILSCALE_CLIENT_ID)" = k123 ]
  [ "$(env_get "$ENV_FILE" FOREMAN_TAILSCALE_CLIENT_SECRET)" = s2-rotated ]
  grep -qx apply "$STUB_LOG"
}

@test "configure_tailscale_oauth needs the secret for a new client ID" {
  stub_tailscale_steps
  env_set "$ENV_FILE" FOREMAN_TAILSCALE_CLIENT_ID=k123 FOREMAN_TAILSCALE_CLIENT_SECRET=s1
  export FOREMAN_TAILSCALE_CLIENT_ID=k456
  run configure_tailscale_oauth
  [ "$status" -eq 1 ]
  [[ "$output" == *FOREMAN_TAILSCALE_CLIENT_SECRET* ]]
  [ "$(env_get "$ENV_FILE" FOREMAN_TAILSCALE_CLIENT_ID)" = k123 ]
}

@test "configure_tailscale_oauth leaves a failing client alone when unattended" {
  stub_tailscale_steps
  env_set "$ENV_FILE" FOREMAN_TAILSCALE_CLIENT_ID=k123 FOREMAN_TAILSCALE_CLIENT_SECRET=s1
  CHECK_RC=1 run configure_tailscale_oauth
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_LOG")" = check ]
}

@test "configure_tailscale_oauth asks for a new client on a terminal when the check fails" {
  stub_tailscale_steps
  env_set "$ENV_FILE" FOREMAN_TAILSCALE_CLIENT_ID=k123 FOREMAN_TAILSCALE_CLIENT_SECRET=s1
  answers y k789 s789
  CHECK_RC=1 run configure_tailscale_oauth
  [ "$status" -eq 0 ]
  [ "$(env_get "$ENV_FILE" FOREMAN_TAILSCALE_CLIENT_ID)" = k789 ]
  [ "$(env_get "$ENV_FILE" FOREMAN_TAILSCALE_CLIENT_SECRET)" = s789 ]
}

@test "check_tailscale_oauth reads the check's result" {
  cp_eval() { printf '%s\n' "12:00:00 [info] noise" "$CHECK_OUT"; }
  CHECK_OUT="TSCHECK ok" run check_tailscale_oauth
  [ "$status" -eq 0 ]
  [[ "$output" == *"lists devices"* ]]
  CHECK_OUT='TSCHECK devices 401 "unauthorized"' run check_tailscale_oauth
  [ "$status" -eq 1 ]
  [[ "$output" == *"rejected the OAuth client"* ]]
  CHECK_OUT='TSCHECK key 400 "requested tags are invalid"' run check_tailscale_oauth
  [ "$status" -eq 1 ]
  [[ "$output" == *"tagOwners"* ]]
  CHECK_OUT="TSCHECK no-creds" run check_tailscale_oauth
  [ "$status" -eq 1 ]
  [[ "$output" == *"force-recreate"* ]]
  CHECK_OUT="** (UndefinedFunctionError) boom" run check_tailscale_oauth
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't check"* ]]
  [[ "$output" == *"UndefinedFunctionError"* ]]
}

# -- starting the container --------------------------------------------------

# A fake docker: the container exists (from compose, unless $PROJECT says
# otherwise) once compose has started it.
stub_compose_docker() {
  stub docker 'case "$*" in
  *com.docker.compose.project*) [ -e "$STATE/exists" ] && echo "${PROJECT-foreman}" ;;
  *State.Running*) if [ -e "$STATE/exists" ]; then echo true; else echo false; fi ;;
  "inspect foreman") [ -e "$STATE/exists" ] ;;
  "compose up"*) touch "$STATE/exists" ;;
  *) exit 1 ;;
esac'
  wait_healthy() { echo "wait $*" >> "$STUB_LOG"; }
}

@test "apply_control_plane starts the container, then leaves it alone until the settings change" {
  stub_compose_docker
  apply_control_plane 4100
  [ "$(grep -c '^docker compose up -d --force-recreate' "$STUB_LOG")" -eq 1 ]
  grep -q '^wait foreman 4100' "$STUB_LOG"
  apply_control_plane 4100
  [ "$(grep -c '^docker compose up' "$STUB_LOG")" -eq 1 ]
  env_set "$ENV_FILE" FOREMAN_TAILSCALE_CLIENT_ID=new
  apply_control_plane 4100
  [ "$(grep -c '^docker compose up' "$STUB_LOG")" -eq 2 ]
}

@test "apply_control_plane recreates after a run that recreated the container and then failed" {
  stub_compose_docker
  apply_control_plane 4100
  cp -p "$ENV_FILE" "$BATS_TEST_TMPDIR/good.env"
  # A run with other settings recreates the container, which then never
  # gets healthy (or the run is interrupted there).
  env_set "$ENV_FILE" FOREMAN_ADMINS=someone-else
  wait_healthy() { echo "wait $*" >> "$STUB_LOG"; exit 1; }
  run apply_control_plane 4100
  [ "$status" -ne 0 ]
  [ "$(grep -c '^docker compose up' "$STUB_LOG")" -eq 2 ]
  # The settings go back to the last good ones, but the container still
  # has the failed run's environment.
  cp -p "$BATS_TEST_TMPDIR/good.env" "$ENV_FILE"
  wait_healthy() { echo "wait $*" >> "$STUB_LOG"; }
  run apply_control_plane 4100
  [ "$status" -eq 0 ]
  [[ "$output" != *"already running with these settings"* ]] || false
  [ "$(grep -c '^docker compose up' "$STUB_LOG")" -eq 3 ]
}

@test "apply_control_plane refuses a foreman container compose didn't create" {
  stub_compose_docker
  touch "$STATE/exists"
  PROJECT="" run apply_control_plane 4100
  [ "$status" -eq 1 ]
  [[ "$output" == *"docker rm -f foreman"* ]]
  run ! grep -q '^docker compose up' "$STUB_LOG"
}

# -- the box ----------------------------------------------------------------

# cp_eval answers with the lines of $MINT_REPLIES in turn; the box
# installer from the control plane logs how it was called.
stub_box() {
  printf '%s\n' "$@" > "$STATE/replies"
  cp_eval() {
    local first
    first=$(head -n 1 "$STATE/replies")
    sed -i.bak 1d "$STATE/replies"
    echo "cp_eval mint" >> "$STUB_LOG"
    echo "$first"
  }
  http_status() { echo 200; }
  export INSTALL_SH="${INSTALL_SH:-new}"
  stub curl 'while [ $# -gt 0 ]; do if [ "$1" = -o ]; then out=$2; fi; shift; done
if [ "$INSTALL_SH" = new ]; then
  printf "%s\n" "TOKEN=\"\${FOREMAN_JOIN_TOKEN:-}\"" "echo \"install.sh args=[\$*] env=[\$TOKEN]\" >> \"\$STUB_LOG\"" > "$out"
else
  printf "%s\n" "echo \"install.sh args=[\$*] env=[\${FOREMAN_JOIN_TOKEN:-}]\" >> \"\$STUB_LOG\"" > "$out"
fi'
}

@test "enroll_box mints a join token and hands it to the box installer outside argv" {
  stub_box "TOKEN fj_minted_token_value"
  run enroll_box
  [ "$status" -eq 0 ]
  grep -qx 'install.sh args=\[\] env=\[fj_minted_token_value\]' "$STUB_LOG"
}

@test "enroll_box passes --token to a box installer that predates FOREMAN_JOIN_TOKEN" {
  export INSTALL_SH=old
  stub_box "TOKEN fj_minted_token_value"
  run enroll_box
  [ "$status" -eq 0 ]
  grep -qx 'install.sh args=\[--token fj_minted_token_value\] env=\[\]' "$STUB_LOG"
}

@test "enroll_box waits for a first sign-in when unattended" {
  stub_box "ERR no-user"
  run enroll_box
  [ "$status" -eq 0 ]
  [[ "$output" == *"hasn't signed in"* ]]
  [[ "$output" == *"FOREMAN_JOIN_TOKEN"* ]]
  run ! grep -q '^install.sh' "$STUB_LOG"
}

@test "enroll_box tries again on a terminal once the admin has signed in" {
  stub_box "ERR no-user" "TOKEN fj_second_try"
  # The box name's default, then Enter after signing in.
  answers "" ""
  run enroll_box
  [ "$status" -eq 0 ]
  [ "$(grep -c '^cp_eval mint' "$STUB_LOG")" -eq 2 ]
  grep -q 'env=\[fj_second_try\]' "$STUB_LOG"
}

@test "enroll_box stops on a box name Foreman refuses" {
  stub_box 'ERR invalid [box_name: {"has already been taken", []}]'
  run enroll_box
  [ "$status" -eq 1 ]
  [[ "$output" == *"has already been taken"* ]]
}

@test "enroll_box skips an enrolled host and one with no agent to install" {
  echo '{}' > "$AGENT_IDENTITY"
  run enroll_box
  [[ "$output" == *"already enrolled"* ]]
  rm "$AGENT_IDENTITY"
  stub_box "TOKEN fj_x"
  http_status() { echo 404; }
  run enroll_box
  [ "$status" -eq 0 ]
  [[ "$output" == *"no agent for linux-amd64"* ]]
  run ! grep -q '^cp_eval' "$STUB_LOG"
}

# -- the GitHub App -----------------------------------------------------------

@test "check_github_app reads what GitHub said about the app" {
  cp_eval() { echo "$CHECK_OUT"; }
  CHECK_OUT="GHCHECK ok foreman-dev" run check_github_app
  [ "$status" -eq 0 ]
  [[ "$output" == *"foreman-dev"* ]]
  CHECK_OUT="GHCHECK http 401" run check_github_app
  [ "$status" -eq 1 ]
  [[ "$output" == *"App ID"* ]]
  CHECK_OUT="GHCHECK client-id Iv1.other" run check_github_app
  [ "$status" -eq 1 ]
  [[ "$output" == *"Iv1.other"* ]]
  CHECK_OUT="GHCHECK error :nxdomain" run check_github_app
  [ "$status" -eq 2 ]
  [[ "$output" == *"couldn't check"* ]]
}

@test "configure_github says an app is configured, not that GitHub accepted it" {
  github_connected() { return 0; }
  run configure_github
  [ "$status" -eq 0 ]
  [[ "$output" == *"GitHub App is configured"* ]]
  [[ "$output" != *"GitHub is connected"* ]]
}

@test "configure_github checks by-hand credentials with GitHub" {
  github_connected() { return 0; }
  cp_eval() { echo "cp_eval" >> "$STUB_LOG"; echo "GHCHECK http 401"; }
  env_set "$ENV_FILE" FOREMAN_GITHUB_APP_ID=123456
  run configure_github
  [ "$status" -eq 0 ]
  grep -qx cp_eval "$STUB_LOG"
  [[ "$output" == *"401"* ]]
}

@test "the summary sends a rejected by-hand app back to the settings file, not to /setup" {
  GITHUB_PENDING=check run summary
  [[ "$output" == *"FOREMAN_GITHUB_APP_ID"* ]]
  [[ "$output" != *"$BASE_URL/setup"* ]]
  GITHUB_PENDING=manual run summary
  [[ "$output" == *"FOREMAN_GITHUB_"* ]]
  [[ "$output" != *"$BASE_URL/setup"* ]]
  GITHUB_PENDING=1 run summary
  [[ "$output" == *"$BASE_URL/setup"* ]]
}

@test "configure_github marks a rejected by-hand app for fixing in the settings file" {
  github_connected() { return 0; }
  cp_eval() { echo "GHCHECK http 401"; }
  env_set "$ENV_FILE" FOREMAN_GITHUB_APP_ID=123456
  GITHUB_PENDING=""
  configure_github >/dev/null 2>&1
  [ "$GITHUB_PENDING" = check ]
}
