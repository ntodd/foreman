#!/bin/sh
# Installs the Foreman feature at image build time (as root).
#
# Everything Foreman delivers at runtime lands in /run/foreman, a read-only
# directory the agent bind-mounts from a tmpfs on the box. This script only
# installs the pieces inside the image that read from it:
#
#   - Tailscale, joined on every container start by entrypoint.sh
#   - a login-shell hook that loads /run/foreman/secrets.env
#   - git config that includes /run/foreman/gitconfig, and a credential
#     helper (plus a gh wrapper) that read /run/foreman/github-token
set -eu

TAILSCALE=${TAILSCALE:-true}
ACCEPTDNS=${ACCEPTDNS:-true}
DNSCHECKHOST=${DNSCHECKHOST:-}

# Pinned, with the digests checked in: a digest fetched next to the tarball
# would only catch corruption, not a swapped file.
TS_VERSION=1.104.1
TS_SHA256_AMD64=108d1d96ecf410d305571e173516f27038f870919a9b89c914a167c6d33a4528
TS_SHA256_ARM64=f60294374967f3dfd8cf57bbbd474d6cfce32d123e3a8ddeab82a87940daa806

share=/usr/local/share/foreman
here=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$share/bin" /etc/foreman
install -m 0755 "$here/scripts/entrypoint.sh" "$share/entrypoint.sh"
install -m 0755 "$here/scripts/save-env" "$share/save-env"
install -m 0755 "$here/scripts/tailscale-up.sh" "$share/tailscale-up.sh"
install -m 0755 "$here/scripts/git-credential-foreman" "$share/git-credential-foreman"
install -m 0755 "$here/scripts/gh" "$share/bin/gh"
install -m 0644 "$here/scripts/profile.sh" "$share/profile.sh"

# Build-time options the entrypoint reads at runtime. The file is sourced
# as root on every start, and a repo can set these options itself, so each
# value is single-quoted.
quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
{
  printf 'FOREMAN_TAILSCALE=%s\n' "$(quote "$TAILSCALE")"
  printf 'FOREMAN_ACCEPT_DNS=%s\n' "$(quote "$ACCEPTDNS")"
  printf 'FOREMAN_DNS_CHECK_HOST=%s\n' "$(quote "$DNSCHECKHOST")"
} > "$share/options"
chmod 0644 "$share/options"

# --- shell hooks ------------------------------------------------------------
# Login shells (Tailscale SSH sessions, the devcontainer CLI's env probe)
# read /etc/profile.d; interactive non-login bash reads bash.bashrc.
mkdir -p /etc/profile.d
ln -sf "$share/profile.sh" /etc/profile.d/zz-foreman.sh

hook=". $share/profile.sh"
append_once() {
  touch "$1"
  grep -qF "$hook" "$1" || printf '\n# Foreman environment\n%s\n' "$hook" >> "$1"
}
if command -v bash >/dev/null 2>&1; then
  if [ -d /etc/bash ]; then append_once /etc/bash/bashrc; else append_once /etc/bash.bashrc; fi
fi
# zsh reads zprofile for login shells and zshrc for interactive ones; Debian
# keeps them in /etc/zsh, most others in /etc.
if command -v zsh >/dev/null 2>&1 || [ -d /etc/zsh ]; then
  if [ -d /etc/zsh ]; then zdir=/etc/zsh; else zdir=/etc; fi
  append_once "$zdir/zprofile"
  append_once "$zdir/zshrc"
fi

# --- git ----------------------------------------------------------------------
# An include of a missing file is ignored, so this is harmless until the
# agent writes /run/foreman/gitconfig.
touch /etc/gitconfig
if ! grep -qF "/run/foreman/gitconfig" /etc/gitconfig; then
  cat >> /etc/gitconfig <<EOF

# Foreman: identity from /run/foreman, GitHub token from the credential helper.
[include]
	path = /run/foreman/gitconfig
[credential "https://github.com"]
	helper =
	helper = $share/git-credential-foreman
EOF
fi

# --- tailscale ----------------------------------------------------------------
fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    return 1
  fi
}

ensure_fetcher() {
  command -v curl >/dev/null 2>&1 && return 0
  command -v wget >/dev/null 2>&1 && return 0
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y --no-install-recommends curl ca-certificates
    rm -rf /var/lib/apt/lists/*
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl ca-certificates
  else
    echo "foreman: no curl or wget, and no package manager to install one" >&2
    exit 1
  fi
}

if [ "$TAILSCALE" = "true" ]; then
  case "$(uname -m)" in
    x86_64) arch=amd64; sum=$TS_SHA256_AMD64 ;;
    aarch64 | arm64) arch=arm64; sum=$TS_SHA256_ARM64 ;;
    *) echo "foreman: unsupported architecture $(uname -m)" >&2; exit 1 ;;
  esac

  ensure_fetcher
  release="tailscale_${TS_VERSION}_${arch}"
  tmp=$(mktemp -d)
  fetch "https://pkgs.tailscale.com/stable/$release.tgz" "$tmp/$release.tgz"
  (cd "$tmp" && printf '%s  %s\n' "$sum" "$release.tgz" | sha256sum -c -)
  tar -xzf "$tmp/$release.tgz" -C "$tmp" --strip-components=1 "$release/tailscale" "$release/tailscaled"
  install -m 0755 "$tmp/tailscale" "$tmp/tailscaled" /usr/local/bin/
  rm -rf "$tmp"
  mkdir -p /var/lib/tailscale /var/run/tailscale
  echo "foreman: installed Tailscale $TS_VERSION ($arch)"
fi

echo "foreman: feature installed"
