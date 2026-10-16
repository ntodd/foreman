# shellcheck shell=sh
# Foreman: sourced by login and interactive shells (sh, bash, zsh).
#
# Loads the container's environment (saved by entrypoint.sh, for shells that
# start without it, like Tailscale SSH sessions) and then the environment's
# secrets, puts the gh wrapper first on PATH, and shows any notices from the
# control plane ("secrets pending restart", "GitHub login expired").

# Once per session: a nested shell keeps what its parent changed (an
# activated virtualenv's PATH, say).
if [ -z "${FOREMAN_CONTAINER_ENV:-}" ] && [ -r /etc/foreman/container.env ]; then
  # shellcheck source=/dev/null
  . /etc/foreman/container.env
  FOREMAN_CONTAINER_ENV=1
  export FOREMAN_CONTAINER_ENV
fi

if [ -r /run/foreman/secrets.env ]; then
  # shellcheck source=/dev/null
  . /run/foreman/secrets.env
fi

case ":$PATH:" in
  *:/usr/local/share/foreman/bin:*) ;;
  *) PATH="/usr/local/share/foreman/bin:$PATH"; export PATH ;;
esac

if [ -s /run/foreman/notices ] && [ -t 1 ] && [ -z "${FOREMAN_NOTICES_SHOWN:-}" ]; then
  cat /run/foreman/notices
  FOREMAN_NOTICES_SHOWN=1
  export FOREMAN_NOTICES_SHOWN
fi
