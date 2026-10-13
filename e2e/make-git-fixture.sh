#!/bin/sh
# Builds a bare copy of a fixture repo that git can clone over "dumb"
# HTTP from any static file server: e2e/make-git-fixture.sh <dest-dir>
set -eu
dest=${1:?destination directory}
src=$(cd "$(dirname "$0")/../apps/foreman_agent/test/fixtures/repos/hello" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cp -R "$src/." "$work/"
git -C "$work" init -q -b main
git -C "$work" add -A
git -C "$work" -c user.name=Foreman -c user.email=e2e@example.com commit -qm "Fixture"

mkdir -p "$dest/ntodd"
rm -rf "$dest/ntodd/hello.git"
git clone -q --bare "$work" "$dest/ntodd/hello.git"
git -C "$dest/ntodd/hello.git" update-server-info
echo "$dest/ntodd/hello.git"
