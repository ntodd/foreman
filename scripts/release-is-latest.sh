#!/bin/sh
# Prints true when TAG is the latest release: at or above every published
# release, read one tag per line on stdin. Only published releases count,
# so a tag whose release workflow failed doesn't hold Latest (or the
# images' :latest) back from the releases after it. Anything but vX.Y.Z
# (prereleases, blank lines) is ignored.
#
#   gh release list --exclude-drafts --exclude-pre-releases --limit 1000 \
#     --json tagName --jq '.[].tagName' | scripts/release-is-latest.sh v0.3.1
set -eu
LC_ALL=C
export LC_ALL

[ $# -eq 1 ] || { echo "usage: $0 TAG < published-tags" >&2; exit 64; }
tag=$1
semver='^v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$'
if ! printf '%s\n' "$tag" | grep -q "$semver" || [ "$(printf '%s\n' "$tag" | wc -l)" -ne 1 ]; then
  echo "release-is-latest: $tag isn't vX.Y.Z" >&2
  exit 1
fi

highest=$({ cat; printf '%s\n' "$tag"; } | grep "$semver" | sed 's/^v//' |
  sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
if [ "v$highest" = "$tag" ]; then echo true; else echo false; fi
