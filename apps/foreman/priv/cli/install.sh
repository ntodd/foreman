#!/bin/sh
# Foreman CLI installer for Linux and macOS. Run as the user who will use it.
set -eu

fail() { echo "Foreman CLI installation failed: $*" >&2; exit 1; }

fetch() {
  case "$1" in
    https://*) protocol='=https' ;;
    http://localhost:*|http://localhost/*|http://127.0.0.1:*|http://127.0.0.1/*|http://\[::1\]:*|http://\[::1\]/*) protocol='=http' ;;
    *) fail "expected an HTTPS release URL" ;;
  esac
  # -q first disables .curlrc, including credentials and custom headers.
  curl -q -fsSL --connect-timeout 10 --max-time 120 --proto "$protocol" --proto-redir "$protocol" "$1" -o "$2"
}

digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(sha256sum < "$1") || fail "cannot hash $1"
  elif command -v shasum >/dev/null 2>&1; then
    sum=$(shasum -a 256 < "$1") || fail "cannot hash $1"
  else
    fail "install sha256sum or shasum to verify the CLI archive"
  fi
  printf '%s\n' "${sum%% *}"
}

main() {
  umask 077
  case $(uname -s) in Linux) os=linux ;; Darwin) os=darwin ;; *) fail "supported operating systems are Linux and macOS" ;; esac
  case $(uname -m) in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) fail "supported CPUs are x86-64 and arm64" ;; esac
  case "${XDG_STATE_HOME:-}" in /*) state_base=$XDG_STATE_HOME ;; *) state_base=$HOME/.local/state ;; esac
  state="$state_base/foreman/cli-update"
  bin="$HOME/.local/bin"
  binary="$bin/foreman"
  owner="use the package manager or installation owner to update this executable"
  mkdir -p "$bin" "$state" || fail "$owner"
  [ ! -L "$binary" ] || fail "$owner"

  if [ -e "$binary" ]; then
    [ -f "$binary" ] && [ -x "$binary" ] && [ -w "$binary" ] && [ -w "$bin" ] || fail "$owner"
    installed_hash=$(digest "$binary")
    [ -f "$state/$installed_hash.version" ] || fail "$owner"
    # An installed CLI already has the verified upgrade path and install lock.
    "$binary" update
  else
    stage=$(mktemp -d "$bin/.foreman-install.XXXXXXXX") || fail "$owner"
    trap 'rm -rf "$stage"' EXIT
    trap 'exit 1' HUP INT TERM
    fetch '__FOREMAN_CLI_RELEASE_URL__' "$stage/tag" || fail "cannot discover the current release; try again"
    tag=$(cat "$stage/tag")
    # Keep the tag a single safe path component even for a misconfigured instance.
    case "$tag" in *[!v0-9.]*) fail "invalid release tag" ;; esac
    printf '%s\n' "$tag" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || fail "invalid release tag"
    base="https://github.com/ntodd/foreman/releases/download/$tag"
    name="foreman-cli-$tag-$os-$arch.tar.gz"
    fetch "$base/foreman-cli-$tag-SHA256SUMS" "$stage/sums" || fail "cannot download checksum manifest"
    expected=$(awk -v name="$name" 'NF == 2 && $2 == name {n++; sum=$1} END {if (n != 1) exit 1; print tolower(sum)}' "$stage/sums") || fail "missing or duplicate checksum for $name"
    fetch "$base/$name" "$stage/archive" || fail "cannot download $name"
    actual=$(digest "$stage/archive")
    [ "$expected" = "$actual" ] || fail "SHA-256 verification failed for $name"
    tar -tzf "$stage/archive" > "$stage/list" && [ "$(cat "$stage/list")" = foreman ] || fail "expected a single foreman executable in $name"
    tar -tvzf "$stage/archive" > "$stage/details" || fail "cannot read archive"
    case $(cat "$stage/details") in -*) ;; *) fail "expected a regular file in $name" ;; esac
    tar -xOzf "$stage/archive" foreman > "$stage/foreman" && [ -s "$stage/foreman" ] || fail "invalid CLI executable"
    chmod 755 "$stage/foreman"
    hash=$(digest "$stage/foreman")
    receipt=$(mktemp "$state/.version.XXXXXXXX")
    trap 'rm -rf "$stage"; rm -f "$receipt"' EXIT
    printf '%s\n' "$tag" > "$receipt"
    mv -f "$receipt" "$state/$hash.version"
    # A same-filesystem link publishes the complete executable atomically,
    # and cannot replace a concurrent install or a package-owned binary.
    ln "$stage/foreman" "$binary" || fail "cannot install $binary; check ownership and rerun"
    echo "Installed Foreman CLI $tag in $binary"
  fi
  # Print literal shell variables so the PATH command can be copied.
  # shellcheck disable=SC2016
  case ":${PATH:-}:" in *:"$bin":*) ;; *) echo 'Before login, run: export PATH="$HOME/.local/bin:$PATH"' ;; esac
}

main
