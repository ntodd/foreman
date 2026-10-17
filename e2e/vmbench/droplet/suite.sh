#!/bin/bash
# The workloads that fit a small box, run the same way in a container and
# in a VM: microbenchmarks, CPU, memory bandwidth, disk, and a C build.
# Prints one JSON line per measurement.
#   suite.sh <scratch dir> <label> <pass>
set -uo pipefail
scratch=$1 label=$2 pass=$3
here=$(cd "$(dirname "$0")" && pwd)
cpus=${CPUS:-1}
mkdir -p "$scratch"
emit() { printf '{"label":"%s","name":"%s","value":%s,"unit":"%s","rep":%s}\n' "$label" "$1" "$2" "$3" "$pass"; }

cc -O2 -o "$scratch/micro" "$here/micro.c"
MICRO_FAULT_MB=256 "$scratch/micro" "$scratch" | sed "s/^{/{\"label\":\"$label\",/; s/}\$/,\"rep\":$pass}/"

v=$(sysbench cpu --threads=1 --time=10 run | awk '/events per second/ {print $4}')
emit cpu.sysbench_1t_eps "$v" eps
v=$(sysbench memory --memory-block-size=1M --memory-total-size=16G --threads=1 run | awk '/MiB\/sec/ {gsub(/\(/,""); print $(NF-1)}')
emit mem.sysbench_bw_mibs "$v" MiB/s

f() { fio --output-format=json --directory="$scratch" --filename=fio.dat --size=512M --runtime=15 --time_based --ioengine=libaio --direct=1 --group_reporting "$@"; }
v=$(f --name=rr --rw=randread --bs=4k --iodepth=32 | jq '.jobs[0].read.iops'); emit fio.randread_4k_qd32_iops "$v" iops
v=$(f --name=rw --rw=randwrite --bs=4k --iodepth=32 | jq '.jobs[0].write.iops'); emit fio.randwrite_4k_qd32_iops "$v" iops
v=$(f --name=sw --rw=write --bs=1M --iodepth=8 | jq '.jobs[0].write.bw / 1024'); emit fio.seqwrite_1m_mibs "$v" MiB/s
v=$(fio --output-format=json --directory="$scratch" --filename=fsync.dat --size=128M --runtime=15 --time_based --ioengine=sync --name=fs --rw=write --bs=4k --fdatasync=1 | jq '.jobs[0].write.iops'); emit fio.write_4k_fdatasync_iops "$v" iops
rm -f "$scratch/fio.dat" "$scratch/fsync.dat"

rm -rf "$scratch/redis" && mkdir -p "$scratch/redis" && tar -xzf "$here/redis.tar.gz" -C "$scratch/redis" --strip-components=1
t=$(date +%s.%N)
make -C "$scratch/redis" -j"$cpus" MALLOC=libc BUILD_TLS=no >/dev/null 2>&1 && emit c.redis_build_s "$(echo "$(date +%s.%N) - $t" | bc)" s
rm -rf "$scratch/redis"
