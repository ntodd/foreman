#!/bin/sh
# Puts Node and the devcontainer CLI in a directory the release step
# copies into the agent release (FOREMAN_AGENT_TOOLS, see mix.exs), so a
# box needs neither. docker/box.Dockerfile runs it on the architecture
# it builds for.
#
#   rel/tools/bundle.sh <dir>
#
# Node is the official build named in node.sha256, checked against the
# digest there. The CLI comes from devcontainer/package-lock.json, whose
# integrity hash npm checks.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out=$1

case "$(uname -m)" in
  x86_64) arch=x64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "bundle.sh: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

line=$(grep " node-v[0-9.]*-linux-$arch\.tar\.xz\$" "$here/node.sha256")
file=${line##* }
dir=${file%.tar.xz}
version=${dir#node-}
version=${version%-linux-"$arch"}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/$file" "https://nodejs.org/dist/$version/$file"
(cd "$tmp" && printf '%s\n' "$line" | sha256sum -c - >/dev/null) || {
  echo "bundle.sh: $file doesn't match its digest" >&2
  exit 1
}
tar -xJf "$tmp/$file" -C "$tmp"

mkdir -p "$out/node/bin" "$out/devcontainer" "$out/bin"
cp "$tmp/$dir/bin/node" "$out/node/bin/node"
cp "$tmp/$dir/LICENSE" "$out/node/LICENSE"

cp "$here/devcontainer/package.json" "$here/devcontainer/package-lock.json" "$out/devcontainer/"
PATH="$tmp/$dir/bin:$PATH" npm ci --prefix "$out/devcontainer" \
  --omit=dev --ignore-scripts --no-fund --no-audit --loglevel=error

cp "$here/devcontainer.sh" "$out/bin/devcontainer"
chmod 0755 "$out/bin/devcontainer" "$out/node/bin/node"

# The CLI has to start on the Node it's paired with.
"$out/bin/devcontainer" --version >/dev/null
