#!/bin/sh
# Foreman feature entrypoint. The devcontainer CLI runs it on every
# container start, including a plain `docker restart`, which a
# postStartCommand would miss.
#
# It must never block or fail the container: the tailnet join runs in the
# background and logs to /var/log/foreman-tailscale.log.

# shellcheck source=/dev/null
. /usr/local/share/foreman/options 2>/dev/null || true

# Tailscale SSH (and so VS Code over SSH) starts a clean login shell, without
# the container's environment: compose `environment:`, containerEnv, or a
# PATH the image set. Save it on every start for profile.sh to load. Values
# are single-quoted by `export -p`; a shell sets the excluded names itself.
save_env() {
  export -p | grep -Ev '^export (HOME|USER|LOGNAME|SHELL|MAIL|PWD|OLDPWD|SHLVL|TERM|HOSTNAME|_)='
}
env_file=/etc/foreman/container.env
if [ "$(id -u)" -eq 0 ]; then
  save_env > "$env_file.tmp" && chmod 0644 "$env_file.tmp" && mv "$env_file.tmp" "$env_file"
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  save_env | sudo -n sh -c "cat > '$env_file.tmp' && chmod 0644 '$env_file.tmp' && mv '$env_file.tmp' '$env_file'"
fi

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
