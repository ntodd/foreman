#!/bin/sh
# End-to-end run of updating the control plane from the Deployment page:
# a control plane host (systemd and its own Docker daemon) running the
# control plane from docker/compose.yml, with the updater installed the way
# docs/setup/upgrading.md says, and a registry holding three versions of
# the control plane image: 0.9.1, 0.9.2 and a 0.9.3 that never starts.
#
# Covers the install, requests the updater must refuse (not a version, a
# symlink, a downgrade, a version that isn't published), an update the
# control plane asks for, and one that fails health checks and is rolled
# back with its data restored.
#
#   e2e/updater/run.sh          build images, run, leave the host up
#   e2e/updater/run.sh --down   tear it down (and its volumes)
#   e2e/updater/run.sh --logs   the host's journal for the updater
#
# The commands in single quotes run on the host.
# shellcheck disable=SC2016
set -eu

cd "$(dirname "$0")/../.."
project=${E2E_PROJECT:-foreman-update-e2e}
work=tmp/$project
export E2E_BOX_IMAGE="$project-box"
cp_image=$project-cp
mkdir -p "$work"
compose="docker compose -p $project -f e2e/updater/compose.yml"

case "${1:-}" in
  --down)
    $compose down --volumes --remove-orphans
    exit 0
    ;;
  --logs)
    $compose exec -T host journalctl --no-pager -o short-iso -u foreman-update -u foreman-update.path -u docker
    exit 0
    ;;
esac

say() { printf '\n== %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

host() { $compose exec -T host "$@"; }

wait_for() {
  desc=$1 timeout=$2
  shift 2
  i=0
  until "$@" > /dev/null 2>&1; do
    i=$((i + 2))
    [ $i -lt "$timeout" ] || fail "timed out waiting for: $desc"
    sleep 2
  done
  echo "ok: $desc"
}

registry=localhost:5000/foreman
dc='docker compose -f /opt/foreman/compose.yml'

ctr() { host sh -c "$dc ps -q foreman"; }
running_image() { host sh -c "docker inspect -f '{{.Config.Image}}' \$($dc ps -q foreman)"; }
healthz() { host curl -fsS -o /dev/null http://127.0.0.1:4000/healthz; }
state() { host sh -c 'cat /var/lib/foreman-update/status/state.json 2>/dev/null' | sed -n 's/.*"state":"\([a-z_]*\)".*/\1/p'; }
state_is() { [ "$(state)" = "$1" ]; }
message() { host cat /var/lib/foreman-update/status/state.json | sed -n 's/.*"message":"\([^"]*\)".*/\1/p'; }
# The updater has run and finished since the state file was last $1.
finished_since() {
  [ "$(host stat -c %Y /var/lib/foreman-update/status/state.json 2>/dev/null || echo 0)" -gt "$1" ] &&
    [ "$(host systemctl show -p ActiveState --value foreman-update.service)" != activating ] &&
    ! state_is running
}
state_mtime() { host stat -c %Y /var/lib/foreman-update/status/state.json 2>/dev/null || echo 0; }

# Helpers inside the control plane, run in a second VM in its container.
cp_eval() {
  out=$(host sh -c "docker exec \$($dc ps -q foreman) env -u PHX_SERVER /app/bin/foreman eval \"\$1\"" sh \
    "$(cat e2e/updater/eval.exs)
$1" 2>&1) || {
    echo "$out" >&2
    fail "eval failed: $1"
  }
  echo "$out" | grep -E '^(SEEDED|USERS|REQUEST|UPDATER)' || true
}

# As the control plane's own user, straight into its request directory.
as_cp() { host sh -c "docker exec \$($dc ps -q foreman) sh -c \"\$1\"" sh "$1"; }

# Asks for $1 as the container could, and waits for the updater to finish.
request_raw() {
  before=$(state_mtime)
  sleep 1
  as_cp "$1"
  wait_for "the updater finished" 600 finished_since "$before"
}

if [ "${SKIP_BUILD:-}" != "1" ]; then
  say "build the control plane (0.9.1, 0.9.2, and a broken 0.9.3) and the host"
  docker build -q -f docker/control-plane.Dockerfile --build-arg FOREMAN_VERSION=0.9.1 -t "$cp_image:0.9.1" . > /dev/null
  # 0.9.2 is 0.9.1 relabelled: the updater goes by the image's version label.
  printf 'FROM %s\nLABEL org.opencontainers.image.version=0.9.2\n' "$cp_image:0.9.1" |
    docker build -q -t "$cp_image:0.9.2" - > /dev/null
  # Writes into the data volume, then exits: the rollback must undo both.
  printf 'FROM %s\nLABEL org.opencontainers.image.version=0.9.3\nCMD ["sh", "-c", "echo 0.9.3 > /var/lib/foreman/broken; exit 1"]\n' "$cp_image:0.9.1" |
    docker build -q -t "$cp_image:0.9.3" - > /dev/null
  docker build -q -f docker/box.Dockerfile --target box -t "$E2E_BOX_IMAGE" . > /dev/null
fi

say "boot the host and fill its registry"
$compose down --volumes --remove-orphans > /dev/null 2>&1 || true
$compose up -d
wait_for "the host's Docker" 120 sh -c "[ \"\$($compose exec -T host systemctl is-active docker)\" = active ]"
host docker run -d --name registry --restart always -p 127.0.0.1:5000:5000 public.ecr.aws/docker/library/registry:2 > /dev/null
docker save "$cp_image:0.9.1" "$cp_image:0.9.2" "$cp_image:0.9.3" | host docker load -q > /dev/null
for v in 0.9.1 0.9.2 0.9.3; do
  host docker tag "$cp_image:$v" "$registry:$v"
  wait_for "pushed $v" 60 host docker push -q "$registry:$v"
  host docker rmi -f "$cp_image:$v" > /dev/null
done
# Pulled from the registry from here on, as on a real host.
host docker rmi "$registry:0.9.2" "$registry:0.9.3" > /dev/null

say "run the control plane from docker/compose.yml"
host mkdir -p /opt/foreman /etc/foreman
$compose cp docker/compose.yml host:/opt/foreman/compose.yml
host sh -c "printf 'FOREMAN_IMAGE=$registry:0.9.1\nOTHER_SETTING=kept\n' > /opt/foreman/.env"
host sh -c 'umask 077 && printf "%s\n" \
  "SECRET_KEY_BASE=$(head -c 48 /dev/urandom | base64 | tr -d "\n")" \
  "FOREMAN_ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)" \
  PHX_HOST=localhost FOREMAN_LISTEN_IP=0.0.0.0 FOREMAN_FORCE_SSL=false FOREMAN_SECURE_COOKIES=false \
  FOREMAN_UPDATE_CHECK=false > /etc/foreman/foreman.env'
host sh -c "$dc up -d --quiet-pull"
wait_for "the control plane is healthy" 180 healthz
cp_eval 'E2E.seed()' | grep -q SEEDED || fail "seed"
cp_eval 'E2E.updater()' | grep -q 'installed=false' || fail "the updater shows as installed before it is"
echo "ok: running 0.9.1, updater not installed"

say "install the updater the way the docs say"
host sh -c 'img=$(docker inspect -f "{{.Config.Image}}" $(docker compose -f /opt/foreman/compose.yml ps -q foreman)) &&
  docker run --rm --entrypoint cat "$img" /app/updater/foreman-update | sh -s -- install /opt/foreman/compose.yml' |
  tee "$work/install.log"
grep -q "installed; update from the Deployment page" "$work/install.log" || fail "install didn't finish"
[ "$(host systemctl is-active foreman-update.path)" = active ] || fail "the path unit isn't active"
[ "$(host systemctl is-enabled foreman-update.path)" = enabled ] || fail "the path unit isn't enabled"
cp_uid=$(host sh -c "docker exec \$($dc ps -q foreman) id -u")
[ "$(host stat -c '%u %a' /var/lib/foreman-update/request)" = "$cp_uid 700" ] || fail "request/ isn't the control plane's"
[ "$(host stat -c '%U %a' /var/lib/foreman-update/status)" = "root 755" ] || fail "status/ isn't root's"
[ "$(host stat -c '%U %a' /var/lib/foreman-update/backups)" = "root 700" ] || fail "backups/ isn't root's alone"
[ "$(host stat -c '%U %a' /usr/local/sbin/foreman-update)" = "root 755" ] || fail "the updater isn't root's"
as_cp 'touch /var/lib/foreman-update/status/x' 2> /dev/null && fail "the control plane can write status/"
cp_eval 'E2E.updater()' | grep -q 'installed=true' || fail "the control plane doesn't see the updater"
echo "ok: installed, the units enabled, request/ the control plane's, status/ read-only to it"
first=$(ctr)

say "requests the updater refuses, changing nothing"
request_raw 'printf "../../../etc/passwd\n" > /var/lib/foreman-update/request/version'
{ state_is failed && message | grep -q "wasn't a version"; } || fail "garbage: $(state) $(message)"
echo "ok: not a version"

request_raw 'ln -s /etc/shadow /var/lib/foreman-update/request/version'
state_is failed || fail "symlink: $(state)"
host grep -q 'root:' /var/lib/foreman-update/status/state.json && fail "the state file has /etc/shadow in it"
echo "ok: a symlink is no request, and nothing it points at is read back"

request_raw 'printf "0.9.0\n" > /var/lib/foreman-update/request/version'
message | grep -q "0.9.0 isn't newer than 0.9.1" || fail "downgrade: $(message)"
echo "ok: no downgrades"

request_raw 'printf "0.9.9\n" > /var/lib/foreman-update/request/version'
message | grep -q "Couldn't pull $registry:0.9.9" || fail "unpublished: $(message)"
echo "ok: a version that isn't published"

[ "$(ctr)" = "$first" ] || fail "a refused request replaced the container"
[ -z "$(host ls -A /var/lib/foreman-update/request)" ] || fail "request/ wasn't emptied"
healthz || fail "0.9.1 isn't healthy after the refusals"
echo "ok: the same container throughout, still healthy, request/ empty"

say "update to 0.9.2 the way the Deployment page asks"
before=$(state_mtime)
sleep 1
cp_eval 'E2E.request("0.9.2")' | grep -q 'REQUEST :ok' || fail "the request wasn't accepted"
wait_for "the update finished" 600 finished_since "$before"
state_is succeeded || fail "update: $(state) $(message)"
[ "$(running_image)" = "$registry:0.9.2" ] || fail "running $(running_image)"
healthz || fail "0.9.2 isn't healthy"
cp_eval 'E2E.users()' | grep -q 'USERS 1' || fail "the data didn't survive"
host grep -qx "FOREMAN_IMAGE=$registry:0.9.2" /opt/foreman/.env || fail ".env doesn't pin 0.9.2"
host grep -qx 'OTHER_SETTING=kept' /opt/foreman/.env || fail ".env lost its other settings"
[ "$(host sh -c 'ls /var/lib/foreman-update/backups/foreman-data-0.9.1-*.tgz | wc -l')" = 1 ] || fail "no backup of 0.9.1"
cp_eval 'E2E.updater()' | grep -q 'state=succeeded' || fail "the control plane doesn't see the result"
echo "ok: 0.9.2 running and healthy, its data kept, .env pinned, 0.9.1 backed up"

say "a version that never comes up is rolled back, data and all"
request_raw 'printf "0.9.3\n" > /var/lib/foreman-update/request/version'
state_is rolled_back || fail "rollback: $(state) $(message)"
[ "$(running_image)" = "$registry:0.9.2" ] || fail "running $(running_image) after the rollback"
wait_for "0.9.2 healthy again" 60 healthz
as_cp 'test -e /var/lib/foreman/broken' && fail "what 0.9.3 wrote to the data volume is still there"
cp_eval 'E2E.users()' | grep -q 'USERS 1' || fail "the data didn't survive the rollback"
host grep -qx "FOREMAN_IMAGE=$registry:0.9.2" /opt/foreman/.env || fail ".env doesn't pin 0.9.2 again"
host grep -qx 'OTHER_SETTING=kept' /opt/foreman/.env || fail ".env lost its other settings"
echo "ok: 0.9.2 back, healthy, the data volume as it was before 0.9.3"

say "the host restarts with the updater still watching"
$compose restart host > /dev/null
wait_for "the host's Docker" 120 sh -c "[ \"\$($compose exec -T host systemctl is-active docker)\" = active ]"
wait_for "the control plane is healthy" 180 healthz
[ "$(host systemctl is-active foreman-update.path)" = active ] || fail "the path unit isn't active after a restart"
[ "$(running_image)" = "$registry:0.9.2" ] || fail "running $(running_image) after a restart"
echo "ok: still 0.9.2, the path unit active"

say "all passed"
