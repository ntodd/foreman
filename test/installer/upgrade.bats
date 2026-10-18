#!/usr/bin/env bats

load helpers

OLD=ghcr.io/ntodd/foreman:0.3.0
NEW=ghcr.io/ntodd/foreman:0.3.1

setup() {
  setup_installer
  mkdir -p "$FOREMAN_OPT" "$FOREMAN_ETC"
  echo FOREMAN_ENCRYPTION_KEY=k > "$FOREMAN_ETC/foreman.env"
  export STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STATE"
  # A fake docker. The foreman container exists when $RUNNING_IMAGE is
  # set: it runs that image, started by compose (project $PROJECT,
  # default foreman) from $COMPOSE_DIR. Every image is already here.
  stub docker 'case "$1" in
  run)
    # Writes the tarball named on the command line (a partial one, then
    # an error, with $TAR_FAILS).
    for a in "$@"; do case "$a" in /backup/*) echo data > "$BACKUP_DIR_ON_HOST/${a#/backup/}" ;; esac; done
    [ -z "${TAR_FAILS:-}" ] || { echo "tar: boom" >&2; exit 2; } ;;
  inspect)
    [ -n "${RUNNING_IMAGE:-}" ] || exit 1
    case "$*" in
      *Config.Image*) echo "$RUNNING_IMAGE" ;;
      *State.Running*) echo true ;;
      *working_dir*) echo "${COMPOSE_DIR:-}" ;;
      *compose.project*) echo "${PROJECT-foreman}" ;;
      *) echo "[]" ;;
    esac ;;
  image) exit 0 ;;
  stop) [ -z "${STOP_FAILS:-}" ] || { echo "Error: cannot stop container" >&2; exit 1; } ;;
  *) exit 0 ;;
esac'
  export BACKUP_DIR_ON_HOST="$FOREMAN_BACKUPS"
}

@test "image_version reads an X.Y.Z tag, and nothing else" {
  [ "$(image_version ghcr.io/ntodd/foreman:0.3.1)" = 0.3.1 ]
  [ "$(image_version foreman-smoke:v1.2.3)" = 1.2.3 ]
  [ -z "$(image_version localhost:5000/foreman)" ]
  [ -z "$(image_version ghcr.io/ntodd/foreman:latest)" ]
  [ -z "$(image_version ghcr.io/ntodd/foreman@sha256:abc)" ]
}

@test "version_cmp orders versions numerically" {
  [ "$(version_cmp 0.3.0 0.3.1)" = -1 ]
  [ "$(version_cmp 0.10.0 0.9.9)" = 1 ]
  [ "$(version_cmp 1.0.0 1.0.0)" = 0 ]
}

@test "confirm_image_change does nothing when the image stays the same" {
  run confirm_image_change "$OLD" "$OLD"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run ! grep -q '^docker' "$STUB_LOG"
}

@test "confirm_image_change does nothing on a first install" {
  run confirm_image_change "" "$NEW"
  [ "$status" -eq 0 ]
  run ! grep -q '^docker' "$STUB_LOG"
}

@test "an unattended upgrade needs FOREMAN_UPGRADE=yes" {
  run confirm_image_change "$OLD" "$NEW"
  [ "$status" -eq 1 ]
  [[ "$output" == *FOREMAN_UPGRADE=yes* ]]
  [[ "$output" == *upgrading.md* ]]
  run ! grep -q '^docker' "$STUB_LOG"
}

@test "an upgrade asks for a backup first, and only asks" {
  FOREMAN_UPGRADE=yes confirm_image_change "$OLD" "$NEW"
  [ "$BACKUP_FIRST" = 1 ]
  run ! grep -q '^docker' "$STUB_LOG"
}

@test "FOREMAN_BACKUP=no upgrades without a backup" {
  BACKUP_FIRST=""
  FOREMAN_UPGRADE=yes FOREMAN_BACKUP=no confirm_image_change "$OLD" "$NEW"
  [ -z "$BACKUP_FIRST" ]
}

@test "backup_data stops the control plane and saves the volume and settings, root only" {
  export RUNNING_IMAGE=$OLD
  snapshot_settings
  run backup_data "$NEW"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$FOREMAN_BACKUPS (root only): foreman-data."*".tgz, foreman.env."* ]]
  # docker stop, not compose: a manual install has no compose.yml in $OPT.
  grep -q '^docker stop foreman' "$STUB_LOG"
  run ! grep -q '^docker compose' "$STUB_LOG"
  grep -q "^docker run --rm .*foreman-data:/data:ro.*$NEW" "$STUB_LOG"
  [ "$(mode_of "$FOREMAN_BACKUPS")" = 700 ]
  env_copy=$(ls "$FOREMAN_BACKUPS"/foreman.env.*)
  [ "$(mode_of "$env_copy")" = 600 ]
  [ "$(cat "$env_copy")" = FOREMAN_ENCRYPTION_KEY=k ]
  tgz=$(ls "$FOREMAN_BACKUPS"/foreman-data.*.tgz)
  [ "$(mode_of "$tgz")" = 600 ]
}

@test "the backup keeps the settings from before this run, and the GitHub App key" {
  echo key > "$FOREMAN_ETC/github-app.pem"
  chmod 0400 "$FOREMAN_ETC/github-app.pem"
  snapshot_settings
  env_set "$FOREMAN_ETC/foreman.env" FOREMAN_AGENT_RELEASE_PUBLIC_KEY=new-release-key
  run backup_data "$NEW"
  [ "$status" -eq 0 ]
  [ "$(cat "$FOREMAN_BACKUPS"/foreman.env.*)" = FOREMAN_ENCRYPTION_KEY=k ]
  pem=$(ls "$FOREMAN_BACKUPS"/github-app.pem.*)
  [ "$(cat "$pem")" = key ]
  [ "$(mode_of "$pem")" = 600 ]
  [[ "$output" == *github-app.pem.* ]]
}

@test "a failed backup puts the settings back and starts the control plane again" {
  export RUNNING_IMAGE=$OLD TAR_FAILS=1
  snapshot_settings
  env_set "$FOREMAN_ETC/foreman.env" FOREMAN_AGENT_RELEASE_PUBLIC_KEY=new-release-key
  run backup_data "$NEW"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tar: boom"* ]]
  grep -q '^docker start foreman' "$STUB_LOG"
  [ "$(cat "$FOREMAN_ETC/foreman.env")" = FOREMAN_ENCRYPTION_KEY=k ]
  [ "$(mode_of "$FOREMAN_ETC/foreman.env")" = 600 ]
  run ls "$FOREMAN_BACKUPS"/foreman-data.*
  [ "$status" -ne 0 ]
}

@test "a failed docker stop puts the settings back before stopping" {
  export RUNNING_IMAGE=$OLD STOP_FAILS=1
  snapshot_settings
  env_set "$FOREMAN_ETC/foreman.env" FOREMAN_AGENT_RELEASE_PUBLIC_KEY=new-release-key
  run backup_data "$NEW"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot stop container"* ]] || false
  [[ "$output" == *"nothing changed"* ]] || false
  [ "$(cat "$FOREMAN_ETC/foreman.env")" = FOREMAN_ENCRYPTION_KEY=k ]
  run ! grep -q '^docker run' "$STUB_LOG"
}

@test "backup_data doesn't start a control plane that wasn't running" {
  export TAR_FAILS=1
  snapshot_settings
  run backup_data "$NEW"
  [ "$status" -eq 1 ]
  run ! grep -q '^docker st' "$STUB_LOG"
}

# -- which image a host runs now ------------------------------------------------

@test "choose_image takes over a manual install's image, so a downgrade is still refused" {
  # docs/setup/personal.md's manual install: compose in a checkout's
  # docker/ dir, no $OPT/.env.
  export RUNNING_IMAGE=foreman-smoke:9.9.9 COMPOSE_DIR=/root/foreman/docker
  FOREMAN_IMAGE=foreman-smoke:0.3.0 run choose_image
  [ "$status" -eq 1 ]
  [[ "$output" == *FOREMAN_DOWNGRADE=yes* ]]
  run ! grep -q '^docker pull' "$STUB_LOG"
}

@test "choose_image asks before upgrading a manual install, and backs it up" {
  export RUNNING_IMAGE=$OLD COMPOSE_DIR=/root/foreman/docker
  FOREMAN_IMAGE=$NEW run choose_image
  [ "$status" -eq 1 ]
  [[ "$output" == *FOREMAN_UPGRADE=yes* ]]
  FOREMAN_IMAGE=$NEW FOREMAN_UPGRADE=yes choose_image >/dev/null
  [ "$PINNED_IMAGE" = "$OLD" ]
  [ "$BACKUP_FIRST" = 1 ]
  ls "$FOREMAN_BACKUPS"/foreman.env.* >/dev/null
}

@test "choose_image refuses a foreman container compose didn't create before stopping it" {
  # docker run --name foreman, from before 0.3.0.
  export RUNNING_IMAGE=$OLD PROJECT=""
  FOREMAN_IMAGE=$NEW FOREMAN_UPGRADE=yes run choose_image
  [ "$status" -eq 1 ]
  [[ "$output" == *"docker rm -f foreman"* ]]
  run ! grep -qE '^docker (stop|pull)' "$STUB_LOG"
  [ ! -e "$FOREMAN_BACKUPS" ]
}

@test "choose_image keeps the image a previous run pinned when no version is given" {
  export RUNNING_IMAGE=$NEW
  echo "FOREMAN_IMAGE=$NEW" > "$FOREMAN_OPT/.env"
  choose_image >/dev/null
  [ "$PINNED_IMAGE" = "$NEW" ]
  [ "$IMAGE" = "$NEW" ]
  [ -z "$BACKUP_FIRST" ]
}

@test "choose_image pulls the image before anything is written" {
  stub docker 'case "$1" in
  image) exit 1 ;;
  pull) echo "manifest unknown" >&2; exit 1 ;;
  *) exit 1 ;;
esac'
  before=$(cat "$FOREMAN_ETC/foreman.env")
  FOREMAN_IMAGE=$NEW run choose_image
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't pull"* ]]
  [ "$(cat "$FOREMAN_ETC/foreman.env")" = "$before" ]
}

@test "old_compose_note points at a compose dir other than the installer's" {
  export RUNNING_IMAGE=$OLD COMPOSE_DIR=/root/foreman/docker
  run old_compose_note
  [[ "$output" == *"/root/foreman/docker/compose.yml"* ]]
  # After the recreate, from what was found before it.
  export COMPOSE_DIR=$FOREMAN_OPT
  run old_compose_note /root/foreman/docker
  [[ "$output" == *"/root/foreman/docker/compose.yml"* ]]
  export COMPOSE_DIR=$FOREMAN_OPT
  run old_compose_note
  [ -z "$output" ]
  unset RUNNING_IMAGE
  run old_compose_note
  [ -z "$output" ]
}

@test "a downgrade is refused unless FOREMAN_DOWNGRADE=yes" {
  FOREMAN_UPGRADE=yes run confirm_image_change "$NEW" "$OLD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"older"* ]]
  [[ "$output" == *FOREMAN_DOWNGRADE=yes* ]]
  run ! grep -q '^docker' "$STUB_LOG"
  FOREMAN_UPGRADE=yes FOREMAN_DOWNGRADE=yes FOREMAN_BACKUP=no run confirm_image_change "$NEW" "$OLD"
  [ "$status" -eq 0 ]
}

@test "the upgrade question is asked on a terminal, defaulting to yes" {
  unset FOREMAN_NONINTERACTIVE
  export FOREMAN_TTY="$BATS_TEST_TMPDIR/tty"
  printf '%s\n' "" n > "$FOREMAN_TTY"
  BACKUP_FIRST=""
  confirm_image_change "$OLD" "$NEW" 2>"$BATS_TEST_TMPDIR/prompts"
  [ -z "$BACKUP_FIRST" ]
  grep -q "Upgrade to $NEW now?" "$BATS_TEST_TMPDIR/prompts"
}

@test "choose_image refuses to go below the image the container runs, even when .env pins the target" {
  # Upgraded to 0.3.1 by a compose override or from another directory,
  # with .env still pinning 0.3.0.
  export RUNNING_IMAGE=$NEW
  echo "FOREMAN_IMAGE=$OLD" > "$FOREMAN_OPT/.env"
  FOREMAN_IMAGE=$OLD run choose_image
  [ "$status" -eq 1 ]
  [[ "$output" == *"older than $NEW"* ]] || false
  [[ "$output" == *FOREMAN_DOWNGRADE=yes* ]] || false
  run ! grep -qE '^docker (pull|stop)' "$STUB_LOG"
}

@test "choose_image goes by the higher of the pin and the container's image" {
  # .env pins 0.3.1, the container still runs 0.3.0 (a run that pinned it
  # and stopped before the recreate): going to 0.3.0 isn't a downgrade
  # from what runs, but it is from the pin.
  export RUNNING_IMAGE=$OLD
  echo "FOREMAN_IMAGE=$NEW" > "$FOREMAN_OPT/.env"
  FOREMAN_IMAGE=$OLD FOREMAN_UPGRADE=yes run choose_image
  [ "$status" -eq 1 ]
  [[ "$output" == *"older than $NEW"* ]] || false
  # And finishing that upgrade still asks, and backs up first.
  FOREMAN_IMAGE=$NEW run choose_image
  [ "$status" -eq 1 ]
  [[ "$output" == *FOREMAN_UPGRADE=yes* ]] || false
  FOREMAN_IMAGE=$NEW FOREMAN_UPGRADE=yes choose_image >/dev/null
  [ "$BACKUP_FIRST" = 1 ]
}

@test "choose_image asks when the container runs an image it can't read a version from" {
  export RUNNING_IMAGE=ghcr.io/ntodd/foreman@sha256:abc
  echo "FOREMAN_IMAGE=$OLD" > "$FOREMAN_OPT/.env"
  FOREMAN_IMAGE=$OLD run choose_image
  [ "$status" -eq 1 ]
  [[ "$output" == *"ghcr.io/ntodd/foreman@sha256:abc"* ]] || false
  [[ "$output" == *FOREMAN_UPGRADE=yes* ]] || false
  FOREMAN_IMAGE=$OLD FOREMAN_UPGRADE=yes FOREMAN_BACKUP=no run choose_image
  [ "$status" -eq 0 ]
}

@test "choose_image asks nothing when the pin and the container agree with the target" {
  export RUNNING_IMAGE=$NEW
  echo "FOREMAN_IMAGE=$NEW" > "$FOREMAN_OPT/.env"
  FOREMAN_IMAGE=$NEW run choose_image
  [ "$status" -eq 0 ]
  [[ "$output" != *"moves the control plane"* ]] || false
}
