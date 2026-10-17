#!/bin/bash
# Container vs VM on a small cloud box that already runs other things (a
# live control plane, an environment). Everything lives in one throwaway
# directory and two Docker containers, so the box gets no new packages:
# QEMU runs inside a container with /dev/kvm passed through.
#
#   run.sh [passes]       results in $W/results.jsonl
#   run.sh --clean        remove the directory, containers and image
#
# Passes alternate container and VM, so drift on a shared CPU hits both.
set -euo pipefail

W=${W:-/root/vmbench-tmp}
MEM_MB=${MEM_MB:-640}
CPUS=${CPUS:-1}
PASSES=${1:-3}
here=$(cd "$(dirname "$0")" && pwd)
ssh_opts=(-q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 -i "$W/key" -p 2222)

clean() {
  docker rm -f vmbench-vm >/dev/null 2>&1 || true
  docker rmi -f vmbench-tools >/dev/null 2>&1 || true
  rm -rf "$W"
}
if [ "${1:-}" = "--clean" ]; then clean; exit 0; fi

avail_mb() { awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo; }
guard() {
  # Leave the box's own services room: abort before the VM would squeeze them.
  if [ "$(avail_mb)" -lt $((MEM_MB + 350)) ]; then
    echo "only $(avail_mb) MB available; need $((MEM_MB + 350)). Not starting." >&2
    exit 1
  fi
}

mkdir -p "$W"
cp "$here/suite.sh" "$here/micro.c" "$W/"
[ -f "$W/redis.tar.gz" ] || curl -fsSL -o "$W/redis.tar.gz" https://download.redis.io/releases/redis-7.4.6.tar.gz

cat > "$W/Dockerfile" <<'EOF'
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential sysbench fio bc jq curl ca-certificates \
    qemu-system-x86 qemu-utils cloud-image-utils openssh-client \
  && rm -rf /var/lib/apt/lists/*
EOF
docker build -q -t vmbench-tools "$W" >/dev/null

# The VM: Ubuntu's cloud image with the same tools, 1 vCPU and MEM_MB.
if [ ! -f "$W/base.img" ]; then
  curl -fsSL -o "$W/base.img" https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img
fi
[ -f "$W/key" ] || ssh-keygen -q -t ed25519 -N "" -f "$W/key"
cat > "$W/user-data" <<EOF
#cloud-config
users:
  - name: dev
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: [$(cat "$W/key.pub")]
package_update: true
packages: [build-essential, sysbench, fio, bc, jq]
EOF
printf 'instance-id: vmbench\nlocal-hostname: vmbench\n' > "$W/meta-data"

tools() { docker run --rm -v "$W:/w" -w /w vmbench-tools "$@"; }
tools cloud-localds /w/seed.img /w/user-data /w/meta-data
tools qemu-img create -q -f qcow2 -F qcow2 -b /w/base.img /w/vm.qcow2 12G

start_vm() {
  guard
  docker rm -f vmbench-vm >/dev/null 2>&1 || true
  docker run -d --name vmbench-vm --network host --device /dev/kvm -v "$W:/w" vmbench-tools \
    qemu-system-x86_64 -enable-kvm -cpu host -smp "$CPUS" -m "$MEM_MB" -display none \
    -drive file=/w/vm.qcow2,if=virtio,cache=none,aio=native -drive file=/w/seed.img,if=virtio,format=raw \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 \
    -serial file:/w/serial.log >/dev/null
  local t=$SECONDS
  until ssh "${ssh_opts[@]}" dev@127.0.0.1 true 2>/dev/null; do
    [ $((SECONDS - t)) -lt 600 ] || { echo "VM didn't come up" >&2; exit 1; }
    sleep 1
  done
  echo $((SECONDS - t))
}

out="$W/results.jsonl"
: > "$out"
emit() { printf '{"label":"%s","name":"%s","value":%s,"unit":"%s"}\n' "$1" "$2" "$3" "$4" >> "$out"; }

echo "first boot (cloud-init installs the tools)" >&2
emit vm boot.first_ssh_s "$(start_vm)" s
ssh "${ssh_opts[@]}" dev@127.0.0.1 'cloud-init status --wait >/dev/null; mkdir -p ~/w'
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$W/key" -P 2222 \
  "$W/suite.sh" "$W/micro.c" "$W/redis.tar.gz" dev@127.0.0.1:w/
ssh "${ssh_opts[@]}" dev@127.0.0.1 'sudo poweroff' || true
sleep 5
echo "second boot" >&2
emit vm boot.ssh_s "$(start_vm)" s

for pass in $(seq 1 "$PASSES"); do
  echo "pass $pass: container" >&2
  docker run --rm --cpus "$CPUS" --memory "${MEM_MB}m" -e CPUS="$CPUS" -v "$W:/w" -w /w vmbench-tools \
    bash /w/suite.sh /w/scratch-ct ct "$pass" >> "$out"
  echo "pass $pass: VM" >&2
  ssh "${ssh_opts[@]}" dev@127.0.0.1 "CPUS=$CPUS bash w/suite.sh /home/dev/scratch vm $pass" >> "$out"
done

pid=$(docker inspect -f '{{.State.Pid}}' vmbench-vm)
emit vm mem.vmm_rss_mb "$(awk '/VmRSS/ {print int($2/1024)}' "/proc/$pid/status")" MB
emit host mem.available_mb "$(avail_mb)" MB
docker rm -f vmbench-vm >/dev/null
echo "$out"
