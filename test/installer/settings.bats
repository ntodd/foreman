#!/usr/bin/env bats

load helpers

setup() {
  setup_installer
  ENV_FILE="$FOREMAN_ETC/foreman.env"
}

@test "env_set creates a 0600 file in a 0700 directory, values raw" {
  env_set "$ENV_FILE" PHX_HOST=dev.example.ts.net 'FOREMAN_X=a $b "c" d=e'
  [ "$(mode_of "$FOREMAN_ETC")" = 700 ]
  [ "$(mode_of "$ENV_FILE")" = 600 ]
  grep -qx 'PHX_HOST=dev.example.ts.net' "$ENV_FILE"
  grep -qx 'FOREMAN_X=a $b "c" d=e' "$ENV_FILE"
}

@test "env_set replaces only the keys it's given and keeps everything else" {
  mkdir -p "$FOREMAN_ETC"
  printf '%s\n' '# mine' 'A=1' 'PHX_HOST=old' 'B=2' > "$ENV_FILE"
  env_set "$ENV_FILE" PHX_HOST=new C=3
  [ "$(cat "$ENV_FILE")" = "$(printf '%s\n' '# mine' 'A=1' 'PHX_HOST=new' 'B=2' 'C=3')" ]
}

@test "env_set swaps the file in atomically and leaves no temp files" {
  env_set "$ENV_FILE" A=1
  before=$(inode_of "$ENV_FILE")
  env_set "$ENV_FILE" A=2
  [ "$(inode_of "$ENV_FILE")" != "$before" ]
  [ "$(ls -A "$FOREMAN_ETC")" = foreman.env ]
}

@test "env_set refuses a value with a newline" {
  run env_set "$ENV_FILE" "A=$(printf 'x\ny')"
  [ "$status" -eq 1 ]
  [ ! -e "$ENV_FILE" ]
}

@test "env_set never replaces an existing secret" {
  env_set "$ENV_FILE" SECRET_KEY_BASE=keep FOREMAN_ENCRYPTION_KEY=keep2
  run env_set "$ENV_FILE" FOREMAN_ENCRYPTION_KEY=other
  [ "$status" -eq 1 ]
  [[ "$output" == *"FOREMAN_ENCRYPTION_KEY"* ]]
  grep -qx FOREMAN_ENCRYPTION_KEY=keep2 "$ENV_FILE"
  # Writing the same value is fine.
  env_set "$ENV_FILE" SECRET_KEY_BASE=keep
}

@test "env_get reads the last value, = and all, and fails for a missing key" {
  mkdir -p "$FOREMAN_ETC"
  printf '%s\n' 'A=1' 'K=abc==' 'A=2' > "$ENV_FILE"
  [ "$(env_get "$ENV_FILE" A)" = 2 ]
  [ "$(env_get "$ENV_FILE" K)" = abc== ]
  run env_get "$ENV_FILE" MISSING
  [ "$status" -eq 1 ]
  run env_get "$FOREMAN_ETC/nope.env" A
  [ "$status" -eq 1 ]
}

@test "ensure_secrets generates both secrets on a new file" {
  ensure_secrets "$ENV_FILE"
  skb=$(env_get "$ENV_FILE" SECRET_KEY_BASE)
  key=$(env_get "$ENV_FILE" FOREMAN_ENCRYPTION_KEY)
  [ "${#skb}" -eq 64 ]
  [ "$(printf '%s' "$key" | openssl base64 -d -A | wc -c | tr -d ' ')" -eq 32 ]
  [ "$(mode_of "$ENV_FILE")" = 600 ]
}

@test "ensure_secrets keeps existing secrets and only adds a missing one" {
  mkdir -p "$FOREMAN_ETC"
  printf '%s\n' 'FOREMAN_ENCRYPTION_KEY=existing-key' 'PHX_HOST=h' > "$ENV_FILE"
  ensure_secrets "$ENV_FILE"
  [ "$(env_get "$ENV_FILE" FOREMAN_ENCRYPTION_KEY)" = existing-key ]
  skb=$(env_get "$ENV_FILE" SECRET_KEY_BASE)
  [ -n "$skb" ]
  ensure_secrets "$ENV_FILE"
  [ "$(env_get "$ENV_FILE" SECRET_KEY_BASE)" = "$skb" ]
  [ "$(grep -c '^SECRET_KEY_BASE=' "$ENV_FILE")" -eq 1 ]
}

@test "base_url_for leaves 443 out of the URL" {
  [ "$(base_url_for dev.example.ts.net 443)" = https://dev.example.ts.net ]
  [ "$(base_url_for dev.example.ts.net 8443)" = https://dev.example.ts.net:8443 ]
}

@test "merge_origins adds an origin once and keeps the others" {
  [ "$(merge_origins "" https://h:8443)" = https://h:8443 ]
  [ "$(merge_origins https://a https://h:8443)" = https://a,https://h:8443 ]
  [ "$(merge_origins "https://a, https://h:8443" https://h:8443)" = "https://a, https://h:8443" ]
}

@test "write_host_settings on 8443 sets the base URL and the extra origin" {
  write_host_settings "$ENV_FILE" dev.example.ts.net 8443
  [ "$(env_get "$ENV_FILE" PHX_HOST)" = dev.example.ts.net ]
  [ "$(env_get "$ENV_FILE" FOREMAN_BASE_URL)" = https://dev.example.ts.net:8443 ]
  [ "$(env_get "$ENV_FILE" FOREMAN_EXTRA_ORIGINS)" = https://dev.example.ts.net:8443 ]
  [ "$(env_get "$ENV_FILE" FOREMAN_LISTEN_IP)" = 0.0.0.0 ]
}

@test "write_host_settings on 443 needs no extra origin" {
  write_host_settings "$ENV_FILE" dev.example.ts.net 443
  [ "$(env_get "$ENV_FILE" FOREMAN_BASE_URL)" = https://dev.example.ts.net ]
  run env_get "$ENV_FILE" FOREMAN_EXTRA_ORIGINS
  [ "$status" -eq 1 ]
}

@test "write_host_settings keeps origins the operator added" {
  mkdir -p "$FOREMAN_ETC"
  echo 'FOREMAN_EXTRA_ORIGINS=https://other.example' > "$ENV_FILE"
  write_host_settings "$ENV_FILE" dev.example.ts.net 8443
  write_host_settings "$ENV_FILE" dev.example.ts.net 8443
  [ "$(env_get "$ENV_FILE" FOREMAN_EXTRA_ORIGINS)" = https://other.example,https://dev.example.ts.net:8443 ]
}

@test "render_compose publishes on loopback and reads the settings file raw" {
  run render_compose foreman 0
  [ "$status" -eq 0 ]
  [[ "$output" == *'image: ${FOREMAN_IMAGE:?'* ]]
  [[ "$output" == *'container_name: foreman'* ]]
  [[ "$output" == *"path: $FOREMAN_ETC/foreman.env"* ]]
  [[ "$output" == *'format: raw'* ]]
  [[ "$output" == *'"127.0.0.1:${FOREMAN_PORT:?'*':4000"'* ]]
  [[ "$output" == *'name: foreman-data'* ]]
  [[ "$output" != *github-app.pem* ]]
}

@test "render_compose mounts the GitHub App key when asked" {
  run render_compose foreman 1
  [[ "$output" == *"$FOREMAN_ETC/github-app.pem:/run/secrets/github-app.pem:ro"* ]]
}

@test "write_compose keeps a copy of a compose file it didn't write" {
  mkdir -p "$FOREMAN_OPT"
  echo "services: {mine: {}}" > "$FOREMAN_OPT/compose.yml"
  write_compose
  grep -q "written by install-control-plane.sh" "$FOREMAN_OPT/compose.yml"
  backup=$(ls "$FOREMAN_OPT"/compose.yml.before-installer.*)
  [ "$(cat "$backup")" = "services: {mine: {}}" ]
  write_compose
  [ "$(ls "$FOREMAN_OPT" | grep -c before-installer)" -eq 1 ]
}

@test "refuse_postgres stops on a Postgres deployment's settings" {
  mkdir -p "$FOREMAN_ETC"
  echo 'DATABASE_URL=ecto://u:p@db/foreman' > "$ENV_FILE"
  run refuse_postgres "$ENV_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"team.md"* ]]
  echo 'DATABASE_URL=' > "$ENV_FILE"
  refuse_postgres "$ENV_FILE"
  refuse_postgres "$FOREMAN_ETC/missing.env"
}

# A fake docker for the secrets guard: the foreman-data volume exists when
# $STATE/volume does, and the foreman container runs with the environment
# in $STATE/container-env when that file exists.
secrets_docker() {
  export STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STATE"
  stub docker 'case "$1 $2" in
  "volume inspect") [ -e "$STATE/volume" ] ;;
  "inspect -f") [ -e "$STATE/container-env" ] && cat "$STATE/container-env" ;;
  *) exit 1 ;;
esac'
}

@test "settle_secrets generates both secrets on a fresh host" {
  secrets_docker
  run settle_secrets "$ENV_FILE"
  [ "$status" -eq 0 ]
  [ -n "$(env_get "$ENV_FILE" FOREMAN_ENCRYPTION_KEY)" ]
  [ -n "$(env_get "$ENV_FILE" SECRET_KEY_BASE)" ]
}

@test "settle_secrets won't make a new encryption key beside existing data when the file lacks one" {
  secrets_docker
  touch "$STATE/volume"
  mkdir -p "$FOREMAN_ETC"
  printf '%s\n' PHX_HOST=x 'FOREMAN_ENCRYPTION_KEY=' > "$ENV_FILE"
  run settle_secrets "$ENV_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"foreman-data"* ]]
  [[ "$output" == *FOREMAN_NEW_SECRETS* ]]
  [ -z "$(env_get "$ENV_FILE" FOREMAN_ENCRYPTION_KEY)" ]
  run env_get "$ENV_FILE" SECRET_KEY_BASE
  [ "$status" -eq 1 ]
}

@test "settle_secrets won't make new secrets beside existing data when the file is missing" {
  secrets_docker
  touch "$STATE/volume"
  run settle_secrets "$ENV_FILE"
  [ "$status" -eq 1 ]
  [ ! -e "$ENV_FILE" ]
}

@test "settle_secrets makes a new key beside existing data only with FOREMAN_NEW_SECRETS=yes" {
  secrets_docker
  touch "$STATE/volume"
  mkdir -p "$FOREMAN_ETC"
  echo PHX_HOST=x > "$ENV_FILE"
  FOREMAN_NEW_SECRETS=yes run settle_secrets "$ENV_FILE"
  [ "$status" -eq 0 ]
  [ -n "$(env_get "$ENV_FILE" FOREMAN_ENCRYPTION_KEY)" ]
}

@test "settle_secrets adopts the running container's secrets when the file lacks them, without printing them" {
  secrets_docker
  touch "$STATE/volume"
  printf '%s\n' PATH=/usr/bin FOREMAN_ENCRYPTION_KEY=live-key-value= SECRET_KEY_BASE=live-skb-value > "$STATE/container-env"
  mkdir -p "$FOREMAN_ETC"
  echo PHX_HOST=x > "$ENV_FILE"
  run settle_secrets "$ENV_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" != *live-key-value* ]]
  [[ "$output" != *live-skb-value* ]]
  [ "$(env_get "$ENV_FILE" FOREMAN_ENCRYPTION_KEY)" = live-key-value= ]
  [ "$(env_get "$ENV_FILE" SECRET_KEY_BASE)" = live-skb-value ]
}

@test "settle_secrets refuses a file whose encryption key differs from the running container's" {
  secrets_docker
  touch "$STATE/volume"
  echo FOREMAN_ENCRYPTION_KEY=live-key > "$STATE/container-env"
  mkdir -p "$FOREMAN_ETC"
  printf '%s\n' FOREMAN_ENCRYPTION_KEY=file-key SECRET_KEY_BASE=s > "$ENV_FILE"
  run settle_secrets "$ENV_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"different FOREMAN_ENCRYPTION_KEY"* ]]
  [[ "$output" != *live-key* ]]
  [[ "$output" != *file-key* ]]
  [ "$(env_get "$ENV_FILE" FOREMAN_ENCRYPTION_KEY)" = file-key ]
}

@test "settle_secrets keeps matching secrets as they are" {
  secrets_docker
  touch "$STATE/volume"
  printf '%s\n' FOREMAN_ENCRYPTION_KEY=k SECRET_KEY_BASE=other > "$STATE/container-env"
  mkdir -p "$FOREMAN_ETC"
  printf '%s\n' FOREMAN_ENCRYPTION_KEY=k SECRET_KEY_BASE=s > "$ENV_FILE"
  before=$(cat "$ENV_FILE")
  run settle_secrets "$ENV_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"keeping"* ]]
  [ "$(cat "$ENV_FILE")" = "$before" ]
}

# A settings file from a run that served Foreman at OLD_BASE.
old_settings() {
  stub docker 'exit 1'
  mkdir -p "$FOREMAN_ETC"
  printf '%s\n' SECRET_KEY_BASE=s FOREMAN_ENCRYPTION_KEY=k FOREMAN_ADMINS=octocat \
    FOREMAN_AGENT_RELEASE_PUBLIC_KEY=pk "FOREMAN_BASE_URL=$1" ${2:+"FOREMAN_EXTRA_ORIGINS=$2"} > "$ENV_FILE"
}

@test "write_settings warns that a changed serve port leaves the old URL serving, for boxes that use it" {
  old_settings https://dev.osiris-delta.ts.net:8443 https://dev.osiris-delta.ts.net:8443
  # 8443 still proxies to Foreman's loopback port.
  SERVE_JSON=$(cat "$FIXTURES/serve-foreman-8443.json")
  TS_HOST=dev.osiris-delta.ts.net HOST_PORT=4100 HTTPS_PORT=9443 BASE_URL=https://dev.osiris-delta.ts.net:9443
  run write_settings
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed from https://dev.osiris-delta.ts.net:8443 to https://dev.osiris-delta.ts.net:9443"* ]] || false
  [[ "$output" == *"tailscale serve --https=8443 off"* ]] || false
  [[ "$output" == *"Boxes keep the URL"* ]] || false
  [ "$(env_get "$ENV_FILE" FOREMAN_BASE_URL)" = https://dev.osiris-delta.ts.net:9443 ]
  # Boxes on the old URL still reach Foreman, so its origin stays allowed.
  [ "$(env_get "$ENV_FILE" FOREMAN_EXTRA_ORIGINS)" = https://dev.osiris-delta.ts.net:8443,https://dev.osiris-delta.ts.net:9443 ]
}

@test "write_settings doesn't tell you to unserve another app that has the old port" {
  # A rebuilt host: foreman.env says 443, but 443 now proxies (with
  # Funnel) to another app, so Foreman moves to 8443.
  old_settings https://dev.osiris-delta.ts.net
  SERVE_JSON=$(cat "$FIXTURES/serve-funnel-443.json")
  TS_HOST=dev.osiris-delta.ts.net HOST_PORT=4001 HTTPS_PORT=8443 BASE_URL=https://dev.osiris-delta.ts.net:8443
  run write_settings
  [ "$status" -eq 0 ]
  [[ "$output" != *"serve --https=443 off"* ]] || false
  [[ "$output" != *"still serves Foreman"* ]] || false
  [[ "$output" == *"https://dev.osiris-delta.ts.net no longer reaches Foreman"* ]] || false
  [[ "$output" == *"http://127.0.0.1:4444"* ]] || false
  [[ "$output" == *"FOREMAN_URL"* ]] || false
  [ "$(env_get "$ENV_FILE" FOREMAN_EXTRA_ORIGINS)" = https://dev.osiris-delta.ts.net:8443 ]
}

@test "write_settings drops the old origin when another app took the old port" {
  # Foreman was on 8443; 8443 now serves 127.0.0.1:4100, which isn't
  # Foreman's loopback port any more.
  old_settings https://dev.osiris-delta.ts.net:8443 https://other.example,https://dev.osiris-delta.ts.net:8443
  SERVE_JSON=$(cat "$FIXTURES/serve-foreman-8443.json")
  TS_HOST=dev.osiris-delta.ts.net HOST_PORT=4200 HTTPS_PORT=10000 BASE_URL=https://dev.osiris-delta.ts.net:10000
  run write_settings
  [ "$status" -eq 0 ]
  [[ "$output" != *"serve --https=8443 off"* ]] || false
  [[ "$output" == *"no longer reaches Foreman"* ]] || false
  [ "$(env_get "$ENV_FILE" FOREMAN_EXTRA_ORIGINS)" = https://other.example,https://dev.osiris-delta.ts.net:10000 ]
}

@test "write_settings says when nothing serves the old port any more" {
  old_settings https://dev.osiris-delta.ts.net:9443 https://dev.osiris-delta.ts.net:9443
  SERVE_JSON='{}'
  TS_HOST=dev.osiris-delta.ts.net HOST_PORT=4100 HTTPS_PORT=443 BASE_URL=https://dev.osiris-delta.ts.net
  run write_settings
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://dev.osiris-delta.ts.net:9443 no longer reaches Foreman (nothing serves it)"* ]] || false
  [[ "$output" != *"serve --https=9443 off"* ]] || false
  run env_get "$ENV_FILE" FOREMAN_EXTRA_ORIGINS
  [ -z "$output" ]
}

@test "drop_origin removes one origin from a comma list" {
  [ "$(drop_origin "https://a,https://h:8443" https://h:8443)" = https://a ]
  [ "$(drop_origin "https://a, https://h:8443 ,https://b" https://h:8443)" = https://a,https://b ]
  [ "$(drop_origin https://h:8443 https://h:8443)" = "" ]
  [ "$(drop_origin https://a https://h:8443)" = https://a ]
}

@test "an interrupted env_set leaves no temp file beside the settings file" {
  env_set "$ENV_FILE" A=1
  # Killed after the new file is written, before it's moved over the old.
  run bash -c 'source "$1"; set -euo pipefail; on_exit_cleanup; mv() { kill -TERM $$; sleep 1; }; env_set "$2" A=2' _ "$INSTALLER" "$ENV_FILE"
  [ "$status" -ne 0 ]
  [ "$(ls -A "$FOREMAN_ETC")" = foreman.env ]
  [ "$(cat "$ENV_FILE")" = A=1 ]
}

@test "write_settings doesn't tell you to unserve the port Foreman stays on" {
  # Same port, spelled differently: https://HOST:8443/ is now https://HOST:8443.
  old_settings https://dev.osiris-delta.ts.net:8443/
  SERVE_JSON=$(cat "$FIXTURES/serve-foreman-8443.json")
  TS_HOST=dev.osiris-delta.ts.net HOST_PORT=4100 HTTPS_PORT=8443 BASE_URL=https://dev.osiris-delta.ts.net:8443
  run write_settings
  [ "$status" -eq 0 ]
  [[ "$output" != *"serve --https=8443 off"* ]] || false
  [[ "$output" != *"no longer reaches Foreman"* ]] || false
}

# A settings file with both secrets and another setting, and a copy of it.
secrets_file() {
  mkdir -p "$FOREMAN_ETC"
  printf '%s\n' '# mine' SECRET_KEY_BASE=skb-value FOREMAN_ENCRYPTION_KEY=enc-key-value A=1 > "$ENV_FILE"
  cp "$ENV_FILE" "$BATS_TEST_TMPDIR/before.env"
}

# From here on in the test, a write fails the way it does on a full
# disk: anything that would write the encryption key's value fails (or
# with PRINTF_STATUS=0 quietly comes up short), having written what came
# before it. Everything else goes through.
disk_fills_up() {
  printf() {
    local a
    for a in "$@"; do
      if [[ "$a" == *enc-key-value* ]]; then
        builtin printf '%s' "${a%%enc-key-value*}"
        return "${PRINTF_STATUS:-1}"
      fi
    done
    builtin printf "$@"
  }
}

@test "env_set leaves the settings file alone when a write fails" {
  secrets_file
  disk_fills_up
  run env_set "$ENV_FILE" A=2 B=3
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't write $ENV_FILE"* ]] || false
  [[ "$output" != *enc-key-value* ]] || false
  cmp "$BATS_TEST_TMPDIR/before.env" "$ENV_FILE"
  [ "$(ls -A "$FOREMAN_ETC")" = foreman.env ]
}

@test "env_set leaves the settings file alone when a write comes up short without an error" {
  secrets_file
  disk_fills_up
  PRINTF_STATUS=0 run env_set "$ENV_FILE" A=2
  [ "$status" -eq 1 ]
  [[ "$output" != *enc-key-value* ]] || false
  cmp "$BATS_TEST_TMPDIR/before.env" "$ENV_FILE"
  [ "$(ls -A "$FOREMAN_ETC")" = foreman.env ]
}

@test "env_set fails in a condition too, where errexit is off" {
  secrets_file
  disk_fills_up
  run bash -c 'source "$1"; '"$(declare -f printf)"'; if env_set "$2" A=2; then echo moved; fi' _ "$INSTALLER" "$ENV_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" != *moved* ]] || false
  cmp "$BATS_TEST_TMPDIR/before.env" "$ENV_FILE"
}

@test "env_file_intact wants every old key, the new values and the secrets as they were" {
  secrets_file
  new="$BATS_TEST_TMPDIR/new.env"
  printf '%s\n' '# mine' SECRET_KEY_BASE=skb-value FOREMAN_ENCRYPTION_KEY=enc-key-value A=2 B=3 > "$new"
  env_file_intact "$ENV_FILE" "$new" A=2 B=3
  # A key from the old file is missing.
  grep -v '^SECRET_KEY_BASE=' "$new" > "$new.1"
  run ! env_file_intact "$ENV_FILE" "$new.1" A=2 B=3
  # A new value didn't make it.
  sed 's/^B=3$/B=/' "$new" > "$new.2"
  run ! env_file_intact "$ENV_FILE" "$new.2" A=2 B=3
  # A secret changed.
  sed 's/^FOREMAN_ENCRYPTION_KEY=.*/FOREMAN_ENCRYPTION_KEY=enc-key-v/' "$new" > "$new.3"
  run ! env_file_intact "$ENV_FILE" "$new.3" A=2 B=3
  # A file that doesn't exist yet has no keys to keep.
  env_file_intact "$FOREMAN_ETC/none.env" "$new" A=2
}

@test "write_compose leaves compose.yml alone when the write fails" {
  write_compose
  cp "$FOREMAN_OPT/compose.yml" "$BATS_TEST_TMPDIR/compose.before"
  printf() {
    if [[ "$*" == *foreman-data* ]]; then builtin printf '%s' "${*%%foreman-data*}"; return 1; fi
    builtin printf "$@"
  }
  run write_compose
  [ "$status" -eq 1 ]
  cmp "$BATS_TEST_TMPDIR/compose.before" "$FOREMAN_OPT/compose.yml"
  [ "$(ls -A "$FOREMAN_OPT")" = compose.yml ]
}

@test "snapshot_settings fails when the copy doesn't match the settings file" {
  secrets_file
  cmp() { return 1; }
  run snapshot_settings
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't back up"* ]] || false
}
