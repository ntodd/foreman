#!/bin/sh
# Fetches what the agent release carries besides its own code, into a
# directory the release step copies in (FOREMAN_AGENT_TOOLS, see mix.exs).
# docker/box.Dockerfile runs it on the architecture it builds for.
#
#   rel/tools/bundle.sh <dir>
#
# On x86_64 that's Cloud Hypervisor (the static build named in
# cloud-hypervisor.sha256, checked against the digest there), in vm/, for
# environment VMs. Other architectures get an empty directory.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out=$1

case "$(uname -m)" in
  x86_64) arch=x64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "bundle.sh: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$out"

if [ "$arch" = x64 ]; then
  line=$(grep -v '^#' "$here/cloud-hypervisor.sha256")
  path=${line##* }
  curl -fsSL -o "$tmp/cloud-hypervisor-static" \
    "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/$path"
  (cd "$tmp" && printf '%s  cloud-hypervisor-static\n' "${line%% *}" | sha256sum -c - >/dev/null) || {
    echo "bundle.sh: $path doesn't match its digest" >&2
    exit 1
  }
  mkdir -p "$out/vm"
  cp "$tmp/cloud-hypervisor-static" "$out/vm/cloud-hypervisor"
  chmod 0755 "$out/vm/cloud-hypervisor"
  "$out/vm/cloud-hypervisor" --version >/dev/null
fi
