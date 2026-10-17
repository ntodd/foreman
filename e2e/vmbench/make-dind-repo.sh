#!/bin/sh
# The docker-in-docker fixture (dind/) as a bare repo at <dir>/acme/dind.git.
set -eu
dir=$1
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -R "$here/dind/." "$work/"
git -C "$work" init -q -b main
git -C "$work" add -A
git -C "$work" -c user.name=bench -c user.email=bench@foreman commit -qm "dind fixture"
mkdir -p "$dir/acme"
rm -rf "$dir/acme/dind.git"
git clone -q --bare "$work" "$dir/acme/dind.git"
git -C "$dir/acme/dind.git" update-server-info
echo "$dir/acme/dind.git"
