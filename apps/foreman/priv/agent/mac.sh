#!/bin/sh
# Runs a Foreman box on this Mac: Flatcar Container Linux in a VM on
# Apple's hypervisor (through vfkit), started at login by launchd. The box
# sets itself up on its first boot and enrolls with the control plane.
#
#   curl -fsSL __FOREMAN_URL__/agent/mac.sh | sh -s -- --token fj_...
#
#   --cpus N        virtual CPUs (default: half this Mac's cores)
#   --memory GiB    memory (default: half this Mac's, at most 16)
#   --disk GiB      disk size (default 100); the file only takes what the
#                   box uses
#
# Running it again updates the launcher and vfkit and keeps the box; it
# needs no token. --cpus and --memory then change the box's size, from its
# next start. Afterwards, ~/.foreman-box/bin/foreman-box manages the box:
#
#   foreman-box status | start | stop | restart | ssh | logs | uninstall
#
# Everything lives in ~/.foreman-box. The VM sees nothing of the Mac's
# files, and reaches the network through the Mac's NAT.
set -eu

FOREMAN_URL="__FOREMAN_URL__"

# Flatcar for the first boot; the box updates itself after that. The
# digests are from the release's signed DIGESTS files.
FLATCAR_VERSION="4757.2.3"
FLATCAR_IMAGE_SHA512_ARM64="5fdbb01d9d9706e7d93b22f619148723d6e88b300d241c2773ff34c17b93b81965798d29a5b6138a2a7197a8fd7b027d5093b458cacf90330360816c8a0b08e4"
FLATCAR_KERNEL_SHA512_ARM64="e9d852a45c4953123f513589f0c6b22abd3fbd58354875884fa03bc73d0be85b884cfcadb03646dc66b4b8ad9d710a2830cceee4f3b14712163fa56115f772b2"
FLATCAR_VERITY_ARM64="6ae5c5ebc899cb7e26ff0cf052d73929ebb0340d53d537c96a4957eafa5184f4"
FLATCAR_IMAGE_SHA512_AMD64="f3d1391c9c36594abcaa5674716d95997c25ec334b75548b93873857e72d6d840621066807a85a47a7a3b4161d5259d0e88b8822c78eef369ba2be8bd57568d1"
FLATCAR_KERNEL_SHA512_AMD64="8ac5ce48e95b6a62baa8b342b022c1c0df994fc30c3042e062acd50eb13672e132ebd0a5ce3517a02aaa7582125c8dfeeb4aabd0bf85a2b7a5a7f644b4be773d"
FLATCAR_VERITY_AMD64="1eda159b35fabd052c62622359e7a2069af95db3ef23924c9c5652e444715586"
# Every Flatcar image's USR-A partition, which the first boot runs from.
FLATCAR_USR_A="7130c94a-213a-4e5a-8e26-6cce9662f132"

# vfkit's release binary: universal, signed by Red Hat, with the
# virtualization entitlement.
VFKIT_VERSION="v0.6.4"
VFKIT_SHA256="0ed83fc8ca7aa708598835480dba1362406aa7cd1dab3b27464eb76327d9652d"

HOME_DIR="${FOREMAN_BOX_HOME:-$HOME/.foreman-box}"
BIN="$HOME_DIR/bin"
BOX="$HOME_DIR/box"
LABEL="${FOREMAN_BOX_LABEL:-foreman.box}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

say() { echo "foreman-box: $*"; }
fail() { echo "foreman-box: $*" >&2; exit 1; }

# -- the box's VM ------------------------------------------------------------

conf() { sed -n "s/^$1=//p" "$BOX/box.conf" 2>/dev/null | tail -1; }

rest() { curl -fsS --max-time 10 --unix-socket "$BOX/rest.sock" "$@"; }

vm_state() { rest http://localhost/vm/state 2>/dev/null | sed -n 's/.*"state":"VirtualMachineState\([A-Za-z]*\)".*/\1/p'; }

loaded() { launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; }

# The address vmnet's DHCP server gave the box (it asks by MAC address):
# the lease with the latest expiry, which the file keeps as fixed-width hex.
address() {
  mac=$(conf mac | sed 's/:0\([0-9a-f]\)/:\1/g; s/^0\([0-9a-f]\)/\1/')
  awk -v hw="1,$mac" '
    /^[ \t]*ip_address=/ { sub(/.*ip_address=/, ""); ip = $0 }
    /^[ \t]*hw_address=/ { sub(/.*hw_address=/, ""); match_hw = ($0 == hw) }
    /^[ \t]*lease=/ { sub(/.*lease=/, ""); if (match_hw && $0 > best) { best = $0; found = ip } }
    END { if (found) print found }' /var/db/dhcpd_leases 2>/dev/null
}

# What launchd runs: the VM, booted from its disk.
run() {
  [ -f "$BOX/box.conf" ] || fail "no box here; set one up with the command from Foreman"
  store="efi,variable-store=$BOX/efi-vars"
  [ -e "$BOX/efi-vars" ] || store="$store,create"
  # Keep the previous boot's console for a look after a crash.
  [ ! -s "$BOX/serial.log" ] || mv -f "$BOX/serial.log" "$BOX/serial.log.1"
  rm -f "$BOX/rest.sock"
  exec "$BIN/vfkit" \
    --cpus "$(conf cpus)" --memory "$(($(conf memory) * 1024))" \
    --bootloader "$store" \
    --device "virtio-blk,path=$BOX/disk.img" \
    --device "virtio-net,nat,mac=$(conf mac)" \
    --device "virtio-serial,logFilePath=$BOX/serial.log" \
    --device virtio-rng \
    --restful-uri "unix://$BOX/rest.sock"
}

start() {
  loaded && return 0
  launchctl bootstrap "gui/$(id -u)" "$PLIST" </dev/null ||
    fail "launchd wouldn't start the box; run this in Terminal, logged in to the Mac"
}

# Asks the box to shut down, and waits for it before unloading the agent.
stop() {
  if [ "$(vm_state)" = Running ]; then
    rest -X POST -d '{"state":"Stop"}' http://localhost/vm/state >/dev/null 2>&1 || true
    i=0
    while [ "$(vm_state)" = Running ] && [ $i -lt 60 ]; do
      sleep 1
      i=$((i + 1))
    done
  fi
  if loaded; then launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true; fi
  # bootout returns before launchd lets go of the job.
  i=0
  while loaded && [ $i -lt 20 ]; do
    sleep 0.5
    i=$((i + 1))
  done
}

status() {
  if ! [ -f "$BOX/box.conf" ]; then
    echo "no box"
    return 1
  fi
  echo "box:     $(conf name)"
  echo "size:    $(conf cpus) CPUs, $(conf memory) GiB, disk $(du -h "$BOX/disk.img" | cut -f1) used of $(conf disk) GiB"
  if loaded; then echo "launchd: loaded ($LABEL)"; else echo "launchd: not loaded"; fi
  echo "vm:      $(vm_state || true)"
  ip=$(address)
  echo "address: ${ip:-unknown}"
}

ssh_box() {
  ip=$(address)
  [ -n "$ip" ] || fail "the box has no address yet"
  exec ssh -i "$BOX/id_ed25519" -o UserKnownHostsFile="$BOX/known_hosts" \
    -o StrictHostKeyChecking=accept-new "core@$ip" "$@"
}

uninstall() {
  [ "${1:-}" = --yes ] || fail "this deletes the box's disk and everything on it; run: foreman-box uninstall --yes (and revoke the box in Foreman)"
  stop
  rm -f "$PLIST"
  rm -rf "$HOME_DIR"
  say "removed the box; revoke it on its page in Foreman"
}

case "${1:-}" in
  run) run ;;
  start) start; exit ;;
  stop) stop; exit ;;
  restart) stop; start; exit ;;
  status) status; exit ;;
  ssh) shift; ssh_box "$@" ;;
  logs) exec tail -n 200 -F "$BOX/serial.log" ;;
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

while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --cpus) CPUS="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --disk) DISK="$2"; shift 2 ;;
    --url) FOREMAN_URL="$2"; shift 2 ;;
    *) fail "unknown option: $1" ;;
  esac
done

[ "$(uname -s)" = Darwin ] || fail "this is for macOS; on Linux use vm.sh or install.sh"
[ "$(id -u)" -ne 0 ] || fail "run this as yourself, not root: the box runs in your login session"
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || fail "macOS 13 or newer is needed (Apple's hypervisor boots Linux with EFI from 13)"
case "$(uname -m)" in
  arm64) arch=arm64 ;;
  x86_64) arch=amd64 ;;
  *) fail "unsupported architecture $(uname -m)" ;;
esac
for n in CPUS MEMORY DISK; do
  eval "v=\${$n}"
  # shellcheck disable=SC2154
  case "$v" in *[!0-9]*) fail "--$(echo "$n" | tr '[:upper:]' '[:lower:]') takes a whole number" ;; esac
done

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
sha512() { shasum -a 512 "$1" | cut -d' ' -f1; }

# vfkit, this script as the command that manages the box (the control
# plane's current copy), and the launchd job that runs it.
install_launcher() {
  mkdir -p "$BIN" "$BOX" "$HOME/Library/LaunchAgents"
  if [ ! -x "$BIN/vfkit" ] || [ "$(sha256 "$BIN/vfkit")" != "$VFKIT_SHA256" ]; then
    say "downloading vfkit $VFKIT_VERSION"
    curl -fsSL -o "$BIN/vfkit.new" "https://github.com/crc-org/vfkit/releases/download/$VFKIT_VERSION/vfkit" </dev/null
    [ "$(sha256 "$BIN/vfkit.new")" = "$VFKIT_SHA256" ] || { rm -f "$BIN/vfkit.new"; fail "vfkit doesn't match its digest"; }
    chmod 0755 "$BIN/vfkit.new"
    mv -f "$BIN/vfkit.new" "$BIN/vfkit"
  fi

  self="$BIN/foreman-box"
  curl -fsSL -o "$self.new" "$FOREMAN_URL/agent/mac.sh" </dev/null || fail "couldn't reach $FOREMAN_URL"
  chmod 0755 "$self.new"
  mv -f "$self.new" "$self"

  cat > "$PLIST.new" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$self</string><string>run</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FOREMAN_BOX_HOME</key><string>$HOME_DIR</string>
    <key>FOREMAN_BOX_LABEL</key><string>$LABEL</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <!-- A VM can't reboot itself on Apple's hypervisor: vfkit exits, and
       launchd starts it again. -->
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <!-- On SIGTERM (logout, shutdown) vfkit asks the box to power off; give
       it time to stop its containers. -->
  <key>ExitTimeOut</key><integer>60</integer>
  <!-- Builds run in the box: no background throttling. -->
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$BOX/vfkit.log</string>
  <key>StandardErrorPath</key><string>$BOX/vfkit.log</string>
</dict>
</plist>
EOF
  mv -f "$PLIST.new" "$PLIST"
}

if [ -f "$BOX/box.conf" ]; then
  # An update: the box and its disk stay as they are. (To start over with
  # a new token: foreman-box uninstall --yes, then this again.)
  install_launcher
  if [ -n "$CPUS$MEMORY" ]; then
    { grep -v -e '^cpus=' -e '^memory=' "$BOX/box.conf"
      echo "cpus=${CPUS:-$(conf cpus)}"
      echo "memory=${MEMORY:-$(conf memory)}"; } > "$BOX/box.conf.new"
    mv -f "$BOX/box.conf.new" "$BOX/box.conf"
    say "the box gets $(conf cpus) CPUs and $(conf memory) GiB from its next start (foreman-box restart)"
  fi
  start
  say "updated; the box keeps its disk and enrollment"
  exit 0
fi

[ -n "$TOKEN" ] || fail "--token is required (create one under Boxes, Add a box, in Foreman)"

cores=$(sysctl -n hw.ncpu)
mem_gib=$(($(sysctl -n hw.memsize) / 1073741824))
[ -n "$CPUS" ] || CPUS=$((cores / 2 > 2 ? cores / 2 : 2))
[ -n "$MEMORY" ] || MEMORY=$((mem_gib / 2 > 16 ? 16 : (mem_gib / 2 < 4 ? 4 : mem_gib / 2)))
[ "$CPUS" -le "$cores" ] || fail "--cpus $CPUS is more than this Mac's $cores"
[ "$MEMORY" -lt "$mem_gib" ] || fail "--memory $MEMORY GiB leaves nothing for this Mac's $mem_gib GiB"
[ "$DISK" -ge 20 ] || fail "--disk needs at least 20 GiB"

if [ "$arch" = arm64 ]; then
  image_sha=$FLATCAR_IMAGE_SHA512_ARM64 kernel_sha=$FLATCAR_KERNEL_SHA512_ARM64 verity=$FLATCAR_VERITY_ARM64
else
  image_sha=$FLATCAR_IMAGE_SHA512_AMD64 kernel_sha=$FLATCAR_KERNEL_SHA512_AMD64 verity=$FLATCAR_VERITY_AMD64
fi

# A new box. Until it starts, a failure leaves nothing behind.
fresh=""
[ -e "$HOME_DIR" ] || fresh=1
work="$HOME_DIR/install"
# shellcheck disable=SC2329 # the EXIT trap runs it
cleanup() {
  rm -rf "$work"
  if [ -n "$fresh" ]; then
    rm -f "$PLIST"
    rm -rf "$HOME_DIR"
  fi
}
trap cleanup EXIT
rm -rf "$work"
mkdir -p "$work/config" "$BOX"

# A key of its own for `foreman-box ssh`, and the box's MAC address.
[ -f "$BOX/id_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C "foreman-box@$(hostname -s)" -f "$BOX/id_ed25519" </dev/null
mac=$(od -An -N3 -tx1 /dev/urandom | tr -s ' ' ':' | sed 's/^/52:54:00/; s/:$//')

# First, so a bad token fails before anything is downloaded.
say "asking $FOREMAN_URL for the box's first-boot config"
code=$(curl -sS -D "$work/headers" -o "$work/config/config.ign" -w '%{http_code}' \
  -X POST "$FOREMAN_URL/agent/flatcar/ignition" \
  --data-urlencode "join_token=$TOKEN" --data-urlencode "arch=$arch" \
  --data-urlencode "ssh_keys[]=$(cat "$BOX/id_ed25519.pub")" </dev/null) || fail "couldn't reach $FOREMAN_URL"
[ "$code" = 200 ] || fail "Foreman said $code: $(cat "$work/config/config.ign")"
chmod 0600 "$work/config/config.ign"
name=$(tr -d '\r' < "$work/headers" | sed -n 's/^[Xx]-[Ff]oreman-[Bb]ox: *//p' | tail -1)

install_launcher

images="$HOME_DIR/images/$FLATCAR_VERSION-$arch"
mkdir -p "$images"
base="https://stable.release.flatcar-linux.net/$arch-usr/$FLATCAR_VERSION"
fetch() {
  if [ ! -f "$images/$1" ] || [ "$(sha512 "$images/$1")" != "$2" ]; then
    say "downloading $1 (Flatcar $FLATCAR_VERSION, $arch)"
    curl -fSL --progress-bar -o "$images/$1.part" "$base/$1" </dev/null
    [ "$(sha512 "$images/$1.part")" = "$2" ] || { rm -f "$images/$1.part"; fail "$1 doesn't match its digest"; }
    mv -f "$images/$1.part" "$images/$1"
  fi
}
fetch flatcar_production_image.bin.bz2 "$image_sha"
fetch flatcar_production_image.vmlinuz "$kernel_sha"

say "writing the box's disk ($DISK GiB, sparse)"
# Most of the image is empty partitions: skip the zeros rather than write
# gigabytes of them. APFS fills in much of a file written slowly from a
# pipe, holes and all, so the image is copied once more, file to file,
# which keeps them (about 1 GB instead of 8).
bunzip2 -c "$images/flatcar_production_image.bin.bz2" | dd of="$BOX/disk.img.raw" bs=1048576 conv=sparse 2>/dev/null
dd if="$BOX/disk.img.raw" of="$BOX/disk.img.part" bs=1048576 conv=sparse 2>/dev/null
rm -f "$BOX/disk.img.raw"
truncate -s "${DISK}g" "$BOX/disk.img.part" 2>/dev/null || mkfile -n "${DISK}g" "$BOX/disk.img.part"
mv -f "$BOX/disk.img.part" "$BOX/disk.img"
rm -f "$images/flatcar_production_image.bin.bz2"

# The first-boot config goes in the image's OEM partition, which is btrfs,
# so a Linux has to write it: the image's own, started once without
# booting its usual way. It stages the config with flatcar-reset, sends
# the console to the virtio one, and powers off.
cat > "$work/config/prep.sh" <<'EOF'
#!/bin/sh
set -eu
flatcar-reset --ignition-file /run/fmcfg/config.ign
printf 'set linux_console="console=hvc0"\n' >> /oem/grub.cfg
sync
echo "foreman-box: config staged"
EOF
hdiutil makehybrid -quiet -iso -joliet -default-volume-name FMCFG -o "$work/config.iso" "$work/config" </dev/null
cpio -o -H newc < /dev/null > "$work/empty.cpio" 2>/dev/null

say "staging the config"
cmdline="rootflags=rw mount.usrflags=ro consoleblank=0 root=LABEL=ROOT console=hvc0"
cmdline="$cmdline mount.usr=/dev/mapper/usr verity.usr=PARTUUID=$FLATCAR_USR_A verity.usrhash=$verity"
cmdline="$cmdline systemd.mount-extra=LABEL=FMCFG:/run/fmcfg:iso9660:ro \"systemd.run=/usr/bin/sh /run/fmcfg/prep.sh\""
cmdline="$cmdline systemd.run_success_action=poweroff systemd.run_failure_action=poweroff"
"$BIN/vfkit" --cpus 2 --memory 2048 \
  --kernel "$images/flatcar_production_image.vmlinuz" --initrd "$work/empty.cpio" --kernel-cmdline "$cmdline" \
  --device "virtio-blk,path=$BOX/disk.img" --device "virtio-blk,path=$work/config.iso,readonly" \
  --device virtio-net,nat --device "virtio-serial,logFilePath=$work/prep.log" --device virtio-rng \
  </dev/null > "$work/vfkit.log" 2>&1 &
pid=$!
i=0
while kill -0 "$pid" 2>/dev/null; do
  i=$((i + 1))
  if [ $i -gt 180 ]; then kill -9 "$pid"; break; fi
  sleep 1
done
wait "$pid" 2>/dev/null || true
if ! grep -aq 'foreman-box: config staged' "$work/prep.log"; then
  tail -n 30 "$work/prep.log" >&2 || true
  rm -f "$BOX/disk.img"
  fail "couldn't stage the first-boot config (the console's last lines are above)"
fi

rm -rf "$HOME_DIR/images"

cat > "$BOX/box.conf" <<EOF
name=$name
cpus=$CPUS
memory=$MEMORY
disk=$DISK
mac=$mac
flatcar=$FLATCAR_VERSION
EOF

# The box exists from here on, and keeps trying whatever happens next.
fresh=""
say "starting the box ($CPUS CPUs, $MEMORY GiB); it sets itself up on its first boot"
stop
start

# Its first boot: Ignition, then the extensions, the tailnet and the agent.
i=0
seen=0
while [ $i -lt 600 ]; do
  if [ -f "$BOX/serial.log" ]; then
    lines=$(tr -d '\r' < "$BOX/serial.log" | grep -a -c -E '^foreman(-box)?: ' || true)
    if [ "$lines" -gt "$seen" ]; then
      tr -d '\r' < "$BOX/serial.log" | grep -a -E '^foreman(-box)?: ' | tail -n +"$((seen + 1))"
      seen=$lines
    fi
    if grep -aq 'foreman-box: enrolled' "$BOX/serial.log"; then
      say "done: $name is on the Boxes page in Foreman"
      say "manage it with $self (status, stop, start, restart, ssh, logs, uninstall)"
      exit 0
    fi
  fi
  i=$((i + 2))
  sleep 2
done

tail -n 40 "$BOX/serial.log" >&2 || true
fail "the box didn't enroll within 10 minutes; it keeps trying. Watch it with: $self logs"
