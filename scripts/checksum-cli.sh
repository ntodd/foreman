#!/bin/sh
# Write a standard SHA-256 manifest only when all four packaged targets exist.
set -eu
[ "$#" -eq 2 ] || { echo "Usage: $0 vX.Y.Z ARCHIVE_DIR" >&2; exit 2; }
tag=$1
cd "$2"
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}
staged=$(mktemp .cli-sums.XXXXXXXX)
trap 'rm -f "$staged"' EXIT
for os in darwin linux; do
  for arch in amd64 arm64; do
    archive="foreman-cli-$tag-$os-$arch.tar.gz"
    [ -s "$archive" ] || { echo "Missing CLI archive: $archive" >&2; exit 1; }
    sha256 "$archive" >> "$staged"
  done
done
sha256 -c "$staged"
mv "$staged" "foreman-cli-$tag-SHA256SUMS"
