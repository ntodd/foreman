#!/bin/sh
# Runs a Foreman box on this Linux machine as a VM: Flatcar Container
# Linux under QEMU with KVM, run by systemd. The box sets itself up on its
# first boot and enrolls with the control plane; Flatcar keeps itself up
# to date, and the box's environments stay apart from this machine.
#
#   curl -fsSL __FOREMAN_URL__/agent/vm.sh | sudo sh -s -- --token fj_...
#
#   --cpus N        virtual CPUs (default: half this machine's)
#   --memory GiB    memory (default: half this machine's, at most 16)
#   --disk GiB      disk size (default 100); the file only takes what the
#                   box uses
#   --ssh-port N    where `foreman-box ssh` reaches the box, on 127.0.0.1
#                   (default 2222)
#
# Needs systemd and KVM. On Debian and Ubuntu it installs QEMU, the UEFI
# firmware and bzip2 if they're missing; elsewhere, install them first.
#
# Running it again updates the launcher and keeps the box; it needs no
# token. --cpus and --memory then change the box's size, from its next
# start. Afterwards, foreman-box manages the box:
#
#   foreman-box status | start | stop | restart | ssh | logs | uninstall
#
# QEMU runs as the foreman-box user, sandboxed by systemd, with user-mode
# networking: the box reaches the network through this machine and
# nothing on this machine's network changes.
set -eu

FOREMAN_URL="__FOREMAN_URL__"

# Flatcar for the first boot; the box updates itself after that. The
# digests are from the release's signed DIGESTS files.
FLATCAR_VERSION="4757.2.3"
FLATCAR_IMAGE_SHA512_AMD64="f3d1391c9c36594abcaa5674716d95997c25ec334b75548b93873857e72d6d840621066807a85a47a7a3b4161d5259d0e88b8822c78eef369ba2be8bd57568d1"
FLATCAR_IMAGE_SHA512_ARM64="5fdbb01d9d9706e7d93b22f619148723d6e88b300d241c2773ff34c17b93b81965798d29a5b6138a2a7197a8fd7b027d5093b458cacf90330360816c8a0b08e4"

DIR="${FOREMAN_BOX_DIR:-/var/lib/foreman-box}"
UNIT="${FOREMAN_BOX_UNIT:-foreman-box}"
USER_NAME=foreman-box
SELF=/usr/local/sbin/$UNIT

say() { echo "foreman-box: $*"; }
fail() { echo "foreman-box: $*" >&2; exit 1; }

conf() { sed -n "s/^$1=//p" "$DIR/box.conf" 2>/dev/null | tail -1; }

# -- the box's VM ------------------------------------------------------------

# What systemd runs: QEMU, booted from the box's disk, as foreman-box.
run() {
  [ -f "$DIR/box.conf" ] || fail "no box here; set one up with the command from Foreman"
  cpus=$(conf cpus)
  set -- \
    -name "$UNIT" -nodefaults -no-user-config -display none \
    -cpu host -smp "$cpus" -m "$(conf memory)G" \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$(conf firmware)" \
    -drive "if=pflash,format=raw,unit=1,file=$DIR/efi-vars.fd" \
    -object iothread,id=io0 \
    -drive "if=none,id=disk0,file=$DIR/disk.img,format=raw,cache=none,aio=$(conf aio),discard=unmap,detect-zeroes=unmap" \
    -device "virtio-blk-pci,drive=disk0,iothread=io0,num-queues=$cpus" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$(conf ssh_port)-:22" \
    -device "virtio-net-pci,netdev=net0,mac=$(conf mac)" \
    -device virtio-rng-pci \
    -device virtio-balloon-pci,free-page-reporting=on \
    -chardev "file,id=console,path=$DIR/serial.log" -serial chardev:console \
    -qmp "unix:$DIR/qmp.sock,server=on,wait=off" \
    -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny
  case "$(uname -m)" in
    x86_64) set -- -machine q35,accel=kvm "$@" ;;
    aarch64) set -- -machine virt,accel=kvm,gic-version=host "$@" ;;
  esac
  # The first-boot config, until the box has enrolled with it.
  if [ -f "$DIR/config.ign" ]; then
    set -- "$@" -fw_cfg "name=opt/org.flatcar-linux/config,file=$DIR/config.ign"
  fi
  # Keep the previous boot's console for a look after a crash.
  [ ! -s "$DIR/serial.log" ] || mv -f "$DIR/serial.log" "$DIR/serial.log.1"
  exec "$(conf qemu)" "$@"
}

# Asks the box to shut down (its power button, through QEMU's monitor),
# and waits for QEMU to exit. systemd runs it as the unit's ExecStop.
powerdown() {
  pid=${MAINPID:-$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null || echo 0)}
  [ "${pid:-0}" -gt 0 ] && kill -0 "$pid" 2>/dev/null || return 0
  perl -MIO::Socket::UNIX -e '
    my $s = IO::Socket::UNIX->new(Peer => $ARGV[0]) or exit 0;
    print $s qq({"execute":"qmp_capabilities"}\n{"execute":"system_powerdown"}\n);
    sleep 1;' "$DIR/qmp.sock" 2>/dev/null || true
  i=0
  while kill -0 "$pid" 2>/dev/null && [ $i -lt 100 ]; do
    sleep 1
    i=$((i + 1))
  done
}

status() {
  if ! [ -f "$DIR/box.conf" ]; then
    echo "no box"
    return 1
  fi
  echo "box:     $(conf name)"
  echo "size:    $(conf cpus) CPUs, $(conf memory) GiB, disk $(du -h "$DIR/disk.img" | cut -f1) used of $(conf disk) GiB"
  echo "systemd: $(systemctl is-active "$UNIT" 2>/dev/null || true) ($UNIT.service)"
  echo "ssh:     foreman-box ssh (127.0.0.1:$(conf ssh_port))"
}

ssh_box() {
  exec ssh -i "$DIR/id_ed25519" -p "$(conf ssh_port)" -o UserKnownHostsFile="$DIR/known_hosts" \
    -o StrictHostKeyChecking=accept-new core@127.0.0.1 "$@"
}

uninstall() {
  [ "${1:-}" = --yes ] || fail "this deletes the box's disk and everything on it; run: foreman-box uninstall --yes (and revoke the box in Foreman)"
  systemctl disable --now "$UNIT" 2>/dev/null || true
  rm -f "/etc/systemd/system/$UNIT.service" "$SELF"
  systemctl daemon-reload
  rm -rf "$DIR"
  say "removed the box; revoke it on its page in Foreman"
}

case "${1:-}" in
  run) run ;;
  powerdown) powerdown; exit ;;
  start) systemctl start "$UNIT"; exit ;;
  stop) systemctl stop "$UNIT"; exit ;;
  restart) systemctl restart "$UNIT"; exit ;;
  status) status; exit ;;
  ssh) shift; ssh_box "$@" ;;
  logs) exec tail -n 200 -F "$DIR/serial.log" ;;
  uninstall) shift; uninstall "$@"; exit ;;
esac

# Run as `curl ... | sh`, the shell reads this script from stdin as it
# goes, so nothing below may read stdin: every command that could gets
# /dev/null.

# -- install or update ---------------------------------------------------------

TOKEN=""
CPUS=""
MEMORY=""
DISK=100
SSH_PORT=2222

while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --cpus) CPUS="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --disk) DISK="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --url) FOREMAN_URL="$2"; shift 2 ;;
    *) fail "unknown option: $1" ;;
  esac
done

[ "$(uname -s)" = Linux ] || fail "this is for Linux; on a Mac use mac.sh"
[ "$(id -u)" -eq 0 ] || fail "run this as root (sudo)"
command -v systemctl >/dev/null 2>&1 || fail "systemd is required"
for n in CPUS MEMORY DISK SSH_PORT; do
  eval "v=\${$n}"
  # shellcheck disable=SC2154
  case "$v" in *[!0-9]*) fail "--$(echo "$n" | tr '[:upper:]_' '[:lower:]-') takes a whole number" ;; esac
done
[ -c /dev/kvm ] || fail "KVM isn't available (no /dev/kvm): turn on virtualization in the firmware, or load kvm_intel or kvm_amd"

case "$(uname -m)" in
  x86_64)
    arch=amd64 qemu=qemu-system-x86_64 packages="qemu-system-x86 ovmf"
    image_sha=$FLATCAR_IMAGE_SHA512_AMD64
    firmware_pairs="/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd
/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd
/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd
/usr/share/edk2/x64/OVMF_CODE.4m.fd:/usr/share/edk2/x64/OVMF_VARS.4m.fd
/usr/share/qemu/ovmf-x86_64-code.bin:/usr/share/qemu/ovmf-x86_64-vars.bin"
    ;;
  aarch64)
    arch=arm64 qemu=qemu-system-aarch64 packages="qemu-system-arm qemu-efi-aarch64"
    image_sha=$FLATCAR_IMAGE_SHA512_ARM64
    firmware_pairs="/usr/share/AAVMF/AAVMF_CODE.fd:/usr/share/AAVMF/AAVMF_VARS.fd
/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw:/usr/share/edk2/aarch64/vars-template-pflash.raw
/usr/share/edk2/aarch64/QEMU_CODE.fd:/usr/share/edk2/aarch64/QEMU_VARS.fd"
    ;;
  *) fail "unsupported architecture $(uname -m)" ;;
esac

find_firmware() {
  echo "$firmware_pairs" | while IFS=: read -r code vars; do
    if [ -f "$code" ] && [ -f "$vars" ]; then
      echo "$code:$vars"
      break
    fi
  done
}

# bzip2 for Flatcar's image, which minimal systems (Ubuntu's cloud
# images) leave out.
packages="$packages bzip2"
if ! command -v "$qemu" >/dev/null 2>&1 || [ -z "$(find_firmware)" ] || ! command -v bunzip2 >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    say "installing what the box needs ($packages)"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq </dev/null >/dev/null
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $packages </dev/null >/dev/null
  else
    fail "install QEMU ($qemu), UEFI firmware for it and bzip2 first (on Fedora: qemu-kvm edk2-ovmf bzip2)"
  fi
fi
qemu_path=$(command -v "$qemu") || fail "$qemu isn't installed"
firmware=$(find_firmware)
[ -n "$firmware" ] || fail "no UEFI firmware for $qemu found"
firmware_code=${firmware%%:*}
firmware_vars=${firmware#*:}
for tool in curl bunzip2 sha512sum perl ssh-keygen; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done

install -d -m 0750 "$DIR"

# io_uring where the kernel and QEMU have it, and direct I/O on the
# filesystem the disk goes on; threads otherwise.
aio=threads
probe="$DIR/.aio-probe"
truncate -s 1M "$probe"
if printf 'quit\n' | timeout 30 "$qemu_path" -nodefaults -display none -machine none -S -monitor stdio \
  -drive "if=none,id=probe,file=$probe,format=raw,cache=none,aio=io_uring" >/dev/null 2>&1; then
  aio=io_uring
fi
rm -f "$probe"

id "$USER_NAME" >/dev/null 2>&1 ||
  useradd --system --home-dir "$DIR" --shell /usr/sbin/nologin "$USER_NAME"
getent group kvm >/dev/null 2>&1 && usermod -aG kvm "$USER_NAME"
install -d -m 0750 -o "$USER_NAME" -g "$USER_NAME" "$DIR"

say "installing $SELF"
curl -fsSL -o "$SELF.new" "$FOREMAN_URL/agent/vm.sh" </dev/null || fail "couldn't reach $FOREMAN_URL"
chmod 0755 "$SELF.new"
mv -f "$SELF.new" "$SELF"

cat > "/etc/systemd/system/$UNIT.service" <<EOF
[Unit]
Description=Foreman box (Flatcar VM)
After=network-online.target
Wants=network-online.target

[Service]
User=$USER_NAME
Group=$USER_NAME
SupplementaryGroups=kvm
Environment=FOREMAN_BOX_DIR=$DIR FOREMAN_BOX_UNIT=$UNIT
ExecStart=$SELF run
ExecStop=$SELF powerdown
TimeoutStopSec=120
Restart=always
RestartSec=5
# QEMU needs KVM and the box's directory, and nothing else of this machine.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=false
DevicePolicy=closed
DeviceAllow=/dev/kvm rw
ReadWritePaths=$DIR
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

if [ -f "$DIR/box.conf" ]; then
  # An update: the box and its disk stay as they are. (To start over with
  # a new token: foreman-box uninstall --yes, then this again.)
  { grep -v -e '^cpus=' -e '^memory=' -e '^qemu=' -e '^firmware=' -e '^aio=' "$DIR/box.conf"
    echo "cpus=${CPUS:-$(conf cpus)}"
    echo "memory=${MEMORY:-$(conf memory)}"
    echo "qemu=$qemu_path"
    echo "firmware=$firmware_code"
    echo "aio=$aio"; } > "$DIR/box.conf.new"
  mv -f "$DIR/box.conf.new" "$DIR/box.conf"
  chown "$USER_NAME:$USER_NAME" "$DIR/box.conf"
  systemctl enable "$UNIT" >/dev/null 2>&1
  systemctl start "$UNIT"
  [ -z "$CPUS$MEMORY" ] || say "the box gets $(conf cpus) CPUs and $(conf memory) GiB from its next start (foreman-box restart)"
  say "updated; the box keeps its disk and enrollment"
  exit 0
fi

[ -n "$TOKEN" ] || fail "--token is required (create one under Boxes, Add a box, in Foreman)"

cores=$(nproc)
mem_gib=$(($(sed -n 's/^MemTotal: *\([0-9]*\) kB/\1/p' /proc/meminfo) / 1048576))
[ -n "$CPUS" ] || CPUS=$((cores / 2 > 2 ? cores / 2 : 2))
[ -n "$MEMORY" ] || MEMORY=$((mem_gib / 2 > 16 ? 16 : (mem_gib / 2 < 4 ? 4 : mem_gib / 2)))
[ "$CPUS" -le "$cores" ] || fail "--cpus $CPUS is more than this machine's $cores"
[ "$MEMORY" -lt "$mem_gib" ] || fail "--memory $MEMORY GiB leaves nothing for this machine's $mem_gib GiB"
[ "$DISK" -ge 20 ] || fail "--disk needs at least 20 GiB"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

[ -f "$DIR/id_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C "foreman-box@$(hostname)" -f "$DIR/id_ed25519" </dev/null
mac=$(od -An -N3 -tx1 /dev/urandom | tr -s ' ' ':' | sed 's/^/52:54:00/; s/:$//')

say "asking $FOREMAN_URL for the box's first-boot config"
code=$(curl -sS -D "$work/headers" -o "$work/config.ign" -w '%{http_code}' \
  -X POST "$FOREMAN_URL/agent/flatcar/ignition" \
  --data-urlencode "join_token=$TOKEN" --data-urlencode "arch=$arch" \
  --data-urlencode "ssh_keys[]=$(cat "$DIR/id_ed25519.pub")" </dev/null) || fail "couldn't reach $FOREMAN_URL"
[ "$code" = 200 ] || fail "Foreman said $code: $(cat "$work/config.ign")"
name=$(tr -d '\r' < "$work/headers" | sed -n 's/^[Xx]-[Ff]oreman-[Bb]ox: *//p' | tail -1)

images="$DIR/images/$FLATCAR_VERSION-$arch"
mkdir -p "$images"
image=flatcar_production_image.bin.bz2
if [ ! -f "$images/$image" ] || [ "$(sha512sum "$images/$image" | cut -d' ' -f1)" != "$image_sha" ]; then
  say "downloading Flatcar $FLATCAR_VERSION ($arch)"
  curl -fsSL -o "$images/$image.part" "https://stable.release.flatcar-linux.net/$arch-usr/$FLATCAR_VERSION/$image" </dev/null
  [ "$(sha512sum "$images/$image.part" | cut -d' ' -f1)" = "$image_sha" ] ||
    { rm -f "$images/$image.part"; fail "$image doesn't match its digest"; }
  mv -f "$images/$image.part" "$images/$image"
fi

say "writing the box's disk ($DISK GiB, sparse)"
# Most of the image is empty partitions: skip the zeros rather than write
# gigabytes of them.
bunzip2 -c "$images/$image" | dd of="$DIR/disk.img.part" bs=1M iflag=fullblock conv=sparse status=none
truncate -s "${DISK}G" "$DIR/disk.img.part"
mv -f "$DIR/disk.img.part" "$DIR/disk.img"
rm -rf "$DIR/images"
cp "$firmware_vars" "$DIR/efi-vars.fd"
install -m 0600 "$work/config.ign" "$DIR/config.ign"

cat > "$DIR/box.conf" <<EOF
name=$name
cpus=$CPUS
memory=$MEMORY
disk=$DISK
mac=$mac
ssh_port=$SSH_PORT
qemu=$qemu_path
firmware=$firmware_code
aio=$aio
flatcar=$FLATCAR_VERSION
EOF
chown -R "$USER_NAME:$USER_NAME" "$DIR"
chmod 0600 "$DIR/id_ed25519"

say "starting the box ($CPUS CPUs, $MEMORY GiB); it sets itself up on its first boot"
systemctl enable "$UNIT" >/dev/null 2>&1
systemctl restart "$UNIT"

# Its first boot: Ignition, then the extensions, the tailnet and the agent.
i=0
seen=0
while [ $i -lt 600 ]; do
  if [ -f "$DIR/serial.log" ]; then
    lines=$(tr -d '\r' < "$DIR/serial.log" | grep -a -c -E '^foreman(-box)?: ' || true)
    if [ "$lines" -gt "$seen" ]; then
      tr -d '\r' < "$DIR/serial.log" | grep -a -E '^foreman(-box)?: ' | tail -n +"$((seen + 1))"
      seen=$lines
    fi
    if grep -aq 'foreman-box: enrolled' "$DIR/serial.log"; then
      # Spent: the token and the box's Tailscale key.
      rm -f "$DIR/config.ign"
      say "done: $name is on the Boxes page in Foreman"
      say "manage it with foreman-box (status, stop, start, restart, ssh, logs, uninstall)"
      exit 0
    fi
  fi
  if ! systemctl is-active --quiet "$UNIT"; then
    journalctl -u "$UNIT" -n 20 --no-pager >&2 || true
    fail "the box's VM stopped"
  fi
  i=$((i + 2))
  sleep 2
done

tail -n 40 "$DIR/serial.log" >&2 || true
fail "the box didn't enroll within 10 minutes; it keeps trying. Watch it with: foreman-box logs"
