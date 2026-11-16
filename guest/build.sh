#!/bin/sh
# Builds the guest system image (see guest/Dockerfile) into DIR.
#
#   guest/build.sh DIR
#
# Only amd64 for now: environment VMs aren't supported on arm64 boxes yet.
set -eu
out=${1:?usage: guest/build.sh DIR}
here=$(cd "$(dirname "$0")" && pwd)
docker build --platform linux/amd64 -f "$here/Dockerfile" --target artifact -o "$out" "$here"
cd "$out"
sha256sum foreman-guest-linux-amd64.tar | tee foreman-guest-linux-amd64.tar.sha256
