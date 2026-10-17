#!/bin/bash
# Runs inside an environment's app container, as the remote user, from the
# workspace. Prints one JSON line per measurement:
#   {"name": "elixir.compile_clean_s", "value": 41.2, "unit": "s", "rep": 1}
#
#   bench/run.sh prep            unpack workloads and warm caches (network)
#   bench/run.sh [group ...]     run groups (default: all), REPS times each
#
# Groups: micro cpu fio git elixir c node
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
ws=$(cd "$here/.." && pwd)
work="$ws/work"
reps=${REPS:-3}
cpus=${BENCH_CPUS:-$(nproc)}
export MIX_ENV=test FOREMAN_DB=postgres HEX_OFFLINE=1 MIX_OS_DEPS_COMPILE_PARTITION_COUNT=1
export DATABASE_URL=ecto://postgres:postgres@localhost/foreman_test
export EXQLITE_FORCE_BUILD=true

emit() { printf '{"name":"%s","value":%s,"unit":"%s","rep":%s}\n' "$1" "$2" "$3" "${4:-0}"; }
now() { date +%s.%N; }
since() { echo "$(now) - $1" | bc; }
log() { echo "# $*" >&2; }

# Times a command; the command's output goes to stderr.
timed() {
  local name=$1 rep=$2
  shift 2
  local t
  t=$(now)
  if "$@" >&2; then
    emit "$name" "$(since "$t")" s "$rep"
  else
    log "FAILED: $name (rep $rep)"
    emit "$name.failed" 1 bool "$rep"
  fi
}

prep() {
  mkdir -p "$work"
  cd "$work" || exit 1
  log "unpacking workloads"
  rm -rf foreman redis node
  mkdir foreman && tar -xzf "$ws/workloads/foreman.tar.gz" -C foreman
  mkdir redis && tar -xzf "$ws/workloads/redis.tar.gz" -C redis --strip-components=1
  cp -r "$ws/workloads/node" node
  cc -O2 -o "$work/micro" "$here/micro.c"
  log "hex, rebar and the NIF caches (network)"
  HEX_OFFLINE=0 mix local.hex --force >&2
  HEX_OFFLINE=0 mix local.rebar --force >&2
  (cd foreman/apps/foreman && HEX_OFFLINE=0 mix compile >&2)
  (cd node && npm ci --no-audit --no-fund >&2)
  log "prep done"
}

group_micro() {
  for rep in $(seq 1 "$reps"); do
    "$work/micro" "$work" | sed "s/}\$/,\"rep\":$rep}/"
  done
}

group_cpu() {
  for rep in $(seq 1 "$reps"); do
    v=$(sysbench cpu --threads=1 --time=10 run | awk '/events per second/ {print $4}')
    emit cpu.sysbench_1t_eps "$v" eps "$rep"
    v=$(sysbench cpu --threads="$cpus" --time=10 run | awk '/events per second/ {print $4}')
    emit cpu.sysbench_nt_eps "$v" eps "$rep"
    v=$(sysbench memory --memory-block-size=1M --memory-total-size=32G --threads=1 run | awk '/MiB\/sec/ {gsub(/\(/,""); print $(NF-1)}')
    emit mem.sysbench_bw_mibs "$v" MiB/s "$rep"
  done
}

fio_json() {
  fio --output-format=json --directory="$work" --filename=fio.dat --size=2G --runtime=15 --time_based \
    --ioengine=libaio --direct=1 --group_reporting "$@"
}

group_fio() {
  for rep in $(seq 1 "$reps"); do
    v=$(fio_json --name=rr --rw=randread --bs=4k --iodepth=32 --numjobs=1 | jq '.jobs[0].read.iops')
    emit fio.randread_4k_qd32_iops "$v" iops "$rep"
    v=$(fio_json --name=rr1 --rw=randread --bs=4k --iodepth=1 --numjobs=1 | jq '.jobs[0].read.clat_ns.mean / 1000')
    emit fio.randread_4k_qd1_lat_us "$v" us "$rep"
    v=$(fio_json --name=rw --rw=randwrite --bs=4k --iodepth=32 --numjobs=1 | jq '.jobs[0].write.iops')
    emit fio.randwrite_4k_qd32_iops "$v" iops "$rep"
    v=$(fio_json --name=sw --rw=write --bs=1M --iodepth=8 --numjobs=1 | jq '.jobs[0].write.bw / 1024')
    emit fio.seqwrite_1m_mibs "$v" MiB/s "$rep"
    v=$(fio_json --name=sr --rw=read --bs=1M --iodepth=8 --numjobs=1 | jq '.jobs[0].read.bw / 1024')
    emit fio.seqread_1m_mibs "$v" MiB/s "$rep"
    v=$(fio --output-format=json --directory="$work" --filename=fio-sync.dat --size=256M --runtime=15 --time_based \
      --ioengine=sync --name=fsync --rw=write --bs=4k --fdatasync=1 | jq '.jobs[0].write.iops')
    emit fio.write_4k_fdatasync_iops "$v" iops "$rep"
    rm -f "$work/fio.dat" "$work/fio-sync.dat"
  done
}

group_git() {
  for rep in $(seq 1 "$reps"); do
    rm -rf "$work/gitrepo" && mkdir -p "$work/gitrepo"
    tar -xzf "$ws/workloads/foreman.tar.gz" -C "$work/gitrepo"
    cd "$work/gitrepo" || exit 1
    git init -q && git config user.email b@b && git config user.name b
    timed git.add_commit_s "$rep" sh -c 'git add -A -f && git commit -qm bench'
    timed git.status_x20_s "$rep" sh -c 'for i in $(seq 20); do git status --porcelain >/dev/null; done'
    timed git.clone_local_s "$rep" git clone -q --no-hardlinks "$work/gitrepo" "$work/gitclone"
    cd "$work" && rm -rf "$work/gitrepo" "$work/gitclone"
  done
}

group_elixir() {
  cd "$work/foreman/apps/foreman" || exit 1
  for rep in $(seq 1 "$reps"); do
    rm -rf _build ../foreman_protocol/_build
    timed elixir.compile_clean_s "$rep" mix compile
    touch lib/foreman_web.ex
    timed elixir.compile_touch_core_s "$rep" mix compile
    mix ecto.drop --quiet >/dev/null 2>&1
    timed elixir.test_s "$rep" mix test --seed 0 --max-cases "$cpus"
  done
}

group_c() {
  cd "$work/redis" || exit 1
  for rep in $(seq 1 "$reps"); do
    make distclean >/dev/null 2>&1
    timed c.redis_build_s "$rep" make -j"$cpus" MALLOC=libc BUILD_TLS=no
  done
}

group_node() {
  cd "$work/node" || exit 1
  for rep in $(seq 1 "$reps"); do
    rm -rf node_modules
    timed node.npm_ci_offline_s "$rep" npm ci --prefer-offline --no-audit --no-fund
    rm -rf dist
    timed node.tsc_s "$rep" npx tsc -p .
    timed node.vite_build_s "$rep" npx vite build --logLevel error
  done
}

if [ "${1:-}" = "prep" ]; then
  prep
  exit 0
fi

groups=${*:-micro cpu fio git elixir c node}
for g in $groups; do
  log "group $g"
  "group_$g"
done
