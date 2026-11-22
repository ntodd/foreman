#!/bin/sh
# Exercise the host request reader with an isolated mailbox.
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed '/^case "${1:-}" in/,$d' docker/foreman-update > "$work/functions"
# shellcheck source=/dev/null
. "$work/functions"
DIR=$work/mailbox
mkdir -p "$DIR/request"
printf '0.9.2\r\n' > "$DIR/request/version"
printf 'next request' > "$DIR/request/pending"
[ "$(take_request)" = 0.9.2 ]
[ ! -e "$DIR/request/version" ]
[ -f "$DIR/request/pending" ]
printf '0.9.3\nextra\n' > "$DIR/request/version"
[ -z "$(take_request)" ]
