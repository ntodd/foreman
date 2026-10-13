# Foreman: sourced by login and interactive shells (sh, bash, zsh).
#
# Loads the environment's secrets, puts the gh wrapper first on PATH, and
# shows any notices from the control plane ("secrets pending restart",
# "GitHub login expired").

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
