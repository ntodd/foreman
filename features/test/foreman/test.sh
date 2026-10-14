#!/bin/bash
# Run with: devcontainer features test --features foreman --base-image mcr.microsoft.com/devcontainers/base:debian features
set -e
source dev-container-features-test-lib

check "tailscale is installed" bash -c "tailscale version | head -1 | grep -q '^1\.'"
check "tailscaled is installed" bash -c "command -v tailscaled"
check "entrypoint is installed" test -x /usr/local/share/foreman/entrypoint.sh
check "profile hook is linked" test -L /etc/profile.d/zz-foreman.sh
check "bashrc sources the hook" grep -q "/usr/local/share/foreman/profile.sh" /etc/bash.bashrc
check "gitconfig includes /run/foreman" grep -q "path = /run/foreman/gitconfig" /etc/gitconfig

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

reportResults
