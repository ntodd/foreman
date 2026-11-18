#!/bin/sh
# Checks foreman-vmctl (apps/foreman_agent/priv/vm/vmctl), the root helper
# for environment VMs, with stand-ins for ip, sysctl, systemctl and
# systemd-run that record what it asks of them: what it refuses, the
# addresses it hands out, and the Cloud Hypervisor command line it
# builds. Nothing here needs root or changes the machine.
#
#   e2e/vmctl/test.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
vmctl=$here/../../apps/foreman_agent/priv/vm/vmctl
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; failures=$((failures + 1)); }
check() { # description, command...
  what=$1
  shift
  if "$@"; then pass "$what"; else fail "$what"; fi
}

# -- stand-ins -------------------------------------------------------------
mkdir -p "$work/bin" "$work/srv/vms" "$work/srv/guest" "$work/srv/agent-disks" "$work/state"
# The box's kernel: its release, and its LSM list.
printf '6.12.117-flatcar\n' > "$work/release"
printf 'lockdown,capability,landlock,yama,apparmor' > "$work/lsm"
cat > "$work/bin/uname" <<STUB
#!/bin/sh
cat "$work/release"
STUB
printf '#!/bin/sh\necho 4\n' > "$work/bin/nproc"
printf 'MemTotal: 8388608 kB\n' > "$work/meminfo"
chmod +x "$work/bin/uname" "$work/bin/nproc"
for tool in ip sysctl systemctl systemd-run systemd-sysusers; do
  cat > "$work/bin/$tool" <<STUB
#!/bin/sh
echo "$tool \$*" >> "$work/calls"
case "$tool \$1 \$2" in
  "ip link show") grep -q "^tap \$3\$" "$work/taps" 2>/dev/null ;;
  "ip tuntap add") echo "tap \$4" >> "$work/taps" ;;
  "systemctl is-active --quiet") grep -q "^unit \$3\$" "$work/units" 2>/dev/null ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$work/bin/$tool"
done
cat > "$work/bin/systemd-run" <<STUB
#!/bin/sh
printf '%s\n' "\$@" > "$work/last-run"
for arg; do case "\$arg" in --unit=*) echo "unit \${arg#--unit=}.service" >> "$work/units" ;; esac; done
STUB
chmod +x "$work/bin/systemd-run"

mkdir -p "$work/agent/current/lib/foreman_agent-1.2.3/priv/tools/vm"
printf '#!/bin/sh\n' > "$work/agent/current/lib/foreman_agent-1.2.3/priv/tools/vm/cloud-hypervisor"
chmod +x "$work/agent/current/lib/foreman_agent-1.2.3/priv/tools/vm/cloud-hypervisor"

cat > "$work/vmctl.conf" <<CONF
SRV=$work/srv
AGENT_ROOT=$work/agent
AGENT_USER=foreman
POOL=10.250
STATE=$work/state
RESOLV=$work/resolv.conf
LSM=$work/lsm
MEMINFO=$work/meminfo
CONF

# A box whose resolv.conf Tailscale wrote: MagicDNS first.
printf 'nameserver 100.100.100.100\nnameserver 192.168.1.1\nsearch tail.ts.net\n' > "$work/resolv.conf"

guest=$(printf 'a%.0s' $(seq 64))
mkdir -p "$work/srv/guest/$guest"
: > "$work/srv/guest/$guest/vmlinuz"
: > "$work/srv/agent-disks/1.2.3.img"

env1=6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f
env2=0b8e3a6c-5d2f-4e1a-9c7b-3f2e1d0c9b8a
for env in $env1 $env2; do
  mkdir -p "$work/srv/vms/$env"
  : > "$work/srv/vms/$env/root.raw"
  : > "$work/srv/vms/$env/data.raw"
done

ask() { printf '%s\n' "$1" | PATH="$work/bin:$PATH" FOREMAN_VMCTL_CONF="$work/vmctl.conf" sh "$vmctl"; }

expect() { # description, request, answer pattern (grep -E)
  got=$(ask "$2")
  if printf '%s' "$got" | grep -Eqx "$3"; then pass "$1"; else fail "$1 (got: $got)"; fi
}

# The helper must refuse before allocating a tap or launching a unit.
mkdir "$work/state/lock"
expect "refuses an inaccessible lock file" "start $env1 2 1024 $guest 1.2.3" "error cannot open VM helper lock"
rmdir "$work/state/lock"
printf '#!/bin/sh\nexit 1\n' > "$work/bin/flock"
chmod +x "$work/bin/flock"
expect "refuses a failed state lock" "start $env1 2 1024 $guest 1.2.3" "error cannot acquire VM helper lock"
rm "$work/bin/flock"
check "failed locks leave addresses untouched" test ! -e "$work/state/nets"
check "failed locks never touch networking or units" test ! -e "$work/calls"
check "failed locks never launch a unit" test ! -e "$work/last-run"

# -- refusals --------------------------------------------------------------
expect "says its version" "version" "ok 3"
expect "says the box's resolvers, not MagicDNS" "resolvers" "ok 192.168.1.1"
expect "refuses an unknown request" "reboot" "error unknown request"
expect "refuses characters outside its vocabulary" "start ../../etc/shadow 1 2" "error unexpected characters"
expect "refuses a shell metacharacter" "stop \$(id)" "error unexpected characters"
expect "refuses capitals" "STOP $env1" "error unexpected characters"
expect "refuses an id that isn't one" "stop not-an-id" "error stop takes ENV_ID"
expect "refuses a path for an id" "start ..-..-etc 1 1024 $guest 1.2.3" "error bad environment id"
expect "refuses zero CPUs" "start $env1 0 1024 $guest 1.2.3" "error bad CPU count"
expect "refuses too little memory" "start $env1 2 100 $guest 1.2.3" "error bad memory size"
expect "rejects CPUs beyond the host" "start $env1 5 1024 $guest 1.2.3" "error requested CPUs exceed host capacity"
expect "rejects restored memory beyond the host" "restore $env1 1 8193" "error requested memory exceeds host capacity"
expect "refuses a guest image that isn't a SHA-256" "start $env1 2 1024 abc 1.2.3" "error bad guest image"
expect "refuses an agent version that isn't one" "start $env1 2 1024 $guest 1.2" "error bad agent version"
expect "refuses a VM whose disks aren't there" "start $env1 2 1024 $guest 9.9.9" "error missing .*/agent-disks/9.9.9.img"
expect "refuses a restore without a snapshot" "restore $env1 2 1024" "error no snapshot"
expect "says the box's kernel has Landlock" "landlock" "ok"
no_landlock="error this box's kernel has no Landlock: environment VMs need Linux 6.2 or later with landlock in its LSM list"
printf 'lockdown,capability,yama,apparmor' > "$work/lsm"
expect "says when the kernel has no Landlock" "landlock" "$no_landlock"
expect "refuses to start a VM without Landlock" "start $env1 2 1024 $guest 1.2.3" "$no_landlock"
mkdir -p "$work/srv/vms/$env1/snapshot"
: > "$work/srv/vms/$env1/snapshot/config.json"
expect "refuses to restore a VM without Landlock" "restore $env1 2 1024" "$no_landlock"
rm -r "$work/srv/vms/$env1/snapshot"
rm "$work/lsm"
expect "says when the kernel has no LSM list" "landlock" "$no_landlock"
printf 'lockdown,capability,landlock,yama,apparmor' > "$work/lsm"
printf '6.1.0-28-amd64\n' > "$work/release"
expect "says when the kernel's Landlock is too old for Cloud Hypervisor" "landlock" "$no_landlock"
printf '7.0.14-generic\n' > "$work/release"
expect "takes a kernel past 6" "landlock" "ok"
printf '6.2\n' > "$work/release"
expect "takes 6.2 itself" "landlock" "ok"
printf 'x.y\n' > "$work/release"
expect "refuses a kernel release it can't read" "landlock" "$no_landlock"
printf '6.12.117-flatcar\n' > "$work/release"
check "nothing refused for Landlock made a tap" sh -c "! grep -q 'tuntap' '$work/calls' 2>/dev/null"
long=$(printf 'stop %0201d' 0)
expect "refuses a long request" "$long" "error request too long"
ln -s /etc/passwd "$work/srv/vms/$env2/data.raw.link"
mv "$work/srv/vms/$env2/data.raw" "$work/srv/vms/$env2/data.raw.real"
mv "$work/srv/vms/$env2/data.raw.link" "$work/srv/vms/$env2/data.raw"
expect "refuses a disk that's a symlink" "start $env2 2 1024 $guest 1.2.3" "error missing .*/data.raw"
rm "$work/srv/vms/$env2/data.raw"
mv "$work/srv/vms/$env2/data.raw.real" "$work/srv/vms/$env2/data.raw"
# Cloud Hypervisor opens its log and the serial console's before Landlock
# confines it, and the VM's directory is the VM's to write: a symlink
# left there would be followed as the agent's user, unconfined.
vm2=$work/srv/vms/$env2
ln -s /etc/passwd "$vm2/ch.log"
expect "refuses a VM whose log is a symlink" "start $env2 2 1024 $guest 1.2.3" "error .*/ch.log isn't a plain file"
rm "$vm2/ch.log"
ln -s "$work/nowhere" "$vm2/serial.log"
expect "refuses a VM whose console log is a symlink, even to nothing" "start $env2 2 1024 $guest 1.2.3" \
  "error .*/serial.log isn't a plain file"
rm "$vm2/serial.log"
mkfifo "$vm2/serial.log"
expect "refuses a console log that isn't a file" "start $env2 2 1024 $guest 1.2.3" "error .*/serial.log isn't a plain file"
rm "$vm2/serial.log"
check "nothing refused started a VM" test ! -e "$work/last-run"

# -- start -----------------------------------------------------------------
expect "starts a VM on the first address" "start $env1 2 2048 $guest 1.2.3" "ok started fm-vm0 10.250.0.2"
run=$(cat "$work/last-run")
has() { if printf '%s\n' "$run" | grep -qxF -- "$2"; then pass "$1"; else fail "$1: no '$2' in: $run"; fi; }
has "in a unit of its own" "--unit=foreman-vm-$env1"
has "as the agent's user" "--uid=foreman"
has "limited to its CPUs" "CPUQuota=200%"
has "limited to its memory and some" "MemoryMax=2560M"
has "on its tap" "tap=fm-vm0,mac=52:54:00:fa:00:00"
has "confined by Landlock" "--landlock"
has "to its own directory" "path=$work/srv/vms/$env1,access=rw"
has "and its guest image, read-only" "path=$work/srv/guest/$guest,access=r"
has "and its agent disk, read-only" "path=$work/srv/agent-disks/1.2.3.img,access=r"
has "and the tun device" "path=/dev/net/tun,access=rw"
has "and its tap's flags" "path=/sys/devices/virtual/net/fm-vm0,access=r"
check "with its address and the box's resolvers, not MagicDNS, on the kernel command line" grep -qx \
  "console=ttyS0 root=/dev/vda rw quiet net.ifnames=0 fm.mac=52:54:00:fa:00:00 fm.ip=10.250.0.2/30 fm.gw=10.250.0.1 fm.dns=192.168.1.1 fm.env=$env1" "$work/last-run"
has "booting the release's agent disk read-only" "path=$work/srv/agent-disks/1.2.3.img,image_type=raw,readonly=on,serial=fm-agent"
# systemd opens a unit's output files as root, following symlinks, and the
# VM's directory is the agent's: nothing there is opened for it.
check "has systemd open nothing in the VM's directory" sh -c "! grep -q 'append:\|file:\|truncate:' '$work/last-run'"
has "sends the unit's output to the journal" "StandardOutput=journal"
has "has Cloud Hypervisor write its own log, as the agent's user" "$work/srv/vms/$env1/ch.log"
check "after --log-file" grep -A1 -qxF -- "--log-file" "$work/last-run"
has "sees no other VM's disks" "TemporaryFileSystem=$work/srv:ro"
has "sees its own directory" "BindPaths=$work/srv/vms/$env1"
has "sees the guest images and agent disks read-only" "BindReadOnlyPaths=$work/srv/guest $work/srv/agent-disks"
has "can't see the box's secrets, identity or settings, or reach this helper" \
  "InaccessiblePaths=-/run/foreman -/var/lib/foreman-agent -/etc/foreman-agent -$work/state -/run/foreman-vmctl.sock -/sys/fs/cgroup/foreman.slice -/run/systemd/private -/run/dbus/system_bus_socket"
has "uses its tap group as the primary VM group" "--gid=foreman-tap0"
has "hides processes outside the VM's ptrace permissions" "ProtectProc=ptraceable"
check "its tap requires its own group" grep -q 'ip tuntap add dev fm-vm0 mode tap user foreman group foreman-tap0' "$work/calls"
check "gives the box's end its address" grep -q "ip addr replace 10.250.0.1/30 dev fm-vm0" "$work/calls"
check "keeps the guests' resolvers for the firewall's loader" grep -qx "192.168.1.1" "$work/state/guest-dns"
expect "says which tap a VM has" "tap $env1" "ok fm-vm0"
expect "says when a VM has no tap" "tap $env2" "error the environment has no address"
expect "refuses a tap request without an id" "tap not-an-id" "error tap takes ENV_ID"
expect "a VM that's running isn't started twice" "start $env1 2 2048 $guest 1.2.3" "ok running"
printf 'nameserver 100.100.100.100\n' > "$work/resolv.conf"
expect "a second VM gets the next address" "start $env2 1 1024 $guest 1.2.3" "ok started fm-vm1 10.250.0.6"
check "a box with only MagicDNS gives its guests 1.1.1.1" grep -q "fm.dns=1.1.1.1 " "$work/last-run"

# -- release and restore -----------------------------------------------------
expect "releases a VM" "release $env1" "ok"
check "removes its tap" grep -q "ip link del fm-vm0" "$work/calls"
check "frees its address" test ! -e "$work/state/nets/0"
mkdir -p "$work/srv/vms/$env2/snapshot"
: > "$work/srv/vms/$env2/snapshot/config.json"
sed -i.bak "/foreman-vm-$env2/d" "$work/units"
: > "$work/last-run"
# What a restore opens before Landlock confines it: the snapshot, the
# disks, and the logs.
ln -s /etc/passwd "$vm2/snapshot/memory-ranges"
expect "refuses a snapshot with a symlink in it" "restore $env2 1 1024" "error .*/snapshot/memory-ranges isn't a plain file"
rm "$vm2/snapshot/memory-ranges"
ln -s /etc/passwd "$vm2/snapshot/.state.json"
expect "refuses a snapshot with a hidden symlink in it" "restore $env2 1 1024" "error .*/snapshot/.state.json isn't a plain file"
rm "$vm2/snapshot/.state.json"
mkdir "$vm2/snapshot/more"
expect "refuses a snapshot with a directory in it" "restore $env2 1 1024" "error .*/snapshot/more isn't a plain file"
rmdir "$vm2/snapshot/more"
mv "$vm2/snapshot" "$vm2/snapshot.real"
ln -s snapshot.real "$vm2/snapshot"
expect "refuses a snapshot directory that's a symlink" "restore $env2 1 1024" "error .*/snapshot isn't a plain directory"
rm "$vm2/snapshot"
mv "$vm2/snapshot.real" "$vm2/snapshot"
mv "$vm2/data.raw" "$vm2/data.raw.real"
ln -s data.raw.real "$vm2/data.raw"
expect "refuses to restore onto a disk that's a symlink" "restore $env2 1 1024" "error missing .*/data.raw"
rm "$vm2/data.raw"
mv "$vm2/data.raw.real" "$vm2/data.raw"
ln -s /etc/passwd "$vm2/serial.log"
expect "refuses to restore with a console log that's a symlink" "restore $env2 1 1024" "error .*/serial.log isn't a plain file"
rm "$vm2/serial.log"
check "nothing refused restored a VM" test ! -s "$work/last-run"
expect "restores a VM on the address it had" "restore $env2 1 1024" "ok restored fm-vm1 10.250.0.6"
check "from its own snapshot" grep -qxF -- \
  "source_url=file://$work/srv/vms/$env2/snapshot,memory_restore_mode=copyonwrite,resume=true" "$work/last-run"
expect "stops a VM" "stop $env2" "ok"

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed" >&2; exit 1; }
echo "all checks passed"
