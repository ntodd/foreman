#!/usr/bin/env bats

load helpers

setup() { setup_installer; }

@test "setup_token_from_logs takes the newest token" {
  run setup_token_from_logs < "$FIXTURES/boot.log"
  [ "$status" -eq 0 ]
  [ "$output" = newsetuptokennewsetuptokennewset ]
}

@test "setup_token_from_logs fails when there's no token" {
  run setup_token_from_logs < "$FIXTURES/boot-unregistered.log"
  [ "$status" -eq 1 ]
}

@test "bundled_agents_status passes when the image's agents registered" {
  run bundled_agents_status < "$FIXTURES/boot.log"
  [ "$status" -eq 0 ]
}

@test "bundled_agents_status reports why they weren't registered" {
  run bundled_agents_status < "$FIXTURES/boot-unregistered.log"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no agent release key configured"* ]]
}

@test "parse_mint returns the join token" {
  run parse_mint "$(printf '%s\n' '12:00:00.000 [info] noise' 'TOKEN fj_abcDEF123_-')"
  [ "$status" -eq 0 ]
  [ "$output" = fj_abcDEF123_- ]
}

@test "parse_mint tells the failures apart" {
  run parse_mint "ERR no-user"
  [ "$status" -eq 3 ]
  run parse_mint "ERR not-admin"
  [ "$status" -eq 4 ]
  run parse_mint 'ERR invalid [box_name: {"has invalid format", []}]'
  [ "$status" -eq 5 ]
  run parse_mint "** (RuntimeError) boom"
  [ "$status" -eq 1 ]
}

@test "box_name_from_hostname makes a valid box name" {
  [ "$(box_name_from_hostname Dev_Box.local)" = dev-box-local ]
  [ "$(box_name_from_hostname --x--)" = x ]
  long=$(printf 'a%.0s' $(seq 70))-
  name=$(box_name_from_hostname "$long")
  [ "${#name}" -le 63 ]
  valid_box_name "$name"
}

@test "valid_box_name follows Foreman's rule" {
  valid_box_name dev
  valid_box_name a
  valid_box_name dev-2
  run ! valid_box_name Dev
  run ! valid_box_name -dev
  run ! valid_box_name dev-
  run ! valid_box_name "dev box"
  run ! valid_box_name ""
}

@test "first_login takes the first admin" {
  [ "$(first_login "octocat, hubot")" = octocat ]
  [ "$(first_login octocat)" = octocat ]
}

@test "wait_healthy polls loopback /healthz until it answers" {
  export COUNT_FILE="$BATS_TEST_TMPDIR/count"
  echo 0 > "$COUNT_FILE"
  stub curl 'n=$(($(cat "$COUNT_FILE") + 1)); echo $n > "$COUNT_FILE"; [ $n -ge 3 ]'
  stub docker 'echo running'
  stub sleep 'true'
  run wait_healthy foreman 4100 30
  [ "$status" -eq 0 ]
  grep -q "^curl .*http://127.0.0.1:4100/healthz" "$STUB_LOG"
}

@test "wait_healthy gives up and points at the logs" {
  stub curl 'exit 7'
  stub docker 'echo running'
  stub sleep 'true'
  run wait_healthy foreman 4100 3
  [ "$status" -eq 1 ]
  [[ "$output" == *"docker logs foreman"* ]]
}

@test "wait_healthy stops early when the container exited" {
  stub curl 'exit 7'
  stub docker 'case "$1" in inspect) echo exited ;; logs) echo "** (RuntimeError) environment variable PHX_HOST is missing." ;; esac'
  stub sleep 'true'
  run wait_healthy foreman 4100 60
  [ "$status" -eq 1 ]
  [[ "$output" == *"PHX_HOST is missing"* ]]
  [ "$(grep -c '^curl' "$STUB_LOG")" -lt 5 ]
}

@test "expand_home expands ~/ to the invoking user's home, not root's" {
  unset SUDO_USER
  [ "$(expand_home "~/app.pem")" = "$HOME/app.pem" ]
  [ "$(expand_home /tmp/app.pem)" = /tmp/app.pem ]
  stub getent '[ "$1 $2" = "passwd nate" ] && echo "nate:x:1000:1000::/home/nate:/bin/zsh"'
  SUDO_USER=nate
  [ "$(expand_home "~/Downloads/app.pem")" = /home/nate/Downloads/app.pem ]
}
