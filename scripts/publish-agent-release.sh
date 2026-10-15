#!/bin/sh
# Registers a CI-built agent release (see .github/workflows/release.yml)
# with the control plane, so boxes can install and update to it.
#
#   scripts/publish-agent-release.sh 0.2.0
#
# Run it on the control plane host, from a checkout of the repo, with gh
# logged in to an account that can read the repo's releases. Set
# FOREMAN_CONTAINER if the container isn't called foreman, and
# FOREMAN_REPO (owner/name) to run it outside a checkout.
set -eu

version="${1:-}"
container="${FOREMAN_CONTAINER:-foreman}"

if ! echo "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "usage: $0 VERSION   (e.g. 0.2.0)" >&2
  exit 64
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

set -- --dir "$dir" --pattern "foreman_agent-$version-*"
[ -n "${FOREMAN_REPO:-}" ] && set -- "$@" --repo "$FOREMAN_REPO"
gh release download "v$version" "$@"

found=0
for tarball in "$dir"/foreman_agent-"$version"-*.tar.gz; do
  [ -e "$tarball" ] || break
  target=$(basename "$tarball" .tar.gz)
  target=${target#"foreman_agent-$version-"}
  signature=$(cat "$tarball.sig")

  # Both end up inside an Elixir string; refuse anything that isn't plain.
  echo "$target" | grep -Eq '^(linux|darwin)-(amd64|arm64)$' || { echo "unexpected target: $target" >&2; exit 1; }
  echo "$signature" | grep -Eq '^[A-Za-z0-9+/=]+$' || { echo "bad signature for $target" >&2; exit 1; }

  remote="/tmp/foreman_agent-$version-$target.tar.gz"
  docker cp "$tarball" "$container:$remote"
  docker exec "$container" env -u PHX_SERVER /app/bin/foreman eval \
    "Foreman.Release.publish_agent(\"$version\", \"$target\", \"$remote\", \"$signature\")"
  docker exec -u 0 "$container" rm -f "$remote"
  found=$((found + 1))
done

if [ "$found" -eq 0 ]; then
  echo "release v$version has no agent tarballs" >&2
  exit 1
fi
