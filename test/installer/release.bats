#!/usr/bin/env bats

load helpers

setup() { setup_installer; }

@test "is_placeholder spots an unrendered value" {
  is_placeholder __FOREMAN_VERSION__
  run ! is_placeholder 0.3.0
  run ! is_placeholder ""
}

@test "resolve_image fails from a checkout with no version" {
  run resolve_image ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"--version"* ]]
}

@test "resolve_image builds the tag from --version" {
  FOREMAN_VERSION=v0.4.0
  [ "$(resolve_image "")" = ghcr.io/ntodd/foreman:0.4.0 ]
}

@test "resolve_image takes --image over everything" {
  FOREMAN_IMAGE=foreman-smoke:0.3.0 FOREMAN_VERSION=0.4.0
  [ "$(resolve_image ghcr.io/ntodd/foreman:0.2.0)" = foreman-smoke:0.3.0 ]
}

@test "resolve_image uses the release it was rendered for" {
  RELEASE_VERSION=0.3.0 RELEASE_IMAGE=ghcr.io/someone/foreman
  [ "$(resolve_image ghcr.io/ntodd/foreman:0.2.0)" = ghcr.io/someone/foreman:0.3.0 ]
}

@test "resolve_image keeps the pinned image on a re-run from a checkout" {
  [ "$(resolve_image ghcr.io/ntodd/foreman:0.3.0)" = ghcr.io/ntodd/foreman:0.3.0 ]
}

@test "resolve_image refuses a malformed version" {
  FOREMAN_VERSION="0.3.0; rm -rf /"
  run resolve_image ""
  [ "$status" -eq 1 ]
}

@test "resolve_public_key prefers the flag, then the release, then the settings file" {
  [ "$(FOREMAN_AGENT_RELEASE_PUBLIC_KEY=flag resolve_public_key file)" = flag ]
  RELEASE_PUBLIC_KEY=baked
  [ "$(resolve_public_key file)" = baked ]
  RELEASE_PUBLIC_KEY=__FOREMAN_RELEASE_PUBLIC_KEY__
  [ "$(resolve_public_key file)" = file ]
}

@test "resolve_public_key fails non-interactive with nothing to go on" {
  run resolve_public_key ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"FOREMAN_RELEASE_PUBLIC_KEY"* ]]
}

@test "render-control-plane-installer bakes in the version, image and key" {
  out="$BATS_TEST_TMPDIR/install-control-plane.sh"
  key="AAAA+BBBB/CCCC=="
  "$BATS_TEST_DIRNAME/../../scripts/render-control-plane-installer.sh" 0.3.0 ghcr.io/ntodd/foreman "$key" > "$out"
  run ! grep -Eq '__FOREMAN_(VERSION|IMAGE|RELEASE_PUBLIC_KEY)__' "$out"
  # shellcheck disable=SC1090
  source "$out"
  [ "$RELEASE_VERSION" = 0.3.0 ]
  [ "$RELEASE_IMAGE" = ghcr.io/ntodd/foreman ]
  [ "$RELEASE_PUBLIC_KEY" = "$key" ]
  [ "$(resolve_image "")" = ghcr.io/ntodd/foreman:0.3.0 ]
}

@test "render-control-plane-installer refuses an empty key or a bad version" {
  run "$BATS_TEST_DIRNAME/../../scripts/render-control-plane-installer.sh" 0.3.0 ghcr.io/ntodd/foreman ""
  [ "$status" -ne 0 ]
  run "$BATS_TEST_DIRNAME/../../scripts/render-control-plane-installer.sh" 0.3 ghcr.io/ntodd/foreman key
  [ "$status" -ne 0 ]
}

@test "render-control-plane-installer checks whole values, not line by line" {
  render="$BATS_TEST_DIRNAME/../../scripts/render-control-plane-installer.sh"
  run "$render" 0.3.0 ghcr.io/ntodd/foreman "$(printf 'AAAA\nBB|BB')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"isn't base64"* ]]
  run "$render" "$(printf '0.3.0\nx')" ghcr.io/ntodd/foreman AAAA
  [ "$status" -ne 0 ]
  [[ "$output" == *"isn't X.Y.Z"* ]]
  run "$render" 0.3.0 "$(printf 'ghcr.io/ntodd/foreman\nx|y')" AAAA
  [ "$status" -ne 0 ]
  [[ "$output" == *"isn't an image repository"* ]]
}

@test "render-control-plane-installer checks characters the same way in any locale" {
  render="$BATS_TEST_DIRNAME/../../scripts/render-control-plane-installer.sh"
  # In a UTF-8 locale, [a-z] can match capitals and accented letters.
  LC_ALL=en_US.UTF-8 run "$render" 0.3.0 ghcr.io/ntodd/foreMan AAAA
  [ "$status" -ne 0 ]
  LC_ALL=en_US.UTF-8 run "$render" 0.3.0 "ghcr.io/ntodd/forem$(printf '\303\251')" AAAA
  [ "$status" -ne 0 ]
}

# -- which release is the latest -----------------------------------------------

latest() { "$BATS_TEST_DIRNAME/../../scripts/release-is-latest.sh" "$@"; }

@test "release-is-latest says true for a tag above every published release" {
  run latest v0.4.0 <<<"$(printf '%s\n' v0.3.1 v0.3.0)"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
}

@test "release-is-latest says false for a patch on an older line" {
  run latest v0.3.2 <<<"$(printf '%s\n' v0.4.0 v0.3.1)"
  [ "$status" -eq 0 ]
  [ "$output" = false ]
}

@test "release-is-latest goes only by published releases, so a failed release's tag doesn't count" {
  # v0.4.0 was tagged but its workflow failed: it isn't in the list
  # gh release list gives, so v0.3.1 is the latest.
  run latest v0.3.1 <<<"$(printf '%s\n' v0.3.0 v0.2.0)"
  [ "$output" = true ]
}

@test "release-is-latest orders versions numerically and ignores anything but vX.Y.Z" {
  run latest v0.10.0 <<<"$(printf '%s\n' v0.9.9 v0.9.10)"
  [ "$output" = true ]
  run latest v0.9.10 <<<"$(printf '%s\n' v0.10.0)"
  [ "$output" = false ]
  run latest v0.4.0 <<<"$(printf '%s\n' v0.5.0-rc.1 latest "" v1)"
  [ "$output" = true ]
}

@test "release-is-latest says true for the first release, and for a re-run of the latest" {
  run latest v0.1.0 </dev/null
  [ "$output" = true ]
  run latest v0.4.0 <<<"$(printf '%s\n' v0.4.0 v0.3.0)"
  [ "$output" = true ]
}

@test "release-is-latest refuses a tag that isn't vX.Y.Z" {
  run latest 0.4.0 </dev/null
  [ "$status" -ne 0 ]
  run latest v0.4.0-rc.1 </dev/null
  [ "$status" -ne 0 ]
  run latest </dev/null
  [ "$status" -ne 0 ]
}

@test "the release workflow decides latest once, from published releases, for the images and the release" {
  wf="$BATS_TEST_DIRNAME/../../.github/workflows/release.yml"
  [ "$(grep -c 'scripts/release-is-latest.sh' "$wf")" -eq 1 ]
  grep -q 'gh release list .*--exclude-drafts --exclude-pre-releases' "$wf"
  grep -q 'needs.manifest.outputs.latest' "$wf"
  grep -q 'gh release create .*--latest="\$LATEST"' "$wf"
  run ! grep -q "git tag -l 'v\*.\*.\*' | .*tail -n 1" "$wf"
  run ! grep -q 'matching-refs/tags' "$wf"
}
