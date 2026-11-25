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

# gh --attach runs behind the helper the agent release ships, which sends
# the upload through Foreman. The feature's source carries no helper, so
# first without one, then with a stand-in that says what it was asked.
sudo tee /usr/local/bin/gh >/dev/null <<'GH'
#!/bin/sh
echo "gh: $* token=${GH_TOKEN:-none}"
GH
sudo chmod 0755 /usr/local/bin/gh
wrapped() { bash -lc "$1" 2>/tmp/gh-wrapper.err; }

check "the feature's source ships no helper" test ! -e /usr/local/share/foreman/foreman-gh-attach
no_helper() {
  [ "$(wrapped 'gh pr edit 7 --attach a.png')" = "gh: pr edit 7 --attach a.png token=ghu_testtoken" ] &&
    [ ! -s /tmp/gh-wrapper.err ]
}
check "without the helper, gh --attach is the real gh" no_helper

sudo tee /usr/local/share/foreman/foreman-gh-attach >/dev/null <<'HELPER'
#!/bin/sh
echo "helper: $* token=${GH_TOKEN:-none}"
HELPER
sudo chmod 0755 /usr/local/share/foreman/foreman-gh-attach
check "gh without --attach is the real gh, with Foreman's token" bash -c \
  '[ "$(bash -lc "gh pr list --json number")" = "gh: pr list --json number token=ghu_testtoken" ]'
attaches() { [ "$(wrapped "$1")" = "helper: /usr/local/bin/gh $2 token=ghu_testtoken" ]; }
check "gh --attach runs behind the helper" attaches 'gh pr edit 7 --attach a.png' 'pr edit 7 --attach a.png'
check "gh --attach=file does too" attaches 'gh issue comment 7 --attach=a.png -b hi' 'issue comment 7 --attach=a.png -b hi'
check "so does any argument that reads --attach, wherever it is" attaches 'gh pr edit 7 -b -- --attach a.png' 'pr edit 7 -b -- --attach a.png'
own_token() { [ "$(wrapped 'GH_TOKEN=ghp_mine gh pr edit 7 --attach a.png')" = "gh: pr edit 7 --attach a.png token=ghp_mine" ]; }
check "a gh given its own token is left alone" own_token
# gh reads GH_TOKEN, then GITHUB_TOKEN. Foreman's token stands in when the
# caller has set neither, so either one is gh's to use as it would anywhere.
github_token() {
  [ "$(wrapped 'GITHUB_TOKEN=ghp_theirs gh pr list')" = "gh: pr list token=none" ] &&
    [ "$(wrapped 'GITHUB_TOKEN=ghp_theirs gh pr edit 7 --attach a.png')" = "gh: pr edit 7 --attach a.png token=none" ]
}
check "a gh given GITHUB_TOKEN is left alone too" github_token
# The way out to a login of one's own: gh stores none while a token is in
# its environment, and ranks any token there above one it has stored.
switched_off() {
  [ "$(wrapped 'FOREMAN_GH_TOKEN=off gh auth login')" = "gh: auth login token=none" ] &&
    [ "$(wrapped 'FOREMAN_GH_TOKEN=off gh pr edit 7 --attach a.png')" = "gh: pr edit 7 --attach a.png token=none" ] &&
    [ "$(wrapped 'FOREMAN_GH_TOKEN=on gh pr list')" = "gh: pr list token=ghu_testtoken" ]
}
check "FOREMAN_GH_TOKEN=off runs gh with nothing of Foreman's" switched_off
sudo rm /usr/local/share/foreman/foreman-gh-attach /usr/local/bin/gh

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
