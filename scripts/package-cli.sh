#!/bin/sh
# Build a release archive from this checkout. OUT_DIR is relative to the caller.
set -eu
[ "$#" -eq 4 ] || { echo "Usage: $0 vX.Y.Z linux|darwin amd64|arm64 OUT_DIR" >&2; exit 2; }
tag=$1 os=$2 arch=$3
echo "$tag" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || { echo "Invalid stable tag: $tag" >&2; exit 2; }
case "$os-$arch" in linux-amd64|linux-arm64|darwin-amd64|darwin-arm64) ;; *) echo "Unsupported target: $os-$arch" >&2; exit 2;; esac
mkdir -p "$4"
out=$(cd "$4" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
stage=$(mktemp -d "$out/.cli-build.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
cd "$root/cli"
CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" go build -trimpath -ldflags "-s -w -X main.version=$tag" -o "$stage/foreman" ./cmd/foreman
name="foreman-cli-$tag-$os-$arch.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$stage/$name" -C "$stage" foreman
mv "$stage/$name" "$out/$name"
