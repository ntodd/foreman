#!/bin/sh
# Foreman feature entrypoint. The devcontainer CLI runs it on every
# container start, including a plain `docker restart`, which a
# postStartCommand would miss.
#
# It must never block or fail the container: the tailnet join runs in the
# background and logs to /var/log/foreman-tailscale.log.

# shellcheck source=/dev/null
. /usr/local/share/foreman/options 2>/dev/null || true

if [ "${FOREMAN_TAILSCALE:-true}" = "true" ] && command -v tailscaled >/dev/null 2>&1; then
  if [ "$(id -u)" -eq 0 ]; then
    nohup /usr/local/share/foreman/tailscale-up.sh >>/var/log/foreman-tailscale.log 2>&1 &
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    # The log goes to /tmp: the redirect runs as this (non-root) user.
    # shellcheck disable=SC2024
    sudo -n -E nohup /usr/local/share/foreman/tailscale-up.sh >>/tmp/foreman-tailscale.log 2>&1 &
  else
    echo "foreman: tailscale needs root and there is no passwordless sudo" >&2
  fi
fi

exec "$@"
