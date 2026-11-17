#!/usr/bin/env bash
# Builds the control plane release for the Amp Box (see .amp/box.yaml).
# Runs in the orb that deploys, never on the Box, so it brings its own
# Erlang: the Box runs Ubuntu 24.04, and an ERTS built on a newer glibc or
# OpenSSL wouldn't start there.
set -euo pipefail

# The control plane must match the agents it serves, so bump these with
# the branch's base tag.
VERSION=0.5.0
OTP=29.1.1
ELIXIR=1.20.4
TAILSCALE=1.104.7

repo=$PWD
out=$repo/_box
cache=${XDG_CACHE_HOME:-$HOME/.cache}/foreman-box
mkdir -p "$cache"

otp=$cache/otp-$OTP
if [ ! -x "$otp/bin/erl" ]; then
  rm -rf "$otp" && mkdir -p "$otp"
  curl -fsSL "https://builds.hex.pm/builds/otp/amd64/ubuntu-24.04/OTP-$OTP.tar.gz" |
    tar -xz -C "$otp" --strip-components=1
  (cd "$otp" && ./Install -minimal "$otp" >/dev/null)
fi

elixir=$cache/elixir-$ELIXIR
if [ ! -x "$elixir/bin/elixir" ]; then
  rm -rf "$elixir" && mkdir -p "$elixir"
  curl -fsSL "https://builds.hex.pm/builds/elixir/v$ELIXIR-otp-${OTP%%.*}.zip" -o "$cache/elixir.zip"
  unzip -q "$cache/elixir.zip" -d "$elixir" && rm "$cache/elixir.zip"
fi

export PATH=$otp/bin:$elixir/bin:$PATH
export MIX_ENV=prod FOREMAN_DB=sqlite FOREMAN_VERSION=$VERSION
export MIX_HOME=$cache/mix HEX_HOME=$cache/hex

rm -rf "$out" && mkdir -p "$out/bin"

# The signed agents CI published for this version; the control plane
# registers them at boot and boxes download them from it.
agents=$repo/apps/foreman/priv/agent/releases
mkdir -p "$agents"
for target in linux-amd64 linux-arm64; do
  for file in "foreman_agent-$VERSION-$target.tar.gz" "foreman_agent-$VERSION-$target.tar.gz.sig"; do
    curl -fsSL "https://github.com/ntodd/foreman/releases/download/v$VERSION/$file" -o "$agents/$file"
  done
done

# Static Tailscale binaries; tailscaled runs in userspace mode as the
# deployment's own account.
curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE}_amd64.tgz" |
  tar -xz -C "$out/bin" --strip-components=1 \
    "tailscale_${TAILSCALE}_amd64/tailscale" "tailscale_${TAILSCALE}_amd64/tailscaled"

cd "$repo/apps/foreman"
mix local.hex --force --if-missing >/dev/null
mix local.rebar --force --if-missing >/dev/null
mix deps.get --only prod
mix assets.setup
mix compile
mix assets.deploy
mix release --overwrite --path "$out/foreman"

cp "$repo/.amp/box/start.sh" "$repo/.amp/box/placeholder.mjs" "$out/"
