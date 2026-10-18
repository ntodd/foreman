#!/usr/bin/env bats

load helpers

IMAGE=ghcr.io/ntodd/foreman:0.3.0

setup() {
  setup_installer
  export STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STATE"
  # A fake docker: the image exists locally once pulled, and a pull of a
  # ghcr.io image only works after a login.
  stub docker 'case "$1" in
  image) [ -e "$STATE/present" ] ;;
  pull)
    if [ -e "$STATE/logged-in" ] || [ -e "$STATE/public" ]; then touch "$STATE/present"; exit 0; fi
    echo "Error response from daemon: Head \"https://ghcr.io/v2/ntodd/foreman/manifests/0.3.0\": unauthorized" >&2; exit 1 ;;
  login) cat > "$STATE/login-stdin"; touch "$STATE/logged-in" ;;
  *) exit 1 ;;
esac'
}

@test "ensure_image does nothing when the image is already here" {
  touch "$STATE/present"
  run ensure_image "$IMAGE"
  [ "$status" -eq 0 ]
  run ! grep -q "^docker pull" "$STUB_LOG"
  run ! grep -q "^docker login" "$STUB_LOG"
}

@test "ensure_image pulls without logging in when it can" {
  touch "$STATE/public"
  run ensure_image "$IMAGE"
  [ "$status" -eq 0 ]
  run ! grep -q "^docker login" "$STUB_LOG"
}

@test "ensure_image logs root in with the token on stdin, then pulls" {
  export FOREMAN_GHCR_USER=octocat
  export FOREMAN_GHCR_TOKEN=not-a-real-token-value
  run ensure_image "$IMAGE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"classic"* ]]
  [[ "$output" != *not-a-real-token-value* ]]
  grep -q "^docker login ghcr.io -u octocat --password-stdin" "$STUB_LOG"
  [ "$(cat "$STATE/login-stdin")" = not-a-real-token-value ]
  [ -e "$STATE/present" ]
  run ! grep -q not-a-real-token-value "$STUB_LOG"
}

@test "ensure_image explains the token it needs when non-interactive" {
  run ensure_image "$IMAGE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"read:packages"* ]]
  [[ "$output" == *FOREMAN_GHCR_TOKEN* ]]
}

@test "ensure_image doesn't try GHCR credentials for another registry" {
  run ensure_image foreman-smoke:0.3.0
  [ "$status" -eq 1 ]
  run ! grep -q "^docker login" "$STUB_LOG"
}

@test "use_root_docker_config points docker at root's config whatever HOME is" {
  # sudo -E keeps the caller's HOME, where docker login would otherwise
  # write, and a later plain sudo docker compose pull wouldn't look.
  stub getent '[ "$1 $2" = "passwd 0" ] && echo "root:x:0:0:root:/root:/bin/bash"'
  HOME=/home/nate use_root_docker_config
  [ "$DOCKER_CONFIG" = /root/.docker ]
  stub getent 'exit 2'
  use_root_docker_config
  [ "$DOCKER_CONFIG" = /root/.docker ]
}

@test "ensure_image says where the login goes" {
  export DOCKER_CONFIG=/root/.docker
  run ensure_image "$IMAGE"
  [[ "$output" == *"/root/.docker/config.json"* ]]
}
