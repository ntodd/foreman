#!/bin/sh
# Renders scripts/install-control-plane.sh for a release: bakes in the
# version, the image repository and the agent release public key, so the
# copy attached to the GitHub release installs exactly that release.
#
#   scripts/render-control-plane-installer.sh 0.3.0 ghcr.io/ntodd/foreman "$PUBLIC_KEY" > out/install-control-plane.sh
set -eu
# Character classes and ranges below mean ASCII only in the C locale.
LC_ALL=C
export LC_ALL

[ $# -eq 3 ] || { echo "usage: $0 VERSION IMAGE PUBLIC_KEY" >&2; exit 64; }
version=$1
image=$2
key=$3

fail() { echo "render: $*" >&2; exit 1; }

# Checked strictly, as whole values (grep would pass a value with one good
# line): they go into a sed replacement and into the script.
case $version in
  *[!0-9.]* | .* | *. | *..* | *.*.*.* | "") fail "$version isn't X.Y.Z" ;;
  *.*.*) ;;
  *) fail "$version isn't X.Y.Z" ;;
esac
case $image in
  *[!a-z0-9./_-]* | [!a-z0-9]* | "") fail "$image isn't an image repository" ;;
esac
case $key in
  *[!A-Za-z0-9+/=]* | =* | *=*[!=]* | "") fail "the public key isn't base64" ;;
esac

script="$(dirname "$0")/install-control-plane.sh"
rendered=$(sed \
  -e "s|__FOREMAN_VERSION__|$version|g" \
  -e "s|__FOREMAN_IMAGE__|$image|g" \
  -e "s|__FOREMAN_RELEASE_PUBLIC_KEY__|$key|g" "$script")
if printf '%s\n' "$rendered" | grep -Eq '__FOREMAN_(VERSION|IMAGE|RELEASE_PUBLIC_KEY)__'; then
  fail "a placeholder is left in the rendered installer"
fi
printf '%s\n' "$rendered"
