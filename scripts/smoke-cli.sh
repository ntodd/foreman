#!/bin/sh
# Run only on the archive's target. Prove that the packaged binary, not a
# binary from PATH or the build directory, reports the requested stable tag.
set -eu
[ "$#" -eq 2 ] || { echo "Usage: $0 vX.Y.Z ARCHIVE" >&2; exit 2; }
tag=$1 archive=$2
os=$(uname -s | tr '[:upper:]' '[:lower:]')
case $(uname -m) in x86_64) arch=amd64;; arm64|aarch64) arch=arm64;; *) echo "Unsupported architecture" >&2; exit 1;; esac
[ "$(basename "$archive")" = "foreman-cli-$tag-$os-$arch.tar.gz" ] || { echo "Archive must target $os-$arch" >&2; exit 1; }
[ "$(tar -tzf "$archive")" = foreman ] || { echo "Expected exactly one foreman executable" >&2; exit 1; }
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
tar -xzf "$archive" -C "$stage"
[ -f "$stage/foreman" ] && [ ! -L "$stage/foreman" ] && [ -x "$stage/foreman" ] || exit 1
export XDG_STATE_HOME="$stage/state"
"$stage/foreman" --help > "$stage/help"
[ -s "$stage/help" ] || { echo "Missing CLI help" >&2; exit 1; }
version=$("$stage/foreman" --version)
case "$version" in "$tag"|"foreman $tag"|"Foreman CLI $tag") ;; *) echo "Expected $tag, got '$version'" >&2; exit 1;; esac
