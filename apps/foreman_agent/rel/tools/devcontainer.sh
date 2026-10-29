#!/bin/sh
# The devcontainer CLI, on the Node this agent release carries. Installed
# as bin/devcontainer in the release (rel/tools/bundle.sh).
root=$(cd "$(dirname "$0")/.." && pwd -P)
PATH="$root/node/bin:$PATH"
export PATH
exec "$root/node/bin/node" "$root/devcontainer/node_modules/@devcontainers/cli/devcontainer.js" "$@"
