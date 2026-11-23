#!/bin/sh
# Requires openapi-python-client, its Python runtime, openapi-ts, tsc, node and mix on PATH.
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
spec="$here/../../docs/design/public-api.openapi.yaml"

cd "$work"
openapi-python-client generate --fail-on-warning --meta none --path "$spec" --output-path pyclient
openapi-ts -i "$spec" -o generated
cp "$here/service.ts" .
tsc --strict --skipLibCheck --target ES2022 --lib ES2023,DOM,DOM.Iterable \
  --module commonjs --moduleResolution node --outDir dist service.ts

cd "$here/../../apps/foreman"
OPENAPI_CLIENT_DIR="$work" MIX_ENV=test mix test "$here/clients_test.exs"
