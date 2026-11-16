#!/bin/sh
# Starts an agent release on each system it's built to run on. The release
# bundles ERTS, which links the build image's glibc and OpenSSL, so a newer
# build image makes an agent that won't start on older boxes; the e2e box
# is Debian 13 and wouldn't notice. It also carries Node and the
# devcontainer CLI, which have to run on systems that have no Node.
#
#   e2e/agent-smoke.sh path/to/foreman_agent.tar.gz
#
# Runs in this machine's architecture, on each system's stock container
# image, which has less installed than any server would; OpenSSL is added
# where it's missing.
set -eu

tarball=${1:?usage: $0 path/to/foreman_agent.tar.gz}
[ -f "$tarball" ] || { echo "no such file: $tarball" >&2; exit 1; }

# Docker Hub's official images, from a mirror: ECR Public's, or Google's
# when ECR refuses (it limits anonymous pulls by IP, and runners share IPs).
images="ubuntu:22.04 ubuntu:24.04 debian:12 debian:13"
mirrors="public.ecr.aws/docker/library mirror.gcr.io/library"

# Prints the reference it pulled.
pull() {
  for mirror in $mirrors; do
    if docker pull -q "$mirror/$1" >/dev/null; then
      echo "$mirror/$1"
      return
    fi
    echo "couldn't pull $1 from $mirror" >&2
  done
  return 1
}

# ed25519 is what release signatures and the agent's identity use; starting
# :ssl is what connecting to the control plane needs.
check='
{:ok, _} = Application.ensure_all_started(:ssl)
{_public, _private} = :crypto.generate_key(:eddsa, :ed25519)
[{_, _, openssl}] = :crypto.info_lib()
IO.puts("ok: OTP #{System.otp_release()}, #{openssl}")
'

# --rm as well, for a cancel that kills this script before the trap runs.
id=""
trap '[ -z "$id" ] || docker rm -f "$id" >/dev/null 2>&1' EXIT
trap 'exit 130' INT TERM

for image in $images; do
  echo "== $image"
  ref=$(pull "$image") || { echo "FAILED: couldn't pull $image" >&2; exit 1; }
  # shellcheck disable=SC2016
  id=$(docker create --rm -e LANG=C.UTF-8 "$ref" sh -euc '
    # Every server has OpenSSL (openssh needs it); a stock container may not.
    if ! ldconfig -p | grep -q "libcrypto\.so\.3 "; then
      apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends openssl >/dev/null
    fi
    mkdir /opt/agent
    tar -xzf /agent.tar.gz -C /opt/agent
    /opt/agent/bin/foreman_agent eval "$1"
    ! command -v node >/dev/null || { echo "this image has a Node of its own" >&2; exit 1; }
    for cli in /opt/agent/lib/foreman_agent-*/priv/tools/bin/devcontainer; do
      echo "ok: devcontainer CLI $("$cli" --version)"
    done
  ' sh "$check")
  docker cp "$tarball" "$id:/agent.tar.gz"
  docker start -a "$id" || { echo "FAILED: the agent doesn't start on $image" >&2; exit 1; }
  id=""
done
