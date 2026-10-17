#!/bin/sh
# Builds the image every environment VM starts from, as an Incus image
# alias (default foreman-env). Run once per box as root (or a member of
# incus-admin), and again to pick up a newer Docker or devcontainer CLI;
# existing environments keep the image they were created from.
#
#   build-image.sh [--base images:ubuntu/24.04/cloud] [--alias foreman-env] [--profile NAME]...
set -eu

base=images:ubuntu/24.04/cloud
alias=foreman-env
profiles="--profile default"
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base=$2; shift 2 ;;
    --alias) alias=$2; shift 2 ;;
    --profile) profiles="$profiles --profile $2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

here=$(cd "$(dirname "$0")" && pwd)
vm=fm-image-build
incus delete --force "$vm" >/dev/null 2>&1 || true

# shellcheck disable=SC2086
incus launch "$base" "$vm" --vm $profiles \
  -c limits.cpu=4 -c limits.memory=4GiB -c security.secureboot=false </dev/null

i=0
until incus exec "$vm" -- true </dev/null >/dev/null 2>&1; do
  i=$((i + 1))
  [ $i -lt 300 ] || { echo "the build VM didn't come up" >&2; exit 1; }
  sleep 1
done
# cloud-init installs the incus agent on first boot; wait for it to finish.
incus exec "$vm" -- cloud-init status --wait </dev/null >/dev/null 2>&1 || true

incus file push "$here/provision.sh" "$vm/root/provision.sh" </dev/null
incus exec "$vm" -- sh /root/provision.sh </dev/null
incus exec "$vm" -- rm -f /root/provision.sh </dev/null
incus stop "$vm" </dev/null
# Published beside the current image and swapped in only once it's there,
# so a failed publish (a full disk, say) leaves the box with a usable one.
incus image alias delete "$alias-new" >/dev/null 2>&1 || true
incus publish "$vm" --alias "$alias-new" </dev/null
fingerprint() { incus image info "$1" </dev/null 2>/dev/null | awk '/^Fingerprint:/ {print $2}'; }
new=$(fingerprint "$alias-new")
old=$(fingerprint "$alias")
incus image alias delete "$alias-new" </dev/null
incus image alias delete "$alias" </dev/null >/dev/null 2>&1 || true
incus image alias create "$alias" "$new" </dev/null
if [ -n "$old" ] && [ "$old" != "$new" ]; then incus image delete "$old" </dev/null; fi
incus delete "$vm" </dev/null
echo "foreman: published $alias ($new)"
