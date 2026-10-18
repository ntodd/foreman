#!/usr/bin/env bash
# Installs a personal Foreman control plane on this Linux host and enrolls
# the host as a box: the SQLite image under Docker Compose, reachable only
# on your tailnet. Releases after 0.3.0 have their own copy attached,
# which installs (or upgrades to) that release; without a tag, gh takes
# the latest:
#
#   gh release download -R ntodd/foreman -p install-control-plane.sh -O - | sudo bash
#
# Run from a checkout, where nothing is baked in, it needs --version
# X.Y.Z, and --public-key on a host whose settings file doesn't have the
# key yet (docs/setup/personal.md).
#
# It says what each step does and asks for what it can't do itself: a
# GHCR token, the GitHub App and the Tailscale OAuth client. It's safe to
# stop and run again; finished steps are detected and skipped, and the
# secrets in /etc/foreman/foreman.env are never regenerated.
#
# Unattended runs take their answers from flags and environment variables
# (see --help) with --non-interactive. Prompts read from /dev/tty, so
# piping the script into bash works.
#
# Needs: Ubuntu or Debian with systemd, Docker Engine with Compose 2.30+,
# and Tailscale logged in, with MagicDNS and HTTPS certificates on. It
# offers to install Node 22 (NodeSource), git, jq and curl with apt.
# Team deployments (Postgres) aren't covered; see docs/setup/team.md.
set -euo pipefail
# Tracing (bash -x) would print secrets, so it's off unless asked for
# with FOREMAN_TRACE=1, and even then the functions that handle secrets
# (or pass them on) start with `eval "$UNTRACED"`: it turns tracing off
# for the rest of the function, and a RETURN trap, which only fires when
# that function returns, turns it back on. A helper function can't do
# this for its caller, hence the eval.
if [ "${FOREMAN_TRACE:-}" = 1 ]; then set -x; else set +x; fi
# shellcheck disable=SC2016 # expanded by the eval
UNTRACED='[[ $- != *x* ]] || { set +x; trap "trap - RETURN; set -x" RETURN; }'

# The release workflow fills these in (scripts/render-control-plane-installer.sh).
RELEASE_VERSION="__FOREMAN_VERSION__"
RELEASE_IMAGE="__FOREMAN_IMAGE__"
RELEASE_PUBLIC_KEY="__FOREMAN_RELEASE_PUBLIC_KEY__"
DEFAULT_IMAGE_REPO=ghcr.io/ntodd/foreman

ETC="${FOREMAN_ETC:-/etc/foreman}"
OPT="${FOREMAN_OPT:-/opt/foreman}"
BACKUPS="${FOREMAN_BACKUPS:-/var/backups/foreman}"
CONTAINER=foreman
AGENT_IDENTITY=/var/lib/foreman-agent/identity.json
PROTECTED_KEYS=" SECRET_KEY_BASE FOREMAN_ENCRYPTION_KEY "
BOX_NAME_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'

usage() {
  cat <<'EOF'
Usage: install-control-plane.sh [options]

Every option has an environment variable; flags win. Secrets are only
taken from the environment or the terminal, never from flags.

  --version X.Y.Z        FOREMAN_VERSION      Release to install (baked into release copies)
  --image REF            FOREMAN_IMAGE        Image to run instead, e.g. a local build
  --public-key KEY       FOREMAN_AGENT_RELEASE_PUBLIC_KEY
                                              Agent release key (baked into release copies)
  --admin LOGIN          FOREMAN_ADMINS       Your GitHub login; Foreman's admin
  --port PORT            FOREMAN_PORT         Loopback port to publish (default: first free from 4000)
  --https-port PORT      FOREMAN_HTTPS_PORT   Tailscale serve port (default: 443, else 8443, 10000, 8444...)
  --ghcr-user LOGIN      FOREMAN_GHCR_USER    GitHub login for the GHCR token
                         FOREMAN_GHCR_TOKEN   Classic PAT with read:packages
  --github-app MODE      FOREMAN_GITHUB_APP   manifest (one click, default), manual or skip
                         FOREMAN_GITHUB_APP_ID, FOREMAN_GITHUB_CLIENT_ID,
                         FOREMAN_GITHUB_CLIENT_SECRET  For --github-app manual
  --github-key FILE      FOREMAN_GITHUB_KEY_FILE  The app's private key (.pem), for manual
                         FOREMAN_TAILSCALE_CLIENT_ID, FOREMAN_TAILSCALE_CLIENT_SECRET
                                              Tailscale OAuth client; replaces a
                                              configured one when they differ
  --skip-tailscale       FOREMAN_TAILSCALE=skip   Leave the OAuth client for later
  --box-name NAME        FOREMAN_BOX_NAME     This host's name as a box (default: its hostname)
                         FOREMAN_JOIN_TOKEN   A join token from Boxes -> Add a box
  --skip-box             FOREMAN_BOX=skip     Don't enroll this host as a box
  --non-interactive      FOREMAN_NONINTERACTIVE=1  Never prompt; use defaults or fail
                         FOREMAN_INSTALL_NODE, FOREMAN_INSTALL_PACKAGES,
                         FOREMAN_TAILNET_OK  yes/no answers (default yes)
                         FOREMAN_NEW_SECRETS=yes  A new FOREMAN_ENCRYPTION_KEY beside an
                                              existing foreman-data volume (default no)
                         FOREMAN_UPGRADE=yes  Change the pinned image (asked on a terminal;
                                              unattended, the default is no)
                         FOREMAN_BACKUP=no    Skip the backup taken before changing it
                                              (to /var/backups/foreman; default yes)
                         FOREMAN_DOWNGRADE=yes  Allow moving to an older version (default no)
                         FOREMAN_HEALTH_TIMEOUT  Seconds to wait for /healthz (default 180)
                         FOREMAN_TRACE=1      Trace the run (set -x), except the parts
                                              that handle secrets; bash -x alone is ignored
  -h, --help
EOF
}

fail() { echo "foreman: $*" >&2; exit 1; }
say() { echo "foreman: $*"; }
warn() { echo "foreman: warning: $*" >&2; }
step() { printf '\n== %s\n' "$*"; }
# Indented explanation, from arguments (wrapped to fit 80 columns) or a
# heredoc (laid out by hand, so taken as it is).
explain() {
  if [ $# -gt 0 ]; then printf '%s\n' "$@" | fold -s -w 77; else cat; fi | sed -e 's/^/   /' -e 's/ *$//'
}

# Temp files to remove however the run ends, Ctrl-C included, so none
# are left beside the settings or compose files.
CLEANUP=()
cleanup() { rm -rf ${CLEANUP[@]+"${CLEANUP[@]}"}; }
on_exit_cleanup() {
  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# item TEXT: a list item under an explanation, wrapped lines hanging
# under its text.
item() {
  printf '%s\n' "$1" | fold -s -w 75 | sed -e '1s/^/   - /' -e '2,$s/^/     /' -e 's/ *$//'
}

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# -- prompts -----------------------------------------------------------------

TTY_STATE=""

# Prompts read from /dev/tty: under `curl | bash` stdin is the script.
tty_ready() {
  case "${FOREMAN_NONINTERACTIVE:-}" in "" | 0 | no | false) ;; *) return 1 ;; esac
  if [ -z "$TTY_STATE" ]; then
    local tty="${FOREMAN_TTY:-/dev/tty}"
    # Probe in a subshell: a failed redirect on exec can end the shell.
    if (exec 8<"$tty") 2>/dev/null; then
      exec 8<"$tty"
      TTY_STATE=open
    else
      TTY_STATE=none
    fi
  fi
  [ "$TTY_STATE" = open ]
}

# ask VAR PROMPT [DEFAULT]: keeps VAR if it's set, otherwise asks (or
# takes the default when there's no terminal).
ask() {
  local var=$1 prompt=$2 default=${3-} answer
  [ -z "${!var:-}" ] || return 0
  if ! tty_ready; then
    [ -n "$default" ] || fail "$prompt: set $var (there's no terminal to ask on)"
    printf -v "$var" '%s' "$default"
    return 0
  fi
  while :; do
    if [ -n "$default" ]; then
      printf '%s [%s]: ' "$prompt" "$default" >&2
    else
      printf '%s: ' "$prompt" >&2
    fi
    IFS= read -r answer <&8 || fail "no answer for $var"
    answer=$(trim "${answer:-$default}")
    [ -z "$answer" ] || break
  done
  printf -v "$var" '%s' "$answer"
}

# ask_secret VAR PROMPT: like ask, without echoing or defaults.
ask_secret() {
  eval "$UNTRACED"
  local var=$1 prompt=$2 answer
  [ -z "${!var:-}" ] || return 0
  tty_ready || fail "$prompt: set $var (there's no terminal to ask on)"
  while :; do
    printf '%s (not shown): ' "$prompt" >&2
    IFS= read -r -s answer <&8 || fail "no answer for $var"
    printf '\n' >&2
    answer=$(trim "$answer")
    [ -z "$answer" ] || break
  done
  printf -v "$var" '%s' "$answer"
}

# confirm VAR PROMPT DEFAULT(y|n): VAR (yes/no) answers it unattended.
confirm() {
  local var=$1 prompt=$2 default=$3 answer hint=y/N
  answer=${!var:-}
  [ "$default" = y ] && hint=Y/n
  while :; do
    if [ -z "$answer" ]; then
      if tty_ready; then
        printf '%s [%s] ' "$prompt" "$hint" >&2
        IFS= read -r answer <&8 || answer=""
      fi
      answer=${answer:-$default}
    fi
    case "$answer" in
      [Yy] | [Yy][Ee][Ss] | 1 | true) return 0 ;;
      [Nn] | [Nn][Oo] | 0 | false) return 1 ;;
    esac
    if [ -n "${!var:-}" ] || ! tty_ready; then
      fail "$var: expected yes or no, not $answer"
    fi
    answer=""
  done
}

parse_args() {
  local value
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help) usage; exit 0 ;;
      --non-interactive) FOREMAN_NONINTERACTIVE=1; shift; continue ;;
      --skip-box) FOREMAN_BOX=skip; shift; continue ;;
      --skip-tailscale) FOREMAN_TAILSCALE=skip; shift; continue ;;
      --version | --image | --port | --https-port | --admin | --public-key | --github-app | \
        --github-key | --ghcr-user | --box-name) ;;
      *) echo "unknown option: $1 (see --help)" >&2; exit 64 ;;
    esac
    [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 64; }
    value=$2
    case "$1" in
      --version) FOREMAN_VERSION=$value ;;
      --image) FOREMAN_IMAGE=$value ;;
      --port) FOREMAN_PORT=$value ;;
      --https-port) FOREMAN_HTTPS_PORT=$value ;;
      --admin) FOREMAN_ADMINS=$value ;;
      --public-key) FOREMAN_AGENT_RELEASE_PUBLIC_KEY=$value ;;
      --github-app)
        case "$value" in manifest | manual | skip) ;; *) echo "--github-app is manifest, manual or skip" >&2; exit 64 ;; esac
        FOREMAN_GITHUB_APP=$value ;;
      --github-key) FOREMAN_GITHUB_KEY_FILE=$value ;;
      --ghcr-user) FOREMAN_GHCR_USER=$value ;;
      --box-name) FOREMAN_BOX_NAME=$value ;;
    esac
    shift 2
  done
}

# -- versions and prerequisites ----------------------------------------------

# version_at_least VERSION MAJOR MINOR: 0 if VERSION >= MAJOR.MINOR, 1 if
# older, 2 if it can't be read.
version_at_least() {
  local v=${1#v} major minor
  major=${v%%.*}
  minor=""
  [ "$v" = "$major" ] || minor=${v#*.}
  minor=${minor%%.*}
  case "$major" in "" | *[!0-9]*) return 2 ;; esac
  case "$minor" in *[!0-9]*) return 2 ;; esac
  minor=${minor:-0}
  if [ "$major" -gt "$2" ] || { [ "$major" -eq "$2" ] && [ "$minor" -ge "$3" ]; }; then
    return 0
  fi
  return 1
}

# The compose file reads the settings file with `format: raw` (2.30+).
compose_version_ok() { version_at_least "$1" 2 30; }
node_version_ok() { version_at_least "$1" 20 0; }

# What systemd units see. The agent's unit runs the devcontainer CLI with
# whatever node is on it, so a node only in someone's nvm doesn't count.
system_which() {
  (PATH=${FOREMAN_SYSTEM_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin} &&
    hash -r && command -v "$1") 2>/dev/null
}

# quietly DESCRIPTION COMMAND...: runs COMMAND with its output kept aside,
# and shows it only if COMMAND fails.
quietly() {
  local what=$1 log
  shift
  log=$(mktemp)
  CLEANUP+=("$log")
  if ! "$@" >"$log" 2>&1 </dev/null; then
    sed 's/^/  /' "$log" >&2
    rm -f "$log"
    fail "$what failed (output above)"
  fi
  rm -f "$log"
}

apt_install() {
  command -v apt-get >/dev/null 2>&1 || fail "apt-get isn't available; install $* yourself and run this again"
  say "installing $* with apt"
  quietly "apt-get update" env DEBIAN_FRONTEND=noninteractive apt-get update
  quietly "apt-get install $*" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

ensure_packages() {
  local missing="" pair
  for pair in curl:curl jq:jq git:git openssl:openssl ss:iproute2 sha256sum:coreutils; do
    command -v "${pair%%:*}" >/dev/null 2>&1 || missing="$missing ${pair#*:}"
  done
  [ -n "$missing" ] || return 0
  say "missing:$missing"
  confirm FOREMAN_INSTALL_PACKAGES "Install$missing with apt?" y ||
    fail "install$missing and run this again"
  # shellcheck disable=SC2086 # one package per word
  apt_install ca-certificates $missing
}

ensure_node() {
  local node version why
  node=$(system_which node || true)
  if [ -n "$node" ]; then
    version=$("$node" --version 2>/dev/null || true)
    if ! node_version_ok "$version"; then
      why="Node ${version:-(unknown version)} is older than 20"
    elif ! system_which npm >/dev/null; then
      why="Node $version is installed but npm is missing"
    else
      say "Node $version is installed"
      return 0
    fi
  else
    why="there's no Node on the system PATH (one installed with nvm doesn't count: systemd can't see it)"
  fi
  explain "$why. The box agent needs Node 20+ with npm for the devcontainer CLI."
  if ! confirm FOREMAN_INSTALL_NODE "Install Node 22 from NodeSource with apt?" y; then
    fail "Node 20+ is required on the system PATH; install it from https://github.com/nodesource/distributions and run this again"
  fi
  command -v apt-get >/dev/null 2>&1 || fail "apt-get isn't available; install Node 20+ from https://github.com/nodesource/distributions"
  say "adding NodeSource's Node 22 apt repository"
  local tmp
  tmp=$(mktemp -d)
  CLEANUP+=("$tmp")
  curl -fsSL https://deb.nodesource.com/setup_22.x -o "$tmp/nodesource_setup.sh" ||
    { rm -rf "$tmp"; fail "couldn't download the NodeSource setup script"; }
  quietly "NodeSource's setup script" bash "$tmp/nodesource_setup.sh"
  rm -rf "$tmp"
  apt_install nodejs
  node=$(system_which node || true)
  if [ -z "$node" ] || ! node_version_ok "$("$node" --version)"; then
    fail "Node still isn't on the system PATH after installing nodejs"
  fi
  # apt leaves a nodejs it thinks is current alone, npm or not.
  system_which npm >/dev/null ||
    fail "npm still isn't on the system PATH after installing nodejs. Reinstall it from NodeSource (sudo apt-get install --reinstall nodejs), or install npm (sudo apt-get install npm), and run this again"
  say "installed Node $("$node" --version)"
}

ensure_docker() {
  command -v docker >/dev/null 2>&1 ||
    fail "Docker Engine is required; install it from Docker's apt repository (https://docs.docker.com/engine/install/)"
  docker info >/dev/null 2>&1 || fail "Docker isn't running (systemctl status docker)"
  local compose rc=0
  compose=$(docker compose version --short 2>/dev/null || true)
  [ -n "$compose" ] || fail "the Docker Compose plugin is required (docker-compose-plugin from Docker's apt repository)"
  compose_version_ok "$compose" || rc=$?
  case $rc in
    0) say "Docker Compose $compose" ;;
    1) fail "Docker Compose $compose is too old; 2.30 or newer is needed. Install Docker from Docker's apt repository (https://docs.docker.com/engine/install/), which ships a current docker-compose-plugin" ;;
    *) fail "couldn't read the Docker Compose version ($compose)" ;;
  esac
}

# -- ports -------------------------------------------------------------------

valid_port() {
  case "$1" in "" | *[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# Reads ports, or A-B ranges, one per line, and prints each port.
expand_ranges() {
  local a b
  while IFS=- read -r a b; do
    [ -n "$a" ] || continue
    if [ -n "$b" ]; then seq "$a" "$b"; else echo "$a"; fi
  done
}

# Ports something on this host already listens on or publishes, except
# the ones Foreman's own container (CONTAINER) holds. Stopped containers
# that docker starts again on its own (a restart policy other than no)
# count too: they'd take their ports back at the next boot.
ports_in_use() {
  local own ids
  own=$(docker port "$1" 2>/dev/null | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' || true)
  ids=$(docker ps -aq --filter status=exited 2>/dev/null || true)
  {
    ss -Htln 2>/dev/null | awk '{print $4}' | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' || true
    # With docker's userland proxy off, published ports don't show in ss.
    docker ps --format '{{.Ports}}' 2>/dev/null | grep -oE ':[0-9]+(-[0-9]+)?->' |
      tr -d ':>' | sed 's/-$//' | expand_ranges || true
    if [ -n "$ids" ]; then
      # shellcheck disable=SC2086 # one ID per word
      docker inspect -f '{{.Name}}|{{.HostConfig.RestartPolicy.Name}}|{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostPort}} {{end}}{{end}}' $ids 2>/dev/null |
        awk -F'|' -v own="/$1" '$1 != own && $2 != "no" && $2 != "" { n = split($3, p, " "); for (i = 1; i <= n; i++) print p[i] }' |
        expand_ranges || true
    fi
  } | sort -nu | if [ -n "$own" ]; then grep -vxF "$own" || true; else cat; fi
}

# The loopback port to keep: the one a previous run pinned, else the one
# an existing foreman container publishes (a manual install being taken
# over), so its serve port and base URL stay put. Read from its port
# bindings, which a stopped container keeps (docker port shows nothing
# for one), else from docker port (a binding to a random port).
pinned_host_port() {
  local port
  port=$(env_get "$OPT/.env" FOREMAN_PORT || true)
  if [ -z "$port" ]; then
    port=$(docker inspect -f '{{range (index .HostConfig.PortBindings "4000/tcp")}}{{.HostPort}} {{end}}' "$1" 2>/dev/null |
      tr ' ' '\n' | grep -E '^[0-9]+$' | head -n 1 || true)
  fi
  if [ -z "$port" ]; then
    port=$(docker port "$1" 4000/tcp 2>/dev/null | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -n 1 || true)
  fi
  printf '%s' "$port"
}

# pick_free_port START [USED...]
pick_free_port() {
  local port=$1
  shift
  local used=" $* "
  while [ "$port" -le 65535 ]; do
    case "$used" in
      *" $port "*) port=$((port + 1)) ;;
      *) echo "$port"; return 0 ;;
    esac
  done
  fail "no free port above $1"
}

# host_port_choice REQUESTED PINNED [USED...]: the loopback port to
# publish the control plane on.
host_port_choice() {
  local requested=$1 pinned=$2
  shift 2
  local used=" $* "
  if [ -n "$requested" ]; then
    valid_port "$requested" || fail "--port $requested isn't a port number"
    case "$used" in *" $requested "*) fail "port $requested is already in use on this host (or tailscale serve forwards to it); pick another with --port" ;; esac
    echo "$requested"
    return 0
  fi
  if [ -n "$pinned" ]; then
    case "$used" in
      *" $pinned "*) fail "port $pinned (pinned in $OPT/.env) is now used by something else; free it, or pick another with --port" ;;
    esac
    echo "$pinned"
    return 0
  fi
  pick_free_port 4000 "$@"
}

# -- tailscale ---------------------------------------------------------------

with_timeout() {
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$seconds" "$@"; else "$@"; fi
}

# Sets TS_HOST (MagicDNS name), TS_TAGS (comma list) and TS_TAILNET.
tailscale_self() {
  command -v tailscale >/dev/null 2>&1 ||
    fail "Tailscale is required: curl -fsSL https://tailscale.com/install.sh | sh, then sudo tailscale up"
  local json state
  json=$(tailscale status --json 2>/dev/null) || fail "couldn't read tailscale status; is tailscaled running? (sudo tailscale up)"
  state=$(jq -r '.BackendState // ""' <<<"$json")
  [ "$state" = Running ] || fail "Tailscale isn't connected (${state:-no state}); run: sudo tailscale up"
  TS_HOST=$(jq -r '(.Self.DNSName // "") | rtrimstr(".")' <<<"$json")
  [ -n "$TS_HOST" ] || fail "this host has no MagicDNS name; turn MagicDNS on at https://login.tailscale.com/admin/dns"
  jq -e '((.Self.CapMap // {}) | has("https")) or ((.CertDomains // []) | length > 0)' <<<"$json" >/dev/null ||
    fail "HTTPS certificates are off for this tailnet. Turn on MagicDNS and HTTPS Certificates at https://login.tailscale.com/admin/dns, then run this again"
  TS_TAGS=$(jq -r '(.Self.Tags // []) | join(",")' <<<"$json")
  TS_TAILNET=$(jq -r '.CurrentTailnet.Name // ""' <<<"$json")
}

# Fails unless JSON is what `tailscale serve status --json` prints (an
# object, `{}` when nothing is served). Anything else would read as
# "nothing served" and put Foreman over whatever is.
require_serve_json() {
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$1" ||
    fail "couldn't read tailscale serve status --json (got: ${1:-nothing}); check sudo tailscale serve status"
}

serve_status_json() {
  local json
  json=$(tailscale serve status --json 2>/dev/null || true)
  require_serve_json "$json"
  printf '%s\n' "$json"
}

# The ports serve already uses on this node, foreground sessions
# included, and any port Funnel is allowed on.
serve_used_ports() {
  jq -r '[.] + [(.Foreground // {})[]]
    | [.[] | ((.TCP // {}) | keys[]), ((.AllowFunnel // {}) | keys[] | split(":") | last)]
    | unique | .[]' <<<"$1"
}

# jq definitions shared by everything that reads serve targets.
# `loopback` takes a proxy or TCP forward target (http://127.0.0.1:4000,
# https+insecure://localhost:8443/app?x=1, 127.0.0.1:22) and gives
# {port, bare} when it points at this host's loopback (127.x.x.x,
# localhost, [::1], or 0.0.0.0 and [::], which reach it too), else
# nothing. Serve forwards to that port whatever path or query follows,
# so they don't change the port; bare is false when there is one. With
# no port, it's the scheme's. `configs` is the serve config with every
# foreground session and service config beside it.
# shellcheck disable=SC2016 # jq's $variables
JQ_SERVE_DEFS='
def loopback:
  (capture("^(?:(?<scheme>[A-Za-z][A-Za-z0-9+.-]*)://)?(?<host>localhost|127(?:[.][0-9]{1,3}){3}|0[.]0[.]0[.]0|\\[(?:::1?|(?:0{1,4}:){7}0{0,3}[01])\\])(?::(?<port>[0-9]+))?(?<rest>[/?#].*)?$"; "i")? // empty)
  | (.scheme // "" | ascii_downcase) as $s
  | {port: (.port // (if $s == "" then null elif ($s | startswith("https")) then "443" else "80" end)),
     bare: ((.rest // "/") == "/")}
  | select(.port != null);
def loopback_port: [loopback | .port][0];
def configs: [.] + [(.Foreground // {})[]] + [(.Services // {})[]];
'

# The loopback ports serve forwards to, for any port, foreground sessions
# and services included. Foreman can't take one: whatever serves it
# (Funnel and all) would reach Foreman instead of the service it was
# meant for.
serve_loopback_ports() {
  jq -r "$JQ_SERVE_DEFS"'
    configs
    | map(((.Web // {})[] | (.Handlers // {})[] | .Proxy // empty), ((.TCP // {})[] | .TCPForward // empty))
    | .[] | strings | loopback | .port' <<<"$1" | sort -nu
}

# What a port serves now (a proxy target, a path, or a TCP forward).
serve_target_at() { # JSON HOST PORT
  jq -r --arg hp "$2:$3" --arg p "$3" '
    (([.Web // {}] + [(.Foreground // {})[] | .Web // {}]) | add | .[$hp].Handlers["/"] // {}) as $h
    | ($h.Proxy // $h.Path // $h.Text // (.TCP[$p].TCPForward // "something else"))' <<<"$1"
}

# serve_port_choice JSON HOST PINNED [REQUESTED] [PREFERRED] [LOCAL]:
# the HTTPS port to serve Foreman on. PINNED is the loopback port Foreman
# is known to have (pinned in .env, or published by its container),
# PREFERRED the port in the settings file's base URL, and LOCAL the ports
# something on this host listens on. A port counts as Foreman's only when
# it proxies to loopback on PINNED, or, with no PINNED, when it's
# PREFERRED and proxies to a loopback port nothing in LOCAL listens on,
# with Funnel off. Any other loopback proxy belongs to another service,
# running or not. Reuses Foreman's port, then PREFERRED if it's free, so URLs
# given to GitHub stay put; otherwise the first free one of 443, 8443,
# 10000, 8444... Free means serve doesn't use it and nothing here listens
# on it (serve would take it over for tailnet clients).
serve_port_choice() {
  local json=$1 host=$2 pinned=$3 requested=${4-} preferred=${5-} ours used taken p
  local here=" ${6-} "
  require_serve_json "$json"
  # With nothing pinned, the base URL's port is only a guess: it isn't
  # Foreman's if something here listens on its target (another service,
  # up), if it has Funnel on (Foreman never does), or if it serves paths
  # besides "/" (serving Foreman would only replace "/").
  ours=" $(jq -r --arg host "$host" --arg pinned "$pinned" --arg preferred "$preferred" --arg here "$here" "$JQ_SERVE_DEFS"'
    (([.AllowFunnel // {}] + [(.Foreground // {})[] | .AllowFunnel // {}]) | add) as $funnel
    | (.Web // {}) | to_entries[]
    | select(.key | startswith($host + ":"))
    | .key as $hp
    | (.key | split(":") | last) as $port
    | ([(.value.Handlers["/"].Proxy // "") | loopback][0]) as $target
    | ($target.port) as $lp
    | select(if $pinned != "" then $lp == $pinned
        else $port == $preferred and $lp != null and $target.bare
          and ((.value.Handlers // {}) | keys) == ["/"]
          and ($here | contains(" " + $lp + " ") | not)
          and ($funnel[$hp] // false) != true end)
    | $port' <<<"$json" | tr '\n' ' ')"
  used=" $(serve_used_ports "$json" | tr '\n' ' ') "
  if [ -n "$requested" ]; then
    valid_port "$requested" || fail "--https-port $requested isn't a port number"
    case "$ours" in
      *" $requested "*) ;;
      *)
        case "$used" in
          *" $requested "*) fail "https://$host:$requested already serves $(serve_target_at "$json" "$host" "$requested"); pick another --https-port" ;;
        esac
        case "$here" in
          *" $requested "*) warn "something on this host listens on port $requested; tailnet clients will reach Foreman there instead" ;;
        esac ;;
    esac
    echo "$requested"
    return 0
  fi
  if [ -n "${ours// /}" ]; then
    case "$ours" in
      *" $preferred "*) echo "$preferred" ;;
      *) p=${ours# }; echo "${p%% *}" ;;
    esac
    return 0
  fi
  taken="$used$here"
  if [ -n "$preferred" ]; then
    case "$taken" in *" $preferred "*) ;; *) echo "$preferred"; return 0 ;; esac
  fi
  for p in 443 8443 10000 $(seq 8444 8999); do
    case "$taken" in *" $p "*) ;; *) echo "$p"; return 0 ;; esac
  done
  fail "no free HTTPS port for tailscale serve"
}

# base_url_port URL HOST: the port URL serves HOST on, if it's https://HOST.
base_url_port() {
  local p
  case "$1" in
    "https://$2" | "https://$2/") echo 443 ;;
    "https://$2:"*) p=${1#"https://$2:"}; p=${p%/}; if valid_port "$p"; then echo "$p"; fi ;;
  esac
}

# port_443_note JSON HOST PORT [LOCAL]: why Foreman isn't on 443.
port_443_note() {
  local json=$1 host=$2 port=$3 here=" ${4-} " funnel
  [ "$port" != 443 ] || return 0
  if [[ " $(serve_used_ports "$json" | tr '\n' ' ') " == *" 443 "* ]]; then
    funnel=$(jq -r --arg hp "$host:443" '(.AllowFunnel // {})[$hp] // false' <<<"$json")
    say "https://$host already serves $(serve_target_at "$json" "$host" 443)$([ "$funnel" != true ] || echo ' (with Funnel on)'); leaving it alone"
  elif [[ "$here" == *" 443 "* ]]; then
    say "something on this host listens on 443; leaving it alone"
  else
    say "443 is free, but Foreman stays on $port, where it's already served, so its URLs (and the GitHub App's) don't change"
  fi
}

# serves_loopback_port JSON HOST PORT LOOPBACK: 0 when PORT's "/" proxies,
# in the background, to LOOPBACK on this host's loopback.
serves_loopback_port() {
  jq -e --arg hp "$2:$3" --arg lp "$4" "$JQ_SERVE_DEFS"'
    ((.Web // {})[$hp].Handlers["/"].Proxy // "") | loopback_port == $lp' <<<"$1" >/dev/null
}

# serve_check JSON HOST PORT TARGET: 0 when PORT serves TARGET in the
# background, tailnet only; 1 when it doesn't serve it; 2 when Funnel is on.
serve_check() {
  local json=$1 hp="$2:$3" target=$4 proxy funnel
  proxy=$(jq -r --arg hp "$hp" '(.Web // {})[$hp].Handlers["/"].Proxy // ""' <<<"$json")
  funnel=$(jq -r --arg hp "$hp" '([.AllowFunnel // {}] + [(.Foreground // {})[] | .AllowFunnel // {}]) | add | .[$hp] // false' <<<"$json")
  [ "$proxy" = "$target" ] || return 1
  [ "$funnel" = false ] || return 2
}

# Serves TARGET on https://HOST:PORT to the tailnet. `serve` only touches
# that port, and drops Funnel for it; this never runs `funnel` or `serve
# reset`. Serve can exit 0 without doing anything (HTTPS still being
# enabled), so the result is read back rather than trusted. If Funnel
# is still on afterwards, the port comes off serve before this fails.
serve_https() {
  local host=$1 port=$2 target=$3 json rc=0
  json=$(serve_status_json) || exit 1
  serve_check "$json" "$host" "$port" "$target" || rc=$?
  case $rc in
    0)
      say "https://$host:$port already serves Foreman, tailnet only"
      return 0 ;;
    2) warn "Funnel is on for https://$host:$port, Foreman's port, which puts it on the internet; turning it off" ;;
  esac
  say "serving $target at https://$host:$port, tailnet only"
  with_timeout 60 tailscale serve --bg --https="$port" "$target" </dev/null >/dev/null || true
  json=$(serve_status_json) || exit 1
  rc=0
  serve_check "$json" "$host" "$port" "$target" || rc=$?
  case $rc in
    0) ;;
    2)
      # Not left public: take the port off serve before stopping.
      with_timeout 60 tailscale serve --https="$port" off </dev/null >/dev/null 2>&1 || true
      fail "Funnel stayed on for https://$host:$port, which would put Foreman on the internet, so this took Foreman off that port (tailscale serve --https=$port off). Turn Funnel off (sudo tailscale funnel --https=$port off), check sudo tailscale serve status, and run this again" ;;
    *) fail "tailscale serve didn't take effect on port $port. Check that HTTPS certificates are on (https://login.tailscale.com/admin/dns) and what sudo tailscale serve status shows, then run this again" ;;
  esac
}

# policy_snippet PORT TAGS: the tailnet policy pieces Foreman needs.
# The host tag to grant the UI on: tag:foreman if the host has it.
host_tag() {
  case ",$1," in
    ,,) ;;
    *,tag:foreman,*) echo tag:foreman ;;
    *) echo "${1%%,*}" ;;
  esac
}

policy_snippet() {
  local port=$1 tags=$2 host_tag
  host_tag=$(host_tag "$tags")
  cat <<EOF
"tagOwners": {
  "tag:foreman-env": ["autogroup:admin"]
},
"grants": [
  {"src": ["autogroup:member"], "dst": ["tag:foreman-env"], "ip": ["*"]}$([ -z "$host_tag" ] || printf ',\n  {"src": ["autogroup:member"], "dst": ["%s"], "ip": ["%s"]}' "$host_tag" "$port")
],
"ssh": [
  {"action": "accept", "src": ["autogroup:member"], "dst": ["tag:foreman-env"], "users": ["autogroup:nonroot"]}
]
EOF
  if [ -z "$host_tag" ]; then
    echo
    echo "This host isn't tagged: the default allow-all policy lets your machines reach it."
    echo "With a custom policy, tag it (tag:foreman) and grant your machines port $port on it."
  else
    echo
    echo "This host is tagged:"
    echo "  $tags"
    echo "If your policy isn't the default allow-all, the second grant lets your"
    echo "machines open the UI on port $port."
  fi
}

# tagged_host_note TAGS PORT
tagged_host_note() {
  explain "This host is tagged ($1)."
  explain <<EOF
If your policy isn't the default allow-all, grant your machines port $2
on it, or the UI won't load from them:
  {"src": ["autogroup:member"], "dst": ["$(host_tag "$1")"], "ip": ["$2"]}
EOF
}

# -- settings ----------------------------------------------------------------

# env_get FILE KEY: the last value of KEY; fails if it isn't there.
env_get() {
  [ -r "$1" ] || return 1
  local line
  line=$(grep -E "^$2=" "$1" | tail -n 1) || return 1
  [ -n "$line" ] || return 1
  printf '%s\n' "${line#*=}"
}

# write_temp FILE MODE CONTENT: writes CONTENT to a temp file beside
# FILE (named in WRITTEN_TMP) and reads it back, failing if it doesn't
# match: a full disk can cut a write short. Each step is checked by
# hand, because a caller in a condition runs with errexit off.
write_temp() {
  local file=$1 mode=$2 content=$3 dir
  dir=$(dirname "$file")
  [ -d "$dir" ] || install -d -m 0700 "$dir" || fail "couldn't create $dir"
  WRITTEN_TMP=$(mktemp "$dir/.$(basename "$file").XXXXXX") || fail "couldn't write $file (is the disk full?); it's unchanged"
  CLEANUP+=("$WRITTEN_TMP")
  if ! chmod "$mode" "$WRITTEN_TMP" || ! printf '%s' "$content" >"$WRITTEN_TMP" ||
    [ "$(cat "$WRITTEN_TMP" && echo .)" != "$content." ]; then
    rm -f "$WRITTEN_TMP"
    fail "couldn't write $file (is the disk full?); it's unchanged"
  fi
}

# replace_with TMP FILE: moves write_temp's file over FILE, root-owned
# when running as root.
replace_with() {
  if [ "$(id -u)" -eq 0 ] && ! chown 0:0 "$1"; then
    rm -f "$1"
    fail "couldn't write $2 (chown failed); it's unchanged"
  fi
  mv -f "$1" "$2" || { rm -f "$1"; fail "couldn't replace $2; it's unchanged"; }
}

# env_file_intact OLD NEW KEY=VALUE...: 0 when NEW has every key OLD has,
# each KEY with its VALUE, and OLD's secrets as they were. The last check
# before NEW replaces OLD.
env_file_intact() {
  local old=$1 new=$2 pair key keys current
  shift 2
  [ -r "$new" ] || return 1
  if [ -e "$old" ]; then
    keys=$(sed -n 's/^\([A-Za-z0-9_][A-Za-z0-9_]*\)=.*/\1/p' "$old") || return 1
    for key in $keys; do
      grep -q "^$key=" "$new" || return 1
    done
    for key in $PROTECTED_KEYS; do
      current=$(env_get "$old" "$key") || continue
      [ -z "$current" ] || [ "$(env_get "$new" "$key" || true)" = "$current" ] || return 1
    done
  fi
  for pair in "$@"; do
    current=$(env_get "$new" "${pair%%=*}") || return 1
    [ "$current" = "${pair#*=}" ] || return 1
  done
}

# env_set FILE KEY=VALUE...: replaces or adds each key, keeping every
# other line. Values are written raw (compose's env_file format: raw), so
# no quotes. The new file is written beside the old one, checked, and
# moved over it, 0600, so a crash or a full disk never leaves half a
# file. Refuses to change a secret that's already set: a new
# FOREMAN_ENCRYPTION_KEY loses every secret in the database.
env_set() {
  eval "$UNTRACED"
  local file=$1 pair key value current line i matched out=""
  shift
  [ $# -gt 0 ] || return 0
  local -a keys=() values=() written=()
  for pair in "$@"; do
    key=${pair%%=*}
    value=${pair#*=}
    case "$key" in "" | *[!A-Za-z0-9_]*) fail "bad setting name: $key" ;; esac
    case "$value" in *$'\n'* | *$'\r'*) fail "$key can't contain a line break" ;; esac
    if [[ "$PROTECTED_KEYS" == *" $key "* ]] && current=$(env_get "$file" "$key") &&
      [ -n "$current" ] && [ "$current" != "$value" ]; then
      fail "refusing to replace $key in $file: data encrypted with the old value would be lost"
    fi
    keys+=("$key")
    values+=("$value")
    written+=("")
  done
  if [ -e "$file" ]; then
    [ -r "$file" ] || fail "can't read $file"
    while IFS= read -r line || [ -n "$line" ]; do
      matched=""
      if [[ "$line" == *=* ]]; then
        for i in "${!keys[@]}"; do
          if [ "${line%%=*}" = "${keys[$i]}" ]; then
            matched=1
            if [ -z "${written[$i]}" ]; then
              out+="${keys[$i]}=${values[$i]}"$'\n'
              written[i]=1
            fi
            break
          fi
        done
      fi
      [ -n "$matched" ] || out+="$line"$'\n'
    done <"$file" || fail "can't read $file"
  fi
  for i in "${!keys[@]}"; do
    [ -n "${written[$i]}" ] || out+="${keys[$i]}=${values[$i]}"$'\n'
  done
  write_temp "$file" 0600 "$out"
  if ! env_file_intact "$file" "$WRITTEN_TMP" "$@"; then
    rm -f "$WRITTEN_TMP"
    fail "couldn't write $file: the new copy lost settings; it's unchanged"
  fi
  replace_with "$WRITTEN_TMP" "$file"
}

# Generates SECRET_KEY_BASE and FOREMAN_ENCRYPTION_KEY if they're missing,
# and leaves them alone if they're there.
ensure_secrets() {
  eval "$UNTRACED"
  local file=$1
  local -a pairs=()
  [ -n "$(env_get "$file" SECRET_KEY_BASE || true)" ] ||
    pairs+=("SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')")
  [ -n "$(env_get "$file" FOREMAN_ENCRYPTION_KEY || true)" ] ||
    pairs+=("FOREMAN_ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d '\n')")
  [ ${#pairs[@]} -eq 0 ] || env_set "$file" "${pairs[@]}"
}

# The value of KEY in the foreman container's environment, if there's
# one. Callers keep it to themselves: it's usually a secret.
container_env_value() {
  eval "$UNTRACED"
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" 2>/dev/null |
    sed -n "s/^$1=//p" | tail -n 1
}

# Makes sure the settings file has the secrets the data needs. A secret
# the file lacks is taken from the running container when it has one.
# A new FOREMAN_ENCRYPTION_KEY next to an existing foreman-data volume
# can't read anything encrypted with the old one, so that needs
# FOREMAN_NEW_SECRETS=yes (or a yes on the terminal), and a file whose
# key differs from the one the container runs with is refused.
settle_secrets() {
  eval "$UNTRACED"
  local file=$1 key current live missing="" taken=""
  local -a adopt=()
  for key in $PROTECTED_KEYS; do
    current=$(env_get "$file" "$key" || true)
    live=$(container_env_value "$key" || true)
    if [ -n "$current" ]; then
      if [ "$key" = FOREMAN_ENCRYPTION_KEY ] && [ -n "$live" ] && [ "$live" != "$current" ]; then
        fail "the $CONTAINER container runs with a different FOREMAN_ENCRYPTION_KEY than $file has; applying the file would make its encrypted data unreadable. Put the right key in $file (sudo docker inspect $CONTAINER shows the one in use) and run this again"
      fi
    elif [ -n "$live" ]; then
      adopt+=("$key=$live")
      taken="$taken $key"
    else
      missing="$missing $key"
    fi
  done
  if [ ${#adopt[@]} -gt 0 ]; then
    env_set "$file" "${adopt[@]}"
    say "took$taken from the running $CONTAINER container ($file didn't have it)"
  fi
  if [ -z "$missing" ]; then
    [ -n "$taken" ] || say "keeping the secrets already in $file"
    return 0
  fi
  if [[ "$missing" == *FOREMAN_ENCRYPTION_KEY* ]] && docker volume inspect foreman-data >/dev/null 2>&1; then
    warn "there's a foreman-data volume but $file has no FOREMAN_ENCRYPTION_KEY. A new key can't read anything encrypted with the old one."
    confirm FOREMAN_NEW_SECRETS "Generate a new key anyway (restore the old file from backup instead if you can)?" n ||
      fail "restore $file (or its FOREMAN_ENCRYPTION_KEY) from your backup and run this again; FOREMAN_NEW_SECRETS=yes makes new secrets anyway"
  fi
  say "generating$missing"
  ensure_secrets "$file"
}

base_url_for() { # HOST PORT
  if [ "$2" = 443 ]; then echo "https://$1"; else echo "https://$1:$2"; fi
}

# merge_origins EXISTING ORIGIN: EXISTING (a comma list) with ORIGIN added
# once.
merge_origins() {
  local existing=$1 origin=$2 item
  local IFS=,
  for item in $existing; do
    if [ "$(trim "$item")" = "$origin" ]; then
      printf '%s\n' "$existing"
      return 0
    fi
  done
  if [ -z "$existing" ]; then echo "$origin"; else echo "$existing,$origin"; fi
}

# drop_origin EXISTING ORIGIN: EXISTING (a comma list) without ORIGIN.
drop_origin() {
  local existing=$1 origin=$2 item out=""
  local IFS=,
  for item in $existing; do
    item=$(trim "$item")
    if [ -z "$item" ] || [ "$item" = "$origin" ]; then continue; fi
    out=${out:+$out,}$item
  done
  printf '%s\n' "$out"
}

# The settings that follow from the tailnet name and the serve port. On a
# port other than 443 the base URL (given to GitHub and agents) has to
# carry it, and so does the origin LiveView's websocket checks.
write_host_settings() {
  local file=$1 host=$2 port=$3 base
  base=$(base_url_for "$host" "$port")
  set -- PHX_HOST="$host" FOREMAN_LISTEN_IP=0.0.0.0 FOREMAN_BASE_URL="$base"
  if [ "$port" != 443 ]; then
    set -- "$@" FOREMAN_EXTRA_ORIGINS="$(merge_origins "$(env_get "$file" FOREMAN_EXTRA_ORIGINS || true)" "$base")"
  fi
  env_set "$file" "$@"
}

is_placeholder() { case "$1" in __*__) return 0 ;; esac; return 1; }

# resolve_image PINNED: --image, else the repo at --version or the
# release this copy was rendered for, else what a previous run pinned.
resolve_image() {
  local pinned=$1 repo=$RELEASE_IMAGE version=${FOREMAN_VERSION:-}
  if [ -n "${FOREMAN_IMAGE:-}" ]; then
    echo "$FOREMAN_IMAGE"
    return 0
  fi
  is_placeholder "$repo" && repo=$DEFAULT_IMAGE_REPO
  if [ -z "$version" ] && ! is_placeholder "$RELEASE_VERSION"; then version=$RELEASE_VERSION; fi
  if [ -z "$version" ]; then
    if [ -n "$pinned" ]; then
      echo "$pinned"
      return 0
    fi
    fail "no version to install: pass --version X.Y.Z, or use the installer attached to a release"
  fi
  version=${version#v}
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "--version $version isn't X.Y.Z"
  echo "$repo:$version"
}

# resolve_public_key EXISTING: --public-key, else the release's, else the
# one already in the settings file.
resolve_public_key() {
  local existing=$1
  if [ -n "${FOREMAN_AGENT_RELEASE_PUBLIC_KEY:-}" ]; then
    echo "$FOREMAN_AGENT_RELEASE_PUBLIC_KEY"
  elif [ -n "$RELEASE_PUBLIC_KEY" ] && ! is_placeholder "$RELEASE_PUBLIC_KEY"; then
    echo "$RELEASE_PUBLIC_KEY"
  elif [ -n "$existing" ]; then
    echo "$existing"
  else
    ask FOREMAN_AGENT_RELEASE_PUBLIC_KEY "Agent release public key (the repo's FOREMAN_RELEASE_PUBLIC_KEY variable: gh variable get FOREMAN_RELEASE_PUBLIC_KEY -R ntodd/foreman)"
    echo "$FOREMAN_AGENT_RELEASE_PUBLIC_KEY"
  fi
}

# render_compose CONTAINER WITH_KEY(0|1)
render_compose() {
  cat <<EOF
# Foreman's control plane, written by install-control-plane.sh. Running it
# again rewrites this file, so put changes in compose.override.yml beside
# it (compose reads both when run from this directory):
#
#   cd $OPT && sudo docker compose ps
#
# .env beside it pins FOREMAN_IMAGE and FOREMAN_PORT (the loopback port
# tailscale serve forwards to). Settings are in $ETC/foreman.env.
name: foreman

services:
  foreman:
    image: \${FOREMAN_IMAGE:?set FOREMAN_IMAGE in .env}
    container_name: $1
    restart: unless-stopped
    # raw: values reach the app as written (Compose 2.30+).
    env_file:
      - path: $ETC/foreman.env
        format: raw
    ports:
      - "127.0.0.1:\${FOREMAN_PORT:?set FOREMAN_PORT in .env}:4000"
    volumes:
      - foreman-data:/var/lib/foreman
EOF
  if [ "$2" = 1 ]; then
    echo "      - $ETC/github-app.pem:/run/secrets/github-app.pem:ro"
  fi
  cat <<'EOF'

volumes:
  foreman-data:
    name: foreman-data
EOF
}

# -- the control plane -------------------------------------------------------

# image_version REF: the X.Y.Z in REF's tag, or nothing.
image_version() {
  local tag=${1##*:}
  case "$1" in *@*) return 0 ;; esac
  [ "$tag" != "$1" ] || return 0
  tag=${tag#v}
  if [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$tag"; fi
}

# version_cmp A B (both X.Y.Z): -1, 0 or 1.
version_cmp() {
  local i
  local -a a b
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for i in 0 1 2; do
    if [ "${a[i]}" -lt "${b[i]}" ]; then echo -1; return 0; fi
    if [ "${a[i]}" -gt "${b[i]}" ]; then echo 1; return 0; fi
  done
  echo 0
}

# confirm_image_change PINNED IMAGE [RUNNING]: before moving the control
# plane to IMAGE from PINNED (the image $OPT/.env pins) or RUNNING (the
# one the container runs; either can be ahead of the other), asks
# (FOREMAN_UPGRADE=yes unattended) and whether to back up first
# (FOREMAN_BACKUP, default yes), setting BACKUP_FIRST. It runs before
# anything is written, so saying no changes nothing. The new image
# migrates the database as it starts, and migrations don't run
# backwards, so going below the higher of the two also needs
# FOREMAN_DOWNGRADE=yes. An image with no version to read counts as a
# change, asked about as a switch.
confirm_image_change() {
  local pinned=$1 image=$2 running=${3-} from="" to c v highest="" newest="" verb=Upgrade default=n
  to=$(image_version "$image")
  # An upgrade only when the target is newer than every image it replaces.
  for c in "$running" "$pinned"; do
    if [ -z "$c" ] || [ "$c" = "$image" ]; then continue; fi
    [ -n "$from" ] || from=$c
    v=$(image_version "$c")
    if [ -z "$v" ] || [ -z "$to" ] || [ "$(version_cmp "$to" "$v")" != 1 ]; then verb=Switch; fi
  done
  [ -n "$from" ] || return 0
  for c in "$running" "$pinned"; do
    v=$(image_version "$c")
    [ -n "$v" ] || continue
    if [ -z "$highest" ] || [ "$(version_cmp "$v" "$highest")" = 1 ]; then highest=$v newest=$c; fi
  done
  if [ -n "$to" ] && [ -n "$highest" ] && [ "$(version_cmp "$to" "$highest")" = -1 ]; then
    warn "$image is older than $newest, which this host runs or has pinned. Its database has been migrated past what $to knows, and migrations don't run backwards."
    confirm FOREMAN_DOWNGRADE "Downgrade anyway?" n ||
      fail "not downgrading; nothing changed. To go back, restore the backup taken before the upgrade (docs/setup/upgrading.md, Rolling back). FOREMAN_DOWNGRADE=yes downgrades anyway"
  fi
  if [ -n "$running" ] && [ -n "$pinned" ] && [ "$running" != "$pinned" ]; then
    warn "the $CONTAINER container runs $running, but $OPT/.env pins $pinned"
  fi
  explain <<EOF
This moves the control plane
  from $from
  to   $image
The new image migrates the database as it starts, then boxes update to
the agent it carries. Read its release notes first. To hold a box on the
agent it runs, see docs/setup/upgrading.md (step 3).
EOF
  tty_ready && default=y
  confirm FOREMAN_UPGRADE "$verb to $image now?" "$default" ||
    fail "not changing the image; nothing changed. Back up (docs/setup/upgrading.md), then run this again (FOREMAN_UPGRADE=yes when unattended)"
  if confirm FOREMAN_BACKUP "Back up the data and settings to $BACKUPS first (stops the control plane)?" y; then
    BACKUP_FIRST=1
  else
    say "going ahead without a backup"
  fi
}

# snapshot_settings: copies the settings file (and the GitHub App's key)
# to BACKUPS as they are before this run changes them, root only. They
# go with the data backup_data takes, under the same BACKUP_TS.
snapshot_settings() {
  local f
  BACKUP_TS=$(date +%Y%m%d%H%M%S)
  install -d -m 0700 "$BACKUPS" || fail "couldn't create $BACKUPS"
  for f in foreman.env github-app.pem; do
    [ -e "$ETC/$f" ] || continue
    if ! install -m 0600 "$ETC/$f" "$BACKUPS/$f.$BACKUP_TS" || ! cmp -s "$ETC/$f" "$BACKUPS/$f.$BACKUP_TS"; then
      rm -f "$BACKUPS/$f.$BACKUP_TS"
      fail "couldn't back up $ETC/$f to $BACKUPS (is the disk full?); nothing changed"
    fi
  done
}

# backup_data IMAGE: a tarball of the stopped foreman-data volume (WAL
# mode: a live copy can miss writes) beside snapshot_settings' copies.
# IMAGE, already pulled, runs the tar. The container is stopped with
# docker, not compose: a manual install's compose file isn't in $OPT. It
# stays stopped for the recreate that follows. If stopping it or the
# backup fails, the settings file goes back to the snapshot and the
# container is started again, so the control plane runs as it did.
backup_data() {
  local image=$1 ts=$BACKUP_TS out running files tgz f
  tgz="$BACKUPS/foreman-data.$ts.tgz"
  running=$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)
  if [ "$running" = true ]; then
    say "stopping the control plane to back up foreman-data (boxes reconnect once it's back)"
    if ! out=$(docker stop "$CONTAINER" 2>&1 </dev/null); then
      undo_backup "$out" "$running" "couldn't stop the control plane (above)"
    fi
  fi
  if ! out=$(docker run --rm --user 0 --entrypoint tar -v foreman-data:/data:ro -v "$BACKUPS":/backup \
    "$image" czf "/backup/${tgz##*/}" -C /data . 2>&1 </dev/null); then
    rm -f "$tgz"
    undo_backup "$out" "$running" "the backup failed (above)"
  fi
  chmod 0600 "$tgz"
  files="${tgz##*/}"
  for f in foreman.env github-app.pem; do
    if [ -e "$BACKUPS/$f.$ts" ]; then files="$files, $f.$ts"; fi
  done
  say "backed up to $BACKUPS (root only): $files"
}

# undo_backup OUTPUT WAS_RUNNING WHY: shows OUTPUT, puts the settings
# file back as snapshot_settings found it, starts the container if it
# was running, and fails with WHY.
undo_backup() {
  printf '%s\n' "$1" | sed 's/^/  /' >&2
  if [ -e "$BACKUPS/foreman.env.$BACKUP_TS" ]; then
    CLEANUP+=("$ETC/.foreman.env.restore")
    cp -p "$BACKUPS/foreman.env.$BACKUP_TS" "$ETC/.foreman.env.restore" && mv -f "$ETC/.foreman.env.restore" "$ETC/foreman.env"
  fi
  if [ "$2" = true ]; then docker start "$CONTAINER" >/dev/null 2>&1 </dev/null || true; fi
  fail "$3, so nothing changed: the control plane runs as it did, with its old settings"
}

# Root's Docker config, whatever HOME says (sudo -E keeps the caller's),
# so the GHCR login lands where a later plain sudo docker compose pull
# looks for it.
use_root_docker_config() {
  local home
  home=$(getent passwd 0 2>/dev/null | cut -d: -f6 || true)
  DOCKER_CONFIG="${home:-/root}/.docker"
  export DOCKER_CONFIG
}

ensure_image() {
  eval "$UNTRACED"
  local image=$1 err
  if docker image inspect "$image" >/dev/null 2>&1; then
    say "$image is already on this host"
    return 0
  fi
  say "pulling $image"
  if err=$(docker pull -q "$image" 2>&1 >/dev/null); then return 0; fi
  case "$image" in ghcr.io/*) ;; *) fail "couldn't pull $image: $err" ;; esac
  case "$err" in
    *unauthorized* | *denied* | *authentication* | *"no basic auth"*) ;;
    *) fail "couldn't pull $image: $err" ;;
  esac
  explain <<EOF
The images are private, so root's Docker needs a GHCR login. Use a
classic personal access token with only read:packages
(https://github.com/settings/tokens/new?scopes=read:packages);
fine-grained tokens can't read packages. Compose runs as root, so a
\`docker login\` you did as your own user doesn't count: this one goes in
${DOCKER_CONFIG:-/root/.docker}/config.json.
EOF
  ask_secret FOREMAN_GHCR_TOKEN "GHCR token (classic, read:packages)"
  ask FOREMAN_GHCR_USER "GitHub login the token belongs to" \
    "$(first_login "${FOREMAN_ADMINS:-$(env_get "$ETC/foreman.env" FOREMAN_ADMINS || true)}")"
  if ! err=$(printf '%s' "$FOREMAN_GHCR_TOKEN" | docker login ghcr.io -u "$FOREMAN_GHCR_USER" --password-stdin 2>&1); then
    fail "GHCR didn't accept the login for $FOREMAN_GHCR_USER: $err"
  fi
  say "logged root's Docker in to ghcr.io as $FOREMAN_GHCR_USER"
  err=$(docker pull -q "$image" 2>&1 >/dev/null) ||
    fail "still couldn't pull $image: $err. The token needs read:packages and its owner needs access to the package"
}

compose() { (cd "$OPT" && env -u FOREMAN_IMAGE -u FOREMAN_PORT docker compose "$@"); }

# What the running container should match: settings, compose files, key.
fingerprint() {
  local f
  for f in "$ETC/foreman.env" "$OPT/compose.yml" "$OPT/.env" "$OPT/compose.override.yml" "$ETC/github-app.pem"; do
    if [ -e "$f" ]; then sha256sum "$f"; fi
  done | sha256sum | cut -d' ' -f1
}

write_compose() {
  local with_key=0 content backup
  [ -e "$ETC/github-app.pem" ] && with_key=1
  install -d -m 0755 "$OPT" || fail "couldn't create $OPT"
  if [ -e "$OPT/compose.yml" ] && ! grep -q 'written by install-control-plane.sh' "$OPT/compose.yml"; then
    backup="$OPT/compose.yml.before-installer.$(date +%Y%m%d%H%M%S)"
    if ! cp -p "$OPT/compose.yml" "$backup" || ! cmp -s "$OPT/compose.yml" "$backup"; then
      fail "couldn't keep a copy of $OPT/compose.yml (is the disk full?); it's unchanged"
    fi
    say "$OPT/compose.yml wasn't written by this installer; kept a copy as $backup"
  fi
  content="$(render_compose "$CONTAINER" "$with_key")"$'\n' || fail "couldn't render compose.yml"
  write_temp "$OPT/compose.yml" 0644 "$content"
  replace_with "$WRITTEN_TMP" "$OPT/compose.yml"
}

wait_healthy() { # CONTAINER PORT TIMEOUT
  local container=$1 port=$2 timeout=${3:-180} i=0 state restarts
  while [ "$i" -lt "$timeout" ]; do
    if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:$port/healthz" 2>/dev/null; then
      return 0
    fi
    read -r state restarts <<<"$(docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$container" 2>/dev/null || echo missing)"
    case "$state:${restarts:-0}" in
      exited:* | dead:* | missing:* | restarting:* | *:[1-9]*)
        echo "--- the last lines of the control plane's log:" >&2
        docker logs --tail 30 "$container" 2>&1 | sed 's/^/  /' >&2 || true
        fail "the control plane isn't staying up ($state); see: sudo docker logs $container"
        ;;
    esac
    sleep 2
    i=$((i + 2))
  done
  fail "the control plane didn't answer http://127.0.0.1:$port/healthz within ${timeout}s; see: sudo docker logs $container"
}

# Starts or recreates the container when the settings changed since the
# last healthy start. A restart doesn't reread the env file; a new
# container does. Every recreate also issues a new setup token.
# Compose can't take over a foreman container it didn't create (docker
# run, from before 0.3.0).
refuse_foreign_container() {
  local project
  project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$CONTAINER" 2>/dev/null || true)
  if docker inspect "$CONTAINER" >/dev/null 2>&1 && [ "$project" != foreman ]; then
    fail "a container named $CONTAINER already exists and compose didn't create it; stop and remove it (sudo docker rm -f $CONTAINER; the data volume stays) and run this again"
  fi
}

apply_control_plane() {
  local port=$1 fp running
  refuse_foreign_container
  fp=$(fingerprint)
  running=$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)
  if [ "$running" = true ] && [ "$fp" = "$(cat "$OPT/.applied" 2>/dev/null || true)" ]; then
    say "the control plane is already running with these settings"
  else
    say "starting the control plane (docker compose up -d --force-recreate in $OPT)"
    # The new container no longer matches the last healthy start, so if
    # this run fails or is stopped, the next one recreates it.
    rm -f "$OPT/.applied"
    quietly "docker compose up" compose up -d --force-recreate --quiet-pull
  fi
  wait_healthy "$CONTAINER" "$port" "${FOREMAN_HEALTH_TIMEOUT:-180}"
  echo "$fp" >"$OPT/.applied"
  say "the control plane answers on http://127.0.0.1:$port/healthz"
}

setup_token_from_logs() {
  eval "$UNTRACED"
  local token
  token=$(grep -A1 'one-time setup token' | sed -n 's/^ *\([A-Za-z0-9_-]\{20,\}\) *$/\1/p' | tail -n 1) || true
  [ -n "$token" ] || return 1
  echo "$token"
}

# Reads the control plane's log: 0 when every bundled agent registered
# (the latest line for each target), else 1 with the reasons.
bundled_agents_status() {
  awk '
    /bundled agent [^ ]+ for [^ ]+ (is registered|wasn.t registered)/ {
      line = $0
      sub(/^.*bundled agent /, "bundled agent ", line)
      split(line, w, " ")
      last[w[5]] = line
    }
    /couldn.t register the bundled agents/ { err = $0 }
    END {
      bad = 0; n = 0
      for (t in last) { n++; if (last[t] ~ /wasn.t registered/) { print last[t]; bad = 1 } }
      if (err != "") { print err; bad = 1 }
      if (n == 0 && !bad) { print "the log shows no bundled agents being registered"; bad = 1 }
      exit bad
    }'
}

# Runs Elixir in the container without starting the app (#42): a second
# copy of the app would fight the first for the port, and on SQLite
# would run its own Oban leader.
cp_eval() {
  docker exec "$CONTAINER" env -u PHX_SERVER /app/bin/foreman eval "$@"
}

# Mints a join token for a box: needs the admin's user row, which exists
# once they've signed in. Login and box name arrive as argv.
MINT_EXS='
Application.load(:foreman)
{:ok, _} = Application.ensure_all_started([:ecto_sql, :cloak])
{:ok, _, _} =
  Ecto.Migrator.with_repo(Foreman.Repo, fn _repo ->
    {:ok, _} = Foreman.Vault.start_link()
    [login, name] = System.argv()
    case Foreman.Accounts.get_user_by_login(login) do
      nil -> IO.puts("ERR no-user")
      user ->
        case Foreman.Boxes.create_join_token(Foreman.Scope.for_user(user), %{"box_name" => name}) do
          {:ok, token} -> IO.puts("TOKEN " <> token)
          {:error, :unauthorized} -> IO.puts("ERR not-admin")
          {:error, cs} -> IO.puts("ERR invalid " <> inspect(cs.errors))
        end
    end
  end)
'

# Checks the Tailscale OAuth client: listing devices proves the client
# works, and an auth key for tag:foreman-env proves the key scope and the
# tag's tagOwners entry. The key is unused and expires in five minutes.
TAILSCALE_CHECK_EXS='
Application.ensure_all_started(:req)
alias Foreman.Tailscale
case Tailscale.creds() do
  nil -> IO.puts("TSCHECK no-creds")
  creds ->
    client = Tailscale.Client.impl()
    case client.list_devices(creds) do
      {:ok, _} ->
        tags = Enum.uniq([Tailscale.marker_tag() | Tailscale.base_tags()])
        case client.create_auth_key(creds, %{tags: tags, description: "foreman installer check", expiry_seconds: 300}) do
          {:ok, _} -> IO.puts("TSCHECK ok")
          {:error, {:http, status, msg}} -> IO.puts("TSCHECK key #{status} #{inspect(msg)}")
          other -> IO.puts("TSCHECK key error #{inspect(other)}")
        end
      {:error, {:http, status, msg}} -> IO.puts("TSCHECK devices #{status} #{inspect(msg)}")
      other -> IO.puts("TSCHECK devices error #{inspect(other)}")
    end
end
'

# parse_mint OUTPUT: prints the token (0), or returns 3 (no such user),
# 4 (not an admin), 5 (bad box name) or 1.
parse_mint() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "TOKEN fj_"*) echo "${line#TOKEN }"; return 0 ;;
      "ERR no-user"*) return 3 ;;
      "ERR not-admin"*) return 4 ;;
      "ERR invalid"*) echo "${line#ERR invalid }"; return 5 ;;
    esac
  done <<<"$1"
  return 1
}

box_name_from_hostname() {
  local name
  name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' |
    sed -e 's/[^a-z0-9-]/-/g' -e 's/--*/-/g' -e 's/^-*//' | cut -c1-63 | sed 's/-*$//')
  echo "${name:-box}"
}

valid_box_name() { [[ "$1" =~ $BOX_NAME_RE ]]; }

first_login() { trim "${1%%,*}"; }

# ~/ is the home of whoever ran sudo, not root's.
expand_home() {
  local home=$HOME
  case "$1" in
    \~/*)
      if [ -n "${SUDO_USER:-}" ]; then
        home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
        home=${home:-/home/$SUDO_USER}
      fi
      printf '%s\n' "$home/${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

http_status() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || true; }

# The SQLite image won't boot with a DATABASE_URL, and this installer
# only sets up the SQLite one.
refuse_postgres() {
  eval "$UNTRACED"
  if [ -n "$(env_get "$1" DATABASE_URL || true)" ]; then
    fail "$1 sets DATABASE_URL: this is a Postgres (team) deployment, which this installer doesn't handle; see docs/setup/team.md"
  fi
}

# -- the steps ---------------------------------------------------------------

preflight() {
  step "Checking this host"
  [ "$(uname -s)" = Linux ] || fail "this installs on Linux"
  command -v systemctl >/dev/null 2>&1 || fail "systemd is required (the box agent runs as a systemd service)"
  case "$(uname -m)" in
    x86_64) ARCH=amd64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *) fail "unsupported architecture $(uname -m)" ;;
  esac
  refuse_postgres "$ETC/foreman.env"
  ensure_packages
  ensure_docker
  ensure_node
  # A key file the settings name but that's gone stops the container (and
  # every eval) at boot.
  local key_file
  key_file=$(env_get "$ETC/foreman.env" FOREMAN_GITHUB_PRIVATE_KEY_FILE 2>/dev/null || true)
  if [ -n "$key_file" ] && [ ! -e "$ETC/github-app.pem" ]; then
    fail "$ETC/foreman.env sets FOREMAN_GITHUB_PRIVATE_KEY_FILE but $ETC/github-app.pem is missing; put the app's key back there (owned by uid 999, mode 0400) or remove the FOREMAN_GITHUB_* lines"
  fi
}

choose_tailnet_and_ports() {
  step "Tailscale and ports"
  explain "Foreman is published on a loopback port and served to the tailnet by" \
    "tailscale serve over HTTPS. It's never put on Funnel."
  tailscale_self
  say "this host is $TS_HOST${TS_TAILNET:+ on the tailnet $TS_TAILNET}"
  confirm FOREMAN_TAILNET_OK "Is that the tailnet your laptops are on?" y ||
    fail "switch tailnets first (tailscale switch --list, then sudo tailscale switch <tailnet>) and run this again"

  local pinned used serve_json forwarded
  serve_json=$(serve_status_json) || exit 1
  SERVE_JSON=$serve_json
  pinned=$(pinned_host_port "$CONTAINER")
  used=$(ports_in_use "$CONTAINER" | tr '\n' ' ')
  # A loopback port serve forwards to is taken even when nothing listens
  # on it, unless it's Foreman's own.
  forwarded=$(serve_loopback_ports "$serve_json" | grep -vxF "${pinned:-none}" | tr '\n' ' ' || true)
  # shellcheck disable=SC2086 # one port per word
  HOST_PORT=$(host_port_choice "${FOREMAN_PORT:-}" "$pinned" $used $forwarded) || exit 1
  TARGET="http://127.0.0.1:$HOST_PORT"
  if [ "$HOST_PORT" != 4000 ] && [ -z "$pinned" ] && [ -z "${FOREMAN_PORT:-}" ]; then
    say "port 4000 is taken here, so the control plane gets 127.0.0.1:$HOST_PORT"
  else
    say "the control plane gets 127.0.0.1:$HOST_PORT"
  fi

  local preferred
  preferred=$(base_url_port "$(env_get "$ETC/foreman.env" FOREMAN_BASE_URL || true)" "$TS_HOST")
  HTTPS_PORT=$(serve_port_choice "$serve_json" "$TS_HOST" "$pinned" "${FOREMAN_HTTPS_PORT:-}" \
    "$preferred" "$used") || exit 1
  BASE_URL=$(base_url_for "$TS_HOST" "$HTTPS_PORT")
  [ -n "${FOREMAN_HTTPS_PORT:-}" ] || port_443_note "$serve_json" "$TS_HOST" "$HTTPS_PORT" "$used"
  say "Foreman will be at $BASE_URL"
}

write_settings() {
  step "Settings ($ETC/foreman.env)"
  local env_file="$ETC/foreman.env" existing_key key old_base old_port
  explain "Root-only (0600). Values are raw: no quotes. Re-running keeps the" \
    "secrets and only replaces the keys it manages."
  install -d -m 0700 "$ETC"
  [ "$(id -u)" -ne 0 ] || chown 0:0 "$ETC"
  settle_secrets "$env_file"

  if [ -z "${FOREMAN_ADMINS:-}" ]; then
    FOREMAN_ADMINS=$(env_get "$env_file" FOREMAN_ADMINS || true)
  fi
  # Without it, the first person to sign in becomes the admin (#30).
  ask FOREMAN_ADMINS "Your GitHub login (Foreman's admin)"
  existing_key=$(env_get "$env_file" FOREMAN_AGENT_RELEASE_PUBLIC_KEY || true)
  key=$(resolve_public_key "$existing_key") || exit 1
  if [ -n "$existing_key" ] && [ "$existing_key" != "$key" ]; then
    say "replacing FOREMAN_AGENT_RELEASE_PUBLIC_KEY with this release's"
  fi
  old_base=$(env_get "$env_file" FOREMAN_BASE_URL || true)
  env_set "$env_file" \
    FOREMAN_ADMINS="$FOREMAN_ADMINS" \
    FOREMAN_AGENT_RELEASE_PUBLIC_KEY="$key" \
    FOREMAN_AGENT_RELEASE_DIR=/var/lib/foreman/releases
  write_host_settings "$env_file" "$TS_HOST" "$HTTPS_PORT"
  if [ -n "$old_base" ] && [ "$old_base" != "$BASE_URL" ]; then
    warn "the base URL changed from $old_base to $BASE_URL; update the GitHub App's URLs (homepage, callback, setup URL) to match"
    old_port=$(base_url_port "$old_base" "$TS_HOST")
    # The same port spelled differently (a trailing slash, :443) isn't a move.
    [ -z "$old_port" ] || [ "$old_port" = "$HTTPS_PORT" ] || old_url_note "$env_file" "$old_base" "$old_port"
  fi
}

# old_url_note FILE OLD_BASE OLD_PORT: what happens to boxes enrolled with
# OLD_BASE now that Foreman is at $BASE_URL. Only when OLD_PORT still
# proxies to Foreman's loopback port is it Foreman's to turn off; anything
# else there belongs to another service, so its origin is dropped.
old_url_note() {
  local file=$1 old_base=$2 old_port=$3 json=${SERVE_JSON:-} what origins
  [ -n "$json" ] || json=$(serve_status_json) || exit 1
  if serves_loopback_port "$json" "$TS_HOST" "$old_port" "$HOST_PORT"; then
    explain "Boxes keep the URL they were enrolled with (FOREMAN_URL in /etc/foreman-agent/agent.env), so tailscale serve still serves Foreman on port $old_port, and $old_base stays an allowed origin. Once every box uses $BASE_URL (edit agent.env, then sudo systemctl restart foreman-agent), stop serving the old port:"
    explain "  sudo tailscale serve --https=$old_port off"
    return 0
  fi
  if [[ " $(serve_used_ports "$json" | tr '\n' ' ') " == *" $old_port "* ]]; then
    what="it serves $(serve_target_at "$json" "$TS_HOST" "$old_port") now"
  else
    what="nothing serves it"
  fi
  warn "$old_base no longer reaches Foreman ($what). Boxes enrolled with it can't reach Foreman until their FOREMAN_URL (in /etc/foreman-agent/agent.env) is $BASE_URL: edit it, then sudo systemctl restart foreman-agent"
  origins=$(env_get "$file" FOREMAN_EXTRA_ORIGINS || true)
  if [ -n "$origins" ] && [ "$(drop_origin "$origins" "$old_base")" != "$origins" ]; then
    env_set "$file" FOREMAN_EXTRA_ORIGINS="$(drop_origin "$origins" "$old_base")"
  fi
}

# The image the foreman container runs, if there's one.
container_image() {
  docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true
}

# The image this host runs now: the one a previous run pinned, else the
# one the foreman container runs (a manual install being taken over), so
# a change of image is asked about either way.
pinned_image() {
  local image
  image=$(env_get "$OPT/.env" FOREMAN_IMAGE || true)
  [ -n "$image" ] || image=$(container_image)
  printf '%s' "$image"
}

# Where compose started the foreman container from, when that isn't $OPT.
old_compose_dir() {
  local dir
  dir=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$CONTAINER" 2>/dev/null || true)
  if [ -n "$dir" ] && [ "$dir" != "$OPT" ]; then printf '%s\n' "$dir"; fi
}

# old_compose_note [DIR]: DIR is old_compose_dir's answer from before the
# container was recreated (afterwards it's $OPT).
old_compose_note() {
  local dir=${1-$(old_compose_dir)}
  [ -n "$dir" ] || return 0
  warn "the control plane was started from $dir; from now on it runs from $OPT. Rename or remove $dir/compose.yml (and the .env beside it), or a docker compose up there brings the old image and settings back"
}

# Settles which image to run and pulls it, before any settings are
# written, so saying no or a failed pull changes nothing.
choose_image() {
  step "The release"
  refuse_foreign_container
  PINNED_IMAGE=$(pinned_image)
  LIVE_IMAGE=$(container_image)
  IMAGE=$(resolve_image "$PINNED_IMAGE") || exit 1
  BACKUP_FIRST="" OLD_COMPOSE_DIR=$(old_compose_dir)
  confirm_image_change "$PINNED_IMAGE" "$IMAGE" "$LIVE_IMAGE"
  ensure_image "$IMAGE"
  [ -z "$BACKUP_FIRST" ] || snapshot_settings
  say "the control plane runs $IMAGE"
}

start_control_plane() {
  step "The control plane"
  [ -z "$BACKUP_FIRST" ] || backup_data "$IMAGE"
  write_compose
  env_set "$OPT/.env" FOREMAN_IMAGE="$IMAGE" FOREMAN_PORT="$HOST_PORT"
  apply_control_plane "$HOST_PORT"
  [ -z "$OLD_COMPOSE_DIR" ] || old_compose_note "$OLD_COMPOSE_DIR"
  check_control_plane_log
}

check_control_plane_log() {
  eval "$UNTRACED"
  local logs reasons
  logs=$(docker logs "$CONTAINER" 2>&1 || true)
  if reasons=$(bundled_agents_status <<<"$logs"); then
    say "the agents in the image are registered"
  else
    warn "the image's agents aren't registered, so boxes have no agent to install:"
    explain "$reasons"
    explain "Check FOREMAN_AGENT_RELEASE_PUBLIC_KEY in $ETC/foreman.env matches the repo's FOREMAN_RELEASE_PUBLIC_KEY."
  fi
  if grep -q 'database is locked' <<<"$logs"; then
    explain "(The 'database is locked' errors in the log during the first migrations are harmless.)"
  fi
}

serve_on_tailnet() {
  step "Serving it on the tailnet"
  serve_https "$TS_HOST" "$HTTPS_PORT" "$TARGET"
  tailscale serve status 2>/dev/null | grep -F "$BASE_URL" | sed 's/^/   /' || true
  if curl -fsS -o /dev/null --max-time 10 --retry 5 --retry-delay 3 --retry-all-errors "$BASE_URL/healthz" 2>/dev/null; then
    say "$BASE_URL/healthz answers through tailscale serve"
  else
    warn "$BASE_URL/healthz didn't answer from this host yet (the first certificate can take a minute); check later with: curl -sS $BASE_URL/healthz"
  fi
  [ -z "$TS_TAGS" ] || tagged_host_note "$TS_TAGS" "$HTTPS_PORT"
}

configure_tailscale_oauth() {
  eval "$UNTRACED"
  step "Tailscale OAuth client"
  local env_file="$ETC/foreman.env" cur_id cur_secret
  cur_id=$(env_get "$env_file" FOREMAN_TAILSCALE_CLIENT_ID || true)
  if [ -n "$cur_id" ]; then
    cur_secret=$(env_get "$env_file" FOREMAN_TAILSCALE_CLIENT_SECRET || true)
    # A client given in the environment replaces the configured one.
    if [ -n "${FOREMAN_TAILSCALE_CLIENT_ID:-}${FOREMAN_TAILSCALE_CLIENT_SECRET:-}" ] &&
      { [ "${FOREMAN_TAILSCALE_CLIENT_ID:-$cur_id}" != "$cur_id" ] ||
        [ "${FOREMAN_TAILSCALE_CLIENT_SECRET:-$cur_secret}" != "$cur_secret" ]; }; then
      say "replacing the OAuth client in $env_file with the one from FOREMAN_TAILSCALE_CLIENT_ID/_SECRET"
      FOREMAN_TAILSCALE_CLIENT_ID=${FOREMAN_TAILSCALE_CLIENT_ID:-$cur_id}
      save_tailscale_oauth
      return 0
    fi
    say "an OAuth client is configured; checking it"
    check_tailscale_oauth && return 0
    if ! tty_ready || ! confirm FOREMAN_TAILSCALE_REPLACE "Enter a different client ID and secret now?" n; then
      return 0
    fi
    TAILSCALE_PENDING=""
    FOREMAN_TAILSCALE_CLIENT_ID="" FOREMAN_TAILSCALE_CLIENT_SECRET=""
    save_tailscale_oauth
    return 0
  fi
  explain <<EOF
Foreman uses an OAuth client to put each environment on the tailnet as
its own node (tag:foreman-env) and to remove it afterwards. Without one,
environments still work; you reach them with docker exec on this host.

1. Add this to your tailnet policy (https://login.tailscale.com/admin/acls):

$(policy_snippet "$HTTPS_PORT" "$TS_TAGS" | sed 's/^/     /')

   The tag has to be in tagOwners before the console offers it.
2. Trust credentials -> Credential -> OAuth
   (https://login.tailscale.com/admin/settings/trust-credentials).
   Scopes: Keys -> Auth Keys: write, and Devices -> Core: write.
   Tag: tag:foreman-env.
3. Copy the client ID and secret; the secret is shown once.
EOF
  if [ "${FOREMAN_TAILSCALE:-}" = skip ]; then
    say "skipping for now; run this again to add it"
    TAILSCALE_PENDING=1
    return 0
  fi
  if [ -z "${FOREMAN_TAILSCALE_CLIENT_ID:-}" ] && ! tty_ready; then
    say "no FOREMAN_TAILSCALE_CLIENT_ID given; skipping for now"
    TAILSCALE_PENDING=1
    return 0
  fi
  if [ -z "${FOREMAN_TAILSCALE_CLIENT_ID:-}" ] &&
    ! confirm FOREMAN_TAILSCALE_NOW "Set up the OAuth client now?" y; then
    say "skipping for now; run this again to add it"
    TAILSCALE_PENDING=1
    return 0
  fi
  save_tailscale_oauth
}

save_tailscale_oauth() {
  eval "$UNTRACED"
  ask FOREMAN_TAILSCALE_CLIENT_ID "OAuth client ID"
  ask_secret FOREMAN_TAILSCALE_CLIENT_SECRET "OAuth client secret"
  env_set "$ETC/foreman.env" \
    FOREMAN_TAILSCALE_CLIENT_ID="$FOREMAN_TAILSCALE_CLIENT_ID" \
    FOREMAN_TAILSCALE_CLIENT_SECRET="$FOREMAN_TAILSCALE_CLIENT_SECRET"
  apply_control_plane "$HOST_PORT"
  check_tailscale_oauth || true
}

check_tailscale_oauth() {
  local out result
  out=$(cp_eval "$TAILSCALE_CHECK_EXS" 2>&1 || true)
  result=$(grep '^TSCHECK ' <<<"$out" | tail -n 1 || true)
  case "$result" in
    "TSCHECK ok")
      say "the OAuth client works: it lists devices and can make tag:foreman-env keys"
      say "(the check left an unused key that expires in five minutes)"
      return 0 ;;
    "TSCHECK devices 401"* | "TSCHECK devices 403"*)
      warn "Tailscale rejected the OAuth client ($result); check FOREMAN_TAILSCALE_CLIENT_ID and _SECRET in $ETC/foreman.env" ;;
    "TSCHECK key"*)
      warn "the OAuth client can't make tag:foreman-env auth keys ($result): give it the Keys -> Auth Keys: write scope and the tag, and check tag:foreman-env is in tagOwners" ;;
    "TSCHECK no-creds")
      warn "the control plane doesn't see the OAuth client; recreate it: cd $OPT && sudo docker compose up -d --force-recreate" ;;
    *)
      warn "couldn't check the OAuth client:"
      explain "$out" ;;
  esac
  explain "Fix them with sudo nano $ETC/foreman.env, then run this again."
  TAILSCALE_PENDING=1
  return 1
}

# Checks the GitHub App's ID and private key with GitHub: an app JWT for
# GET /app, whose client ID should be the configured one. The client
# secret is only used at sign-in, so this can't check it.
GITHUB_CHECK_EXS='
Application.ensure_all_started(:req)
app = Application.get_env(:foreman, :github_app, %{})
client_id = app[:client_id]
result =
  try do
    jwt = Foreman.GitHub.JWT.app_token(app[:app_id], app[:private_key])
    Req.get("https://api.github.com/app",
      auth: {:bearer, jwt},
      retry: false,
      headers: [{"accept", "application/vnd.github+json"}, {"user-agent", "foreman"}]
    )
  rescue
    e -> {:error, Exception.message(e)}
  end
case result do
  {:ok, %{status: 200, body: %{"client_id" => cid} = body}} when cid != client_id ->
    IO.puts("GHCHECK client-id #{cid} #{body["slug"]}")
  {:ok, %{status: 200, body: body}} -> IO.puts("GHCHECK ok #{body["slug"]}")
  {:ok, %{status: status}} -> IO.puts("GHCHECK http #{status}")
  {:error, reason} -> IO.puts("GHCHECK error #{inspect(reason)}")
end
'

# 0 when GitHub accepts the app, 1 when it doesn't, 2 when it couldn't
# be asked.
check_github_app() {
  local out result
  out=$(cp_eval "$GITHUB_CHECK_EXS" 2>&1 || true)
  result=$(grep '^GHCHECK ' <<<"$out" | tail -n 1 || true)
  case "$result" in
    "GHCHECK ok"*)
      say "GitHub accepts the app's ID and key (${result#GHCHECK ok }); the client secret is checked at sign-in"
      return 0 ;;
    "GHCHECK http 401"* | "GHCHECK http 404"*)
      warn "GitHub rejected the app (HTTP ${result#GHCHECK http }): check the App ID (FOREMAN_GITHUB_APP_ID in $ETC/foreman.env) and that $ETC/github-app.pem is that app's private key" ;;
    "GHCHECK client-id"*)
      result=${result#GHCHECK client-id }
      warn "the App ID and key belong to an app with client ID ${result%% *}, not the FOREMAN_GITHUB_CLIENT_ID in $ETC/foreman.env" ;;
    "GHCHECK http"*)
      warn "GitHub answered ${result#GHCHECK }; couldn't check the app"
      return 2 ;;
    *)
      warn "couldn't check the app with GitHub:"
      explain "$out"
      return 2 ;;
  esac
  return 1
}

github_connected() {
  case "$(http_status "http://127.0.0.1:$HOST_PORT/setup")" in
    30*) return 0 ;;
  esac
  return 1
}

configure_github() {
  step "GitHub App"
  if github_connected; then
    say "a GitHub App is configured"
    if [ -n "$(env_get "$ETC/foreman.env" FOREMAN_GITHUB_APP_ID || true)" ]; then
      check_github_app || [ $? -eq 2 ] || GITHUB_PENDING=check
    fi
    return 0
  fi
  explain <<EOF
Foreman signs you in and reads repos through a GitHub App. Use one app
per deployment: Foreman syncs every installation of the app it's given.
  manifest  Foreman's setup page creates it in one click (recommended)
  manual    create it on GitHub yourself and paste its credentials here
  skip      do it later
EOF
  ask FOREMAN_GITHUB_APP "How to create the GitHub App (manifest, manual or skip)" manifest
  case "$FOREMAN_GITHUB_APP" in
    manifest) github_manifest ;;
    manual) github_manual ;;
    skip) say "skipping; run this again, or open $BASE_URL/setup"; GITHUB_PENDING=1 ;;
    *) fail "FOREMAN_GITHUB_APP is manifest, manual or skip, not $FOREMAN_GITHUB_APP" ;;
  esac
}

github_manifest() {
  eval "$UNTRACED"
  local token
  token=$(docker logs "$CONTAINER" 2>&1 | setup_token_from_logs || true)
  explain <<EOF
1. Open $BASE_URL/setup
2. Enter the one-time setup token: ${token:-(not in the log yet; see the command below)}
3. Leave the organization empty for your own account (or enter the org),
   click Create GitHub App on GitHub, then install it on the repos
   Foreman should see.
4. Sign in with GitHub as ${FOREMAN_ADMINS:-your admin login}.

The token changes whenever the container restarts. The current one:
  sudo docker logs foreman 2>&1 | grep -A1 "setup token" | tail -n 1
EOF
  wait_for_github
}

# Waits (on a terminal) for the operator to finish on GitHub.
wait_for_github() {
  if ! tty_ready; then
    GITHUB_PENDING=1
    return 0
  fi
  local answer
  while :; do
    printf 'Press Enter once the app is installed and you have signed in (or type skip): ' >&2
    IFS= read -r answer <&8 || answer=skip
    [ "$answer" != skip ] || { GITHUB_PENDING=1; return 0; }
    if github_connected; then
      say "a GitHub App is configured"
      return 0
    fi
    say "Foreman isn't connected to GitHub yet ($BASE_URL/setup still asks for setup)"
  done
}

github_manual() {
  eval "$UNTRACED"
  local env_file="$ETC/foreman.env" key uid
  explain <<EOF
Create the app at https://github.com/settings/apps/new (or under your
org's Settings -> Developer settings -> GitHub Apps) with:
  GitHub App name   Foreman ($TS_HOST), or anything unique
  Homepage URL      $BASE_URL
  Callback URL      $BASE_URL/auth/github/callback
  Expire user authorization tokens   on
  Setup URL         $BASE_URL/setup/github/installed
  Webhook           Active off (Foreman has no public webhook endpoint)
  Permissions       Repository: Contents, Pull requests, Issues and
                    Workflows read and write; Metadata read.
                    Organization: Members read.
  Events            none
  Where can it be installed   Only on this account
Then generate a client secret and a private key (.pem) on the app's
page, copy the .pem to this host, and install the app on your repos.
EOF
  ask FOREMAN_GITHUB_APP_ID "App ID"
  [[ "$FOREMAN_GITHUB_APP_ID" =~ ^[0-9]+$ ]] || fail "the App ID is a number, not $FOREMAN_GITHUB_APP_ID"
  ask FOREMAN_GITHUB_CLIENT_ID "Client ID"
  ask_secret FOREMAN_GITHUB_CLIENT_SECRET "Client secret"
  ask FOREMAN_GITHUB_KEY_FILE "Path to the private key (.pem) on this host"
  key=$(expand_home "$FOREMAN_GITHUB_KEY_FILE")
  [ -r "$key" ] || fail "can't read $key"
  openssl pkey -in "$key" -noout 2>/dev/null || fail "$key isn't a private key (the .pem GitHub generated)"
  # The container's user reads it; it's uid 999 today, but read it from
  # the image rather than trust that.
  uid=$(docker run --rm --entrypoint id "$IMAGE" -u foreman 2>/dev/null || echo 999)
  CLEANUP+=("$ETC/github-app.pem.new")
  install -m 0400 -o "$uid" -g 0 "$key" "$ETC/github-app.pem.new"
  mv -f "$ETC/github-app.pem.new" "$ETC/github-app.pem"
  say "installed the key as $ETC/github-app.pem (uid $uid, 0400), mounted at /run/secrets/github-app.pem"
  env_set "$env_file" \
    FOREMAN_GITHUB_APP_ID="$FOREMAN_GITHUB_APP_ID" \
    FOREMAN_GITHUB_CLIENT_ID="$FOREMAN_GITHUB_CLIENT_ID" \
    FOREMAN_GITHUB_CLIENT_SECRET="$FOREMAN_GITHUB_CLIENT_SECRET" \
    FOREMAN_GITHUB_PRIVATE_KEY_FILE=/run/secrets/github-app.pem
  write_compose
  apply_control_plane "$HOST_PORT"
  if github_connected; then
    say "a GitHub App is configured"
    if check_github_app || [ $? -eq 2 ]; then
      say "$ETC/github-app.pem is the copy Foreman uses; delete the one at $key once you're done (shred -u $key)"
      say "sign in at $BASE_URL as $FOREMAN_ADMINS"
      wait_for_signin
    else
      explain "Fix the FOREMAN_GITHUB_* values in $env_file (or the key), then run this again."
      GITHUB_PENDING=check
    fi
  else
    warn "the control plane still asks for setup; check the FOREMAN_GITHUB_* values in $ETC/foreman.env"
    GITHUB_PENDING=manual
  fi
}

wait_for_signin() {
  tty_ready || return 0
  local answer
  printf 'Press Enter once you have signed in (or type skip): ' >&2
  IFS= read -r answer <&8 || true
}

enroll_box() {
  eval "$UNTRACED"
  step "This host as a box"
  if [ -s "$AGENT_IDENTITY" ]; then
    say "this host is already enrolled; skipping (the agent updates itself)"
    return 0
  fi
  if [ "${FOREMAN_BOX:-}" = skip ]; then
    say "skipping; run this again to enroll it"
    BOX_PENDING=1
    return 0
  fi
  explain "The agent runs environments on this host. It installs as the foreman" \
    "user in the docker group (root-equivalent on this host)."
  if [ "$(http_status "http://127.0.0.1:$HOST_PORT/agent/releases/latest/linux-$ARCH")" != 200 ]; then
    warn "the control plane has no agent for linux-$ARCH to install (see the agent registration warning above); skipping"
    BOX_PENDING=1
    return 0
  fi
  ask FOREMAN_BOX_NAME "Box name" "$(box_name_from_hostname "$(hostname -s 2>/dev/null || hostname)")"
  valid_box_name "$FOREMAN_BOX_NAME" ||
    fail "box names are lowercase letters, digits and dashes (not starting or ending with one), up to 63 characters: $FOREMAN_BOX_NAME"

  local token="${FOREMAN_JOIN_TOKEN:-}" login out rc
  login=$(first_login "$FOREMAN_ADMINS")
  while [ -z "$token" ]; do
    rc=0
    out=$(cp_eval "$MINT_EXS" "$login" "$FOREMAN_BOX_NAME" 2>&1) || true
    token=$(parse_mint "$out") || rc=$?
    case $rc in
      0) say "made a join token for $FOREMAN_BOX_NAME" ;;
      3) say "$login hasn't signed in to Foreman yet; that creates the account a join token needs" ;;
      4) say "$login isn't an admin. FOREMAN_ADMINS gives the role at sign-in: sign out of Foreman and in again" ;;
      5) fail "Foreman refused the box name $FOREMAN_BOX_NAME: $token" ;;
      *)
        warn "couldn't make a join token:"
        explain "$out" ;;
    esac
    [ $rc -eq 0 ] || token=""
    [ -z "$token" ] || break
    if ! tty_ready; then
      explain "Sign in at $BASE_URL, then run this again (or pass FOREMAN_JOIN_TOKEN from Boxes -> Add a box)."
      BOX_PENDING=1
      return 0
    fi
    local answer
    printf 'Sign in at %s, then press Enter to try again (or type skip): ' "$BASE_URL" >&2
    IFS= read -r answer <&8 || answer=skip
    if [ "$answer" = skip ]; then
      BOX_PENDING=1
      return 0
    fi
  done

  local tmp
  tmp=$(mktemp -d)
  CLEANUP+=("$tmp")
  # Over loopback: it doesn't depend on the tailnet. The script points the
  # agent at the base URL.
  curl -fsS -o "$tmp/install.sh" "http://127.0.0.1:$HOST_PORT/agent/install.sh" ||
    { rm -rf "$tmp"; fail "couldn't fetch the box installer from the control plane"; }
  say "running the box installer from $BASE_URL/agent/install.sh"
  # The token goes in the environment, where other users can't read it
  # (argv shows in ps), unless the control plane's script predates that.
  local -a args=()
  local env_token=$token
  # shellcheck disable=SC2016 # the script's own text
  if ! grep -qF 'TOKEN="${FOREMAN_JOIN_TOKEN:-}"' "$tmp/install.sh"; then
    args=(--token "$token")
    env_token=""
  fi
  if ! FOREMAN_JOIN_TOKEN=$env_token sh "$tmp/install.sh" ${args[@]+"${args[@]}"} </dev/null; then
    rm -rf "$tmp"
    fail "the box installer failed (above). The join token is single-use; run this again for a new one"
  fi
  rm -rf "$tmp"
}

summary() {
  step "Done"
  explain <<EOF
Foreman:  $BASE_URL (tailnet only)
Settings: $ETC/foreman.env (root, 0600)
Compose:  $OPT (compose.yml; .env pins the image)
  cd $OPT && sudo docker compose logs -f

Back up FOREMAN_ENCRYPTION_KEY now: every secret in the database is
encrypted with it, and without it they're gone. The file is root-only:
  sudo cat $ETC/foreman.env

To upgrade, run the next release's installer: it asks first, backs up
the data and settings, and keeps them. The backups go in
  $BACKUPS
Or set FOREMAN_IMAGE in $OPT/.env and run sudo docker compose up -d
there. See docs/setup/upgrading.md.

Containers on this host reach the tailnet as this host, with its grants
(issue #50), environments included. Keep this host's tags to the minimum.
EOF
  if [ -n "${GITHUB_PENDING:-}${TAILSCALE_PENDING:-}${BOX_PENDING:-}" ]; then
    echo
    explain "Still to do (run this again afterwards; it picks up where it left off):"
    case "${GITHUB_PENDING:-}" in
      "") ;;
      check) item "GitHub didn't accept the app: fix FOREMAN_GITHUB_APP_ID (and the other FOREMAN_GITHUB_* values) in $ETC/foreman.env, or put the app's key in $ETC/github-app.pem" ;;
      manual) item "the control plane didn't take the GitHub App: check the FOREMAN_GITHUB_* values in $ETC/foreman.env" ;;
      *) item "connect GitHub at $BASE_URL/setup, install the app, and sign in" ;;
    esac
    [ -z "${TAILSCALE_PENDING:-}" ] || item "the Tailscale OAuth client"
    [ -z "${BOX_PENDING:-}" ] || item "enroll this host as a box"
  fi
}

main() {
  parse_args "$@"
  [ "$(id -u)" -eq 0 ] || fail "run this as root (sudo)"
  on_exit_cleanup
  umask 022
  use_root_docker_config
  tty_ready || say "no terminal: answers come from flags and environment variables (--help)"
  GITHUB_PENDING="" TAILSCALE_PENDING="" BOX_PENDING=""
  preflight
  choose_tailnet_and_ports
  choose_image
  write_settings
  start_control_plane
  serve_on_tailnet
  # Before GitHub: adding the client recreates the container, which
  # issues a new setup token.
  configure_tailscale_oauth
  configure_github
  enroll_box
  summary
}

[ -n "${FOREMAN_INSTALLER_SOURCED:-}" ] || main "$@"
