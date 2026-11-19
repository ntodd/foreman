#!/bin/sh
# Compose override for a CI service that starts its own Docker daemon.
# Forward only Crew's public mirror configuration and CA.
set -eu
service=${1:?usage: crew-cache.sh SERVICE}
ca=/usr/local/share/ca-certificates/crew-cache.crt
[ -s /etc/docker/certs.d/public.ecr.aws/hosts.toml ] || { echo "missing Crew ECR mirror" >&2; exit 1; }
printf 'services:\n  %s:\n    volumes:\n' "$service"
for path in "$ca" /etc/docker/certs.d/*/hosts.toml /etc/buildkit/buildkitd.toml; do
  [ -s "$path" ] || { echo "missing Crew cache configuration: $path" >&2; exit 1; }
  case "$path" in
    */localhost:5000/hosts.toml) ;; # the updater's local fixture registry
    */hosts.toml) grep -Fq "ca = \"$ca\"" "$path" || continue ;;
  esac
  printf '      - type: bind\n        source: %s\n        target: %s\n        read_only: true\n        bind: {create_host_path: false}\n' "$path" "$path"
done
