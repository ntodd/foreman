#!/bin/bash
# Benchmarks environments in containers against environments in their own
# VMs, on one Linux box with Docker and Incus: a control plane (the release
# image), a git server for the fixture repo (make-repo.sh), and two agents
# from the same release, one per isolation mode, enrolled as two boxes.
#
# Run as root on the box, from a checkout of this repo:
#   e2e/vmbench/bench.sh setup
#   e2e/vmbench/bench.sh run <box> <label> [cpus] [memory_mb] [groups...]
#   e2e/vmbench/bench.sh lifecycle <box> <label> [cpus] [memory_mb]
#   e2e/vmbench/bench.sh down
#
# Boxes are bench-ct (containers) and bench-vm (VMs). Results go to
# $WORK/results/<label>.jsonl, one JSON object per line.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
WORK=${WORK:-/var/lib/vmbench}
AGENT_TARBALL=${AGENT_TARBALL:-/tmp/agent-out/foreman_agent.tar.gz}
CP_IMAGE=${CP_IMAGE:-foreman-cp:bench}
# The address both the box and its VMs reach the git server on.
GIT_HOST=${GIT_HOST:-10.77.0.1}
GIT_PORT=8899
REPS=${REPS:-3}
mkdir -p "$WORK/results"

say() { printf '\n== %s\n' "$*" >&2; }
fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
now() { date +%s.%N; }
since() { echo "$(now) - $1" | bc; }

cp_eval() {
  docker exec -e E2E_ADMIN=bench -e E2E_REPO=acme/vmbench vmbench-cp env -u PHX_SERVER /app/bin/foreman eval \
    "Code.eval_file(\"/e2e/vmbench/eval.exs\"); $1" 2>/dev/null
}

record() { # label name value unit [extra json]
  printf '{"label":"%s","name":"%s","value":%s,"unit":"%s"%s}\n' "$1" "$2" "$3" "$4" "${5:-}" >> "$WORK/results/$1.jsonl"
}

agent_unit() { # name isolation token
  local name=$1 isolation=$2 token=$3
  install -d -m 0700 -o foreman -g foreman "/var/lib/foreman-agent-$name"
  install -d -m 0755 -o foreman -g foreman "/srv/foreman-$name" "/srv/foreman-$name/envs"
  install -d -m 0711 -o foreman -g foreman "/run/foreman-$name"
  install -d -m 0700 -o foreman -g foreman "/run/foreman-$name/envs"
  printf 'd /run/foreman-%s 0711 foreman foreman -\nd /run/foreman-%s/envs 0700 foreman foreman -\n' "$name" "$name" \
    > "/etc/tmpfiles.d/foreman-$name.conf"
  cat > "/etc/foreman-agent/$name.env" <<EOF
FOREMAN_URL=http://127.0.0.1:4000
FOREMAN_JOIN_TOKEN=$token
FOREMAN_DEVCONTAINER_CLI=/opt/foreman-agent/node/node_modules/.bin/devcontainer
FOREMAN_AGENT_DATA_DIR=/var/lib/foreman-agent-$name
FOREMAN_ENVS_ROOT=/srv/foreman-$name/envs
FOREMAN_SECRETS_ROOT=/run/foreman-$name/envs
FOREMAN_ALLOWED_GIT_HOSTS=$GIT_HOST
FOREMAN_INSECURE_GIT_HOSTS=$GIT_HOST
FOREMAN_ISOLATION=$isolation
FOREMAN_VM_PROFILES=foreman-env
HOME=/var/lib/foreman-agent-$name
RELEASE_TMP=/var/lib/foreman-agent-$name/tmp
EOF
  chgrp foreman "/etc/foreman-agent/$name.env"
  chmod 0640 "/etc/foreman-agent/$name.env"
  # The production unit's sandboxing (install.sh), per instance.
  cat > "/etc/systemd/system/foreman-agent-$name.service" <<EOF
[Unit]
Description=Foreman agent ($name)
After=network-online.target docker.service

[Service]
User=foreman
Group=foreman
EnvironmentFile=/etc/foreman-agent/$name.env
ExecStart=/opt/foreman-agent/current/bin/foreman_agent start
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/foreman-agent-$name /srv/foreman-$name /run/foreman-$name /opt/foreman-agent

[Install]
WantedBy=multi-user.target
EOF
}

setup() {
  say "fixture repo and git server"
  sh "$here/make-repo.sh" "$WORK/git" >/dev/null
  systemctl stop vmbench-git 2>/dev/null || true
  systemd-run --unit vmbench-git --quiet python3 -m http.server "$GIT_PORT" --bind 0.0.0.0 --directory "$WORK/git"

  say "control plane"
  if [ ! -f "$WORK/cp.env" ]; then
    {
      echo "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')"
      echo "FOREMAN_ENCRYPTION_KEY=$(openssl rand -base64 32)"
    } > "$WORK/cp.env"
  fi
  docker rm -f vmbench-cp >/dev/null 2>&1 || true
  docker run -d --name vmbench-cp --network host --env-file "$WORK/cp.env" \
    -e PHX_HOST=localhost -e PORT=4000 -e FOREMAN_LISTEN_IP=127.0.0.1 \
    -e FOREMAN_BASE_URL=http://127.0.0.1:4000 -e FOREMAN_FORCE_SSL=false -e FOREMAN_SECURE_COOKIES=false \
    -e FOREMAN_GIT_BASE_URL="http://$GIT_HOST:$GIT_PORT" -e FOREMAN_AGENT_RELEASE_DIR=/var/lib/foreman/releases \
    -v vmbench-cp:/var/lib/foreman -v "$root/e2e:/e2e:ro" "$CP_IMAGE" >/dev/null
  for _ in $(seq 60); do curl -fsS http://127.0.0.1:4000/healthz >/dev/null 2>&1 && break; sleep 2; done

  say "agent release"
  id foreman >/dev/null 2>&1 || useradd --system --home-dir /var/lib/foreman-agent --shell /usr/sbin/nologin foreman
  usermod -aG docker,incus-admin foreman
  install -d -m 0755 -o foreman -g foreman /opt/foreman-agent /opt/foreman-agent/releases
  install -d -m 0750 -o root -g foreman /etc/foreman-agent
  rm -rf /opt/foreman-agent/releases/bench
  install -d -o foreman -g foreman /opt/foreman-agent/releases/bench
  tar -xzf "$AGENT_TARBALL" -C /opt/foreman-agent/releases/bench
  chown -R foreman:foreman /opt/foreman-agent/releases/bench
  ln -sfn releases/bench /opt/foreman-agent/current

  for name in ct vm; do
    systemctl stop "foreman-agent-$name" 2>/dev/null || true
    token=""
    if [ ! -s "/var/lib/foreman-agent-$name/identity.json" ]; then
      token=$(docker exec -e E2E_ADMIN=bench -e E2E_REPO=acme/vmbench -e E2E_BOX="bench-$name" vmbench-cp \
        env -u PHX_SERVER /app/bin/foreman eval 'Code.eval_file("/e2e/seed.exs")' 2>/dev/null | sed -n 's/^E2E_JOIN_TOKEN=//p')
      [ -n "$token" ] || fail "no join token for bench-$name"
    fi
    isolation=container
    [ "$name" = vm ] && isolation=vm
    agent_unit "$name" "$isolation" "$token"
  done
  systemctl daemon-reload
  systemctl start foreman-agent-ct foreman-agent-vm
  for _ in $(seq 60); do
    out=$(cp_eval 'Bench.status()' || true)
    if echo "$out" | grep -q "BOX bench-ct agent=" && echo "$out" | grep -q "BOX bench-vm agent="; then break; fi
    sleep 2
  done
  cp_eval 'Bench.status()'
}

# Waits for an environment's last operation to finish; fails on failure.
wait_op() { # slug timeout
  local slug=$1 timeout=$2 start
  start=$(now)
  while :; do
    line=$(cp_eval "Bench.state(\"$slug\")" | grep '^STATE' || true)
    case "$line" in
      *" succeeded") return 0 ;;
      *" failed" | *" cancelled") cp_eval "Bench.log(\"$slug\")" | tail -30 >&2; fail "$line" ;;
    esac
    [ "$(echo "$(since "$start") > $timeout" | bc)" = 1 ] && fail "timed out waiting for $slug: $line"
    sleep 2
  done
}

last_op_secs() { cp_eval "Bench.ops(\"$1\")" | grep '^OP' | tail -1 | awk '{print $4}'; }

create_env() { # box cpus memory [repo] -> prints "id slug"
  local box=$1 cpus=${2:-nil} memory=${3:-nil} repo=${4:-acme/vmbench} out
  out=$(cp_eval "Bench.create(\"$box\", $cpus, $memory, \"$repo\")" | grep '^ENV=')
  echo "$out" | sed 's/ENV=\([^ ]*\) SLUG=\(.*\)/\1 \2/'
}

# A command line that runs its arguments in the environment's app container.
app_exec() { # box env_id
  local box=$1 id=$2 c
  if [ "$box" = bench-vm ]; then
    c=$(incus exec "fm-$id" -- docker ps -q --filter "label=foreman.env_id=$id" --filter label=com.docker.compose.service=app </dev/null)
    echo "incus exec fm-$id -- docker exec -u vscode -w /workspaces/vmbench -e REPS=$REPS -e BENCH_CPUS=$BENCH_CPUS $c"
  else
    c=$(docker ps -q --filter "label=foreman.env_id=$id" --filter label=com.docker.compose.service=app)
    echo "docker exec -u vscode -w /workspaces/vmbench -e REPS=$REPS -e BENCH_CPUS=$BENCH_CPUS $c"
  fi
}

host_used_mb() { free -m | awk '/^Mem:/ {print $3}'; }

env_memory_mb() { # box env_id
  if [ "$1" = bench-vm ]; then
    # What the box pays: the VM's resident memory, guest kernel and page cache included.
    pid=$(cat "/run/incus/fm-$2/qemu.pid")
    awk '/VmRSS/ {print int($2/1024)}' "/proc/$pid/status"
  else
    docker stats --no-stream --format '{{.MemUsage}}' $(docker ps -q --filter "label=foreman.env_id=$2") |
      awk '{v=$1; if (v ~ /GiB/) {sub("GiB","",v); s+=v*1024} else if (v ~ /MiB/) {sub("MiB","",v); s+=v} else if (v ~ /kB/) {sub("kB","",v); s+=v/1024}} END {print int(s)}'
  fi
}

run() { # box label cpus memory groups...
  local box=$1 label=$2 cpus=${3:-nil} memory=${4:-nil}
  shift 4 || shift $#
  BENCH_CPUS=${BENCH_CPUS:-${cpus%.*}}
  [ "$BENCH_CPUS" = nil ] && BENCH_CPUS=$(nproc)
  : > "$WORK/results/$label.jsonl"

  say "$label: create on $box (cpus=$cpus memory=$memory)"
  local before id slug
  before=$(host_used_mb)
  read -r id slug < <(create_env "$box" "$cpus" "$memory")
  wait_op "$slug" 3600
  record "$label" lifecycle.create_cold_s "$(last_op_secs "$slug")" s
  echo "$id $slug" > "$WORK/results/$label.env"

  say "$label: prep (unpack workloads, warm caches)"
  local x t
  x=$(app_exec "$box" "$id")
  t=$(now)
  $x bench/run.sh prep </dev/null >/dev/null 2>"$WORK/results/$label.prep.log" || fail "prep failed (see $WORK/results/$label.prep.log)"
  record "$label" lifecycle.prep_s "$(since "$t")" s

  sleep 30
  record "$label" mem.env_idle_mb "$(env_memory_mb "$box" "$id")" MB
  record "$label" mem.host_delta_idle_mb "$(( $(host_used_mb) - before ))" MB

  say "$label: workloads (${*:-all})"
  $x bench/run.sh "$@" </dev/null 2>"$WORK/results/$label.run.log" |
    sed "s/^{/{\"label\":\"$label\",/" >> "$WORK/results/$label.jsonl"

  record "$label" mem.env_after_mb "$(env_memory_mb "$box" "$id")" MB
  record "$label" mem.host_delta_after_mb "$(( $(host_used_mb) - before ))" MB
  echo "$WORK/results/$label.jsonl"
}

# Stop, start, restart, a second environment on a box that has built the
# repo once, and destroy.
lifecycle() { # box label cpus memory
  local box=$1 label=$2 cpus=${3:-nil} memory=${4:-nil} id slug
  read -r id slug < "$WORK/results/$label.env"

  for action in stop start restart_all; do
    say "$label: $action"
    cp_eval "Bench.act(\"$slug\", \"$action\")" >/dev/null
    wait_op "$slug" 1800
    record "$label" "lifecycle.${action}_s" "$(last_op_secs "$slug")" s
  done

  say "$label: a second environment of the same repo"
  read -r id2 slug2 < <(create_env "$box" "$cpus" "$memory")
  wait_op "$slug2" 3600
  record "$label" lifecycle.create_second_s "$(last_op_secs "$slug2")" s

  for s in "$slug2" "$slug"; do
    say "$label: destroy $s"
    cp_eval "Bench.act(\"$s\", \"destroy\")" >/dev/null
    t=$(now)
    for _ in $(seq 300); do
      cp_eval 'Bench.status()' | grep -q "ENV $s " || break
      sleep 2
    done
    record "$label" lifecycle.destroy_s "$(since "$t")" s
  done
}

# A new agent build: unpack it and restart both agents.
redeploy() {
  rm -rf /opt/foreman-agent/releases/bench
  install -d -o foreman -g foreman /opt/foreman-agent/releases/bench
  tar -xzf "$AGENT_TARBALL" -C /opt/foreman-agent/releases/bench
  chown -R foreman:foreman /opt/foreman-agent/releases/bench
  systemctl restart foreman-agent-ct foreman-agent-vm
}

down() {
  systemctl stop foreman-agent-ct foreman-agent-vm vmbench-git 2>/dev/null || true
  docker rm -f vmbench-cp >/dev/null 2>&1 || true
}

# Sourced by capabilities.sh for its helpers.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

case "${1:-}" in
  setup) setup ;;
  run) shift; run "$@" ;;
  lifecycle) shift; lifecycle "$@" ;;
  redeploy) redeploy ;;
  down) down ;;
  *) sed -n '2,15p' "$0"; exit 64 ;;
esac
