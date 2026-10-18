#!/usr/bin/env bats
# What the installer prints: plain lines that fit a terminal.

load helpers

setup() {
  setup_installer
  # Real paths, not the test's temp dir, so widths are what users see.
  ETC=/etc/foreman OPT=/opt/foreman BACKUPS=/var/backups/foreman
  stub docker 'exit 1'
}

widest() { awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }'; }

@test "explain wraps long lines from arguments at 80 columns" {
  run explain "$(printf 'word %.0s' $(seq 40))"
  [ "${#lines[@]}" -gt 1 ]
  [ "$(widest <<<"$output")" -le 80 ]
}

@test "explain leaves short lines and indentation alone" {
  run explain "short line" "  indented"
  [ "${lines[0]}" = "   short line" ]
  [ "${lines[1]}" = "     indented" ]
}

@test "the upgrade explanation fits in 80 columns with real image names" {
  FOREMAN_UPGRADE=yes FOREMAN_BACKUP=no run confirm_image_change \
    ghcr.io/ntodd/foreman:0.3.0 ghcr.io/ntodd/foreman:0.3.1
  [ "$status" -eq 0 ]
  [ "$(grep '^   ' <<<"$output" | widest)" -le 80 ]
}

@test "the summary fits in 80 columns" {
  BASE_URL=https://dev.osiris-delta.ts.net:8443
  GITHUB_PENDING=check TAILSCALE_PENDING=1 BOX_PENDING=1 run summary
  [ "$(widest <<<"$output")" -le 80 ]
  GITHUB_PENDING=manual run summary
  [ "$(widest <<<"$output")" -le 80 ]
}

@test "the tagged-host notes fit in 80 columns, apart from the policy lines" {
  run policy_snippet 8443 tag:server,tag:foreman,tag:prod-east
  [ "$(grep -v '"src"' <<<"$output" | widest)" -le 80 ]
  run tagged_host_note tag:server,tag:foreman,tag:prod-east 8443
  [ "$(grep -v '"src"' <<<"$output" | widest)" -le 80 ]
}

@test "the docs fetch the installer from the newest release, not one pinned to a tag" {
  root="$BATS_TEST_DIRNAME/../.."
  # 0.3.0 has no installer attached; gh with no tag takes the latest.
  run grep -rnE 'release download v?[0-9X]+\.[0-9Y]+\.[0-9Z]+.*install-control-plane' \
    "$root/README.md" "$root/docs"
  [ "$status" -eq 1 ]
  grep -qF 'gh release download -R ntodd/foreman -p install-control-plane.sh -O - | sudo bash' \
    "$root/docs/setup/personal.md"
  # And how to run it from a checkout, for a release without one.
  grep -qF 'sudo bash scripts/install-control-plane.sh --version 0.3.0' "$root/docs/setup/personal.md"
}

@test "wrapped items under Still to do hang under their text" {
  BASE_URL=https://dev.osiris-delta.ts.net:8443
  GITHUB_PENDING=check TAILSCALE_PENDING=1 BOX_PENDING=1 run summary
  todo=$(sed -n '/Still to do/,$p' <<<"$output" | tail -n +2)
  # The check item wraps; every line is an item or hangs under one.
  [ "$(wc -l <<<"$todo")" -gt 3 ]
  run grep -vE '^   - [^ ]|^     [^ ]' <<<"$todo"
  [ "$status" -eq 1 ]
  [ "$(widest <<<"$todo")" -le 80 ]
}
