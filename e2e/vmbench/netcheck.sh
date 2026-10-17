#!/bin/bash
# What an environment can reach on the network, on each kind of box: the
# other environment on the same box, and services on the box itself.
# Run as root after `bench.sh setup`. Prints REACHABLE/BLOCKED per check.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bench.sh
source "$here/bench.sh"
set +e

wait_running() { wait_op "$1" 1800; }

# Runs a TCP connect from an environment's app container: exit 0 if it connects.
probe() { # box env_id host port
  local box=$1 id=$2 host=$3 port=$4 x
  x=$(app_exec "$box" "$id" | sed 's|-w /workspaces/vmbench|-w /|')
  $x timeout 5 bash -c "exec 3<>/dev/tcp/$host/$port" </dev/null >/dev/null 2>&1
}
report() { if probe "$@"; then echo "REACHABLE: $desc"; else echo "BLOCKED:   $desc"; fi; }

BENCH_CPUS=2 REPS=1
# A light fixture with no privileged parts: an app container and a sidecar.
sh "$here/../make-git-fixture.sh" "$WORK/git" >/dev/null
docker exec -e E2E_ADMIN=bench -e E2E_REPO=acme/hello -e E2E_BOX=unused vmbench-cp \
  env -u PHX_SERVER /app/bin/foreman eval 'Code.eval_file("/e2e/seed.exs")' >/dev/null 2>&1

for box in ${BOXES:-bench-ct bench-vm}; do
  say "$box: two environments"
  read -r a_id a_slug < <(create_env "$box" 2 4096 acme/hello)
  read -r b_id b_slug < <(create_env "$box" 2 4096 acme/hello)
  wait_running "$a_slug"
  wait_running "$b_slug"

  if [ "$box" = bench-vm ]; then
    b_ip=$(incus list "fm-$b_id" -f json </dev/null | jq -r '.[0].state.network.enp5s0.addresses[] | select(.family=="inet") | .address')
    gw=10.77.0.1
    # Something listening on the other VM itself (not in its containers).
    incus exec "fm-$b_id" -- sh -c 'nohup python3 -m http.server 7000 >/dev/null 2>&1 &' </dev/null
    desc="$box: the other environment's VM ($b_ip:7000)" report "$box" "$a_id" "$b_ip" 7000
    c=$(incus exec "fm-$b_id" -- docker ps -q --filter label=com.docker.compose.service=app </dev/null)
    b_cip=$(incus exec "fm-$b_id" -- docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c" </dev/null)
  else
    c=$(docker ps -q --filter "label=foreman.env_id=$b_id" --filter label=com.docker.compose.service=app)
    b_cip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c")
    gw=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' \
      "$(docker ps -q --filter "label=foreman.env_id=$a_id" --filter label=com.docker.compose.service=app)")
  fi
  # A server in the other environment's app container (perl comes with git).
  x=$(app_exec "$box" "$b_id" | sed 's|-w /workspaces/vmbench|-w /|')
  $x sh -c "nohup perl -MIO::Socket::INET -e '\$s=IO::Socket::INET->new(LocalPort=>7001,Listen=>5,ReuseAddr=>1) or die; while(\$c=\$s->accept){print \$c qq(ok\\n); close \$c}' >/dev/null 2>&1 & sleep 1" </dev/null
  desc="$box: the other environment's container ($b_cip:7001)" report "$box" "$a_id" "$b_cip" 7001
  desc="$box: the box's git server on its bridge address ($gw:$GIT_PORT)" report "$box" "$a_id" "$gw" "$GIT_PORT"
  desc="$box: the box's sshd ($gw:22)" report "$box" "$a_id" "$gw" 22
  desc="$box: the control plane, bound to the box's loopback ($gw:4000)" report "$box" "$a_id" "$gw" 4000
  desc="$box: the internet (1.1.1.1:443)" report "$box" "$a_id" 1.1.1.1 443

  for s in "$a_slug" "$b_slug"; do cp_eval "Bench.act(\"$s\", \"destroy\")" >/dev/null; done
done
