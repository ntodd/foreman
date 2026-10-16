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
# PATH the image set. Save it on every start for profile.sh to load, as
# `export NAME='value'` lines built one variable at a time (values can span
# lines; a ' becomes '"'"', which every awk writes the same way). Names a shell sets for itself, or that make it read other files,
# are left out.
serialize_env() {
  awk 'BEGIN {
    skip = " HOME USER LOGNAME SHELL MAIL PWD OLDPWD SHLVL TERM HOSTNAME _ UID EUID GID EGID PPID IFS OPTIND OPTARG RANDOM SECONDS LINENO PS1 PS2 PS3 PS4 ENV BASH_ENV ZDOTDIR HISTFILE FOREMAN_CONTAINER_ENV "
    for (name in ENVIRON) {
      if (name !~ /^[A-Za-z_][A-Za-z0-9_]*$/ || index(skip, " " name " ")) continue
      value = ENVIRON[name]
      gsub(/\047/, "\047\042\047\042\047", value)
      printf "export %s=\047%s\047\n", name, value
    }
  }'
}
if [ -d /run/foreman ]; then
  if [ "$(id -u)" -eq 0 ]; then
    serialize_env | /usr/local/share/foreman/save-env
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    serialize_env | sudo -n /usr/local/share/foreman/save-env
  fi
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
