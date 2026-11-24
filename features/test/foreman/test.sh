#!/bin/bash
# Run with: devcontainer features test --features foreman --base-image mcr.microsoft.com/devcontainers/base:debian features
set +e
source dev-container-features-test-lib

check "tailscale is installed" bash -c "tailscale version | head -1 | grep -q '^1\.'"
check "tailscaled is installed" bash -c "command -v tailscaled"
check "entrypoint is installed" test -x /usr/local/share/foreman/entrypoint.sh
check "profile hook is linked" test -L /etc/profile.d/zz-foreman.sh
check "bashrc sources the hook" grep -q "/usr/local/share/foreman/profile.sh" /etc/bash.bashrc
check "gitconfig includes /run/foreman" grep -q "path = /run/foreman/gitconfig" /etc/gitconfig

# The CLI is the user's own copy, so `foreman update` can replace it.
has_receipt() { ls "$HOME"/.local/state/foreman/cli-update/*.version >/dev/null 2>&1; }
reinstalls() {
  rm -f "$HOME/.local/bin/foreman" "$HOME"/.local/state/foreman/cli-update/*.version
  /usr/local/share/foreman/bin/foreman --version 2>/tmp/foreman-install.log | grep -q '^foreman v' &&
    grep -q 'installing the CLI' /tmp/foreman-install.log && has_receipt
}
# A login shell finds the user's own copy when its ~/.local/bin is on PATH
# (Debian's ~/.profile puts it there), and the launcher otherwise.
on_path() {
  case "$(bash -lc 'command -v foreman')" in
    /usr/local/share/foreman/bin/foreman | "$HOME/.local/bin/foreman") return 0 ;;
    *) return 1 ;;
  esac
}
check "foreman is on PATH in login shells" on_path
check "the launcher is installed" test -x /usr/local/share/foreman/bin/foreman
check "the CLI was installed for the devcontainer's user at build" test -x "$HOME/.local/bin/foreman"
own_copy() { [ "$(stat -c %u "$HOME/.local/bin/foreman")" = "$(id -u)" ] && has_receipt; }
check "it is the user's own, with the receipt foreman update needs" own_copy
check "the launcher runs it" bash -c "/usr/local/share/foreman/bin/foreman --version | grep -q '^foreman v'"
check "a user without one gets it the first time they run foreman" reinstalls
# Something else where the CLI goes is reported, not run and not replaced.
in_the_way() {
  mv "$HOME/.local/bin/foreman" /tmp/foreman.kept && mkdir "$HOME/.local/bin/foreman"
  /usr/local/share/foreman/bin/foreman --version >/tmp/foreman-conflict.log 2>&1
  status=$?
  rmdir "$HOME/.local/bin/foreman" && mv /tmp/foreman.kept "$HOME/.local/bin/foreman"
  [ "$status" = 127 ] && grep -q "isn't a runnable CLI" /tmp/foreman-conflict.log
}
check "something else in the CLI's place is reported, not replaced" in_the_way
check "curl is in the image for a later install" bash -c "command -v curl"

# Simulate what the agent delivers. /run/foreman is a read-only bind mount
# in a real environment; here the test creates it.
sudo mkdir -p /run/foreman
sudo tee /run/foreman/secrets.env >/dev/null <<'SECRETS'
export FOREMAN_TEST_SECRET='it'\''s here'
SECRETS
printf 'ghu_testtoken' | sudo tee /run/foreman/github-token >/dev/null
printf '[user]\n\tname = Test User\n\temail = test@example.com\n' | sudo tee /run/foreman/gitconfig >/dev/null
printf 'secrets pending restart\n' | sudo tee /run/foreman/notices >/dev/null
sudo chmod 0644 /run/foreman/*

check "login shells load secrets" bash -lc '[ "$FOREMAN_TEST_SECRET" = "it'"'"'s here" ]'
check "git identity comes from /run/foreman/gitconfig" bash -c '[ "$(git config user.email)" = "test@example.com" ]'
check "credential helper answers for github.com" bash -c \
  "printf 'protocol=https\nhost=github.com\n\n' | git credential fill | grep -q '^password=ghu_testtoken$'"
check "credential helper ignores other hosts" bash -c \
  "! /usr/local/share/foreman/git-credential-foreman get <<< \$'protocol=https\nhost=example.com\n' | grep -q password"
check "credential helper ignores plain http" bash -c \
  "! /usr/local/share/foreman/git-credential-foreman get <<< \$'protocol=http\nhost=github.com\n' | grep -q password"
check "gh wrapper is first on PATH in login shells" bash -lc '[ "$(command -v gh)" = /usr/local/share/foreman/bin/gh ]'
check "gh wrapper reports a missing gh" bash -lc 'gh --version; [ $? -eq 127 ]'
check "notices print in interactive shells" bash -c "script -qc 'bash -l -c true' /dev/null | grep -q 'secrets pending restart'"

# The container's environment, saved at start for shells that begin
# without it (Tailscale SSH). In an environment /run/foreman belongs to the
# devcontainer's user; here the test makes it so.
sudo chown "$(id -u)" /run/foreman
nl='
'
sudo env -i PATH=/usr/bin:/bin \
  "MULTI=start${nl}export HOME=removed" \
  'EVIL=$(touch /tmp/foreman-injected)' \
  "QUOTED=it's \"quoted\" \$HOME" \
  "END=end${nl}export HOME=removed" \
  UID=4242 /usr/local/share/foreman/entrypoint.sh true

login() { env -i HOME="$HOME" bash -lc "$1"; }
saved_is_private() { [ "$(stat -c '%u %a' /etc/foreman/container.env)" = "$(id -u) 600" ]; }
values_round_trip() {
  [ "$(login 'printf %s "$QUOTED"')" = "it's \"quoted\" \$HOME" ] &&
    [ "$(login 'printf %s "$MULTI"')" = "start${nl}export HOME=removed" ]
}
nothing_injected() { login true && [ ! -e /tmp/foreman-injected ]; }
no_shell_names() { ! grep -q '^export UID=' /etc/foreman/container.env; }
zsh_too() {
  ! command -v zsh >/dev/null ||
    [ "$(env -i HOME="$HOME" zsh -lc 'printf %s "$QUOTED"')" = "it's \"quoted\" \$HOME" ]
}
nested_keeps_path() { login 'export PATH=/venv/bin:$PATH; bash -ic "echo \$PATH"' 2>/dev/null | grep -q '^/venv/bin:'; }

check "the saved environment is the user's alone" saved_is_private
check "a clean login shell gets the container's environment, values intact" values_round_trip
check "no value runs as code" nothing_injected
check "shell-owned names aren't saved" no_shell_names
check "zsh logins load it too" zsh_too
check "a nested shell keeps the PATH it inherited" nested_keeps_path

reportResults
