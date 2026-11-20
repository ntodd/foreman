#!/bin/sh
# Boots the guest system image under Cloud Hypervisor, with the agent
# release on its agent disk, and checks the agent on the box can drive
# the agent in the VM over hybrid vsock: hello, queries, a command run in
# the guest, a host-only command refused, and a page cache reclaim
# through the guest's root helper, drain included. Then powers the VM
# off, boots it again on the same data disk (which mustn't be formatted
# twice), and checks no unit failed.
#
#   e2e/guest/run.sh GUEST_TAR AGENT_TARBALL
#
# Needs /dev/kvm (read and write for this user), zstd and mkfs.ext4. No
# network and no root: the VM has no NIC.
set -eu

guest_tar=$(realpath "$1")
agent_tar=$(realpath "$2")
fail() { echo "e2e/guest: $*" >&2; exit 1; }

if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then fail "needs read and write access to /dev/kvm"; fi

# Unix socket paths are short; keep everything under /tmp.
dir=$(mktemp -d /tmp/fm-guest.XXXXXX)
pid=""
cleanup() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  rm -rf "$dir"
}
trap cleanup EXIT

echo "e2e/guest: unpacking"
mkdir "$dir/guest" "$dir/rel" "$dir/run"
tar -xf "$guest_tar" -C "$dir/guest"
zstd -q -d --sparse "$dir/guest/root.raw.zst" -o "$dir/run/root.raw"
tar -xzf "$agent_tar" -C "$dir/rel"
set -- "$dir"/rel/lib/foreman_agent-*/priv/tools/vm/cloud-hypervisor
ch=$1
[ -x "$ch" ] || fail "the agent release has no Cloud Hypervisor"
size=$(( $(du -sm "$dir/rel" | cut -f1) * 13 / 10 + 64 ))
mkfs.ext4 -q -F -L fm-agent -d "$dir/rel" "$dir/run/agent.img" "${size}M"
env_id=6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f
mkdir "$dir/seed"
printf '%s\n' "$env_id" > "$dir/seed/.env-id"
mkfs.ext4 -q -F -L fm-data -d "$dir/seed" "$dir/run/data.raw" 8G
uuid=$(blkid -p -s UUID -o value "$dir/run/data.raw")

# Boot the offline initializer with an independent copy and inspect its
# filesystem before using the normal guest boot path. Keep any panic on
# the serial console so a later reboot cannot hide a failed first boot.
mkdir -p "$dir/fixture/docker/volumes/test" "$dir/fixture/srv"
echo old-volume > "$dir/fixture/docker/volumes/test/canary"
echo keep > "$dir/fixture/srv/clone"
mkfs.ext4 -q -F -d "$dir/fixture" "$dir/run/adopt.raw" 64M
timeout 90 "$ch" --kernel "$dir/guest/vmlinuz" \
  --cmdline "console=ttyS0 root=/dev/vda ro quiet panic=0 init=/usr/local/lib/foreman-guest/adopt fm.env=$env_id" \
  --disk "path=$dir/run/root.raw,image_type=raw,readonly=on,serial=fm-root" \
  --disk "path=$dir/run/adopt.raw,image_type=raw,serial=fm-data" \
  --cpus boot=1 --memory size=256M --serial "file=$dir/run/adopt.log" --console off \
  --landlock --landlock-rules "path=$dir/run,access=rw" "path=$dir/guest,access=r" ||
  { cat "$dir/run/adopt.log"; fail "offline initialization did not exit"; }
grep -aq "^foreman-adopted $env_id" "$dir/run/adopt.log" ||
  { cat "$dir/run/adopt.log"; fail "offline initialization did not finish"; }
[ "$(debugfs -R 'cat /.env-id' "$dir/run/adopt.raw" 2>/dev/null)" = "$env_id" ] || fail "incorrect owner"
[ "$(debugfs -R 'cat /srv/clone' "$dir/run/adopt.raw" 2>/dev/null)" = keep ] || fail "clone lost"
[ -z "$(debugfs -R 'cat /docker/volumes/test/canary' "$dir/run/adopt.raw" 2>/dev/null)" ] || fail "inherited volume"

boot() {
  serial="$dir/run/serial-$1.log"
  rm -f "$dir/run/api.sock" "$dir/run/vsock.sock"
  "$ch" --kernel "$dir/guest/vmlinuz" --cmdline "console=ttyS0 root=/dev/vda rw net.ifnames=0 fm.env=$env_id" \
    --disk "path=$dir/run/root.raw,image_type=raw,direct=on,num_queues=2,serial=fm-root" \
    --disk "path=$dir/run/data.raw,image_type=raw,direct=on,num_queues=2,serial=fm-data" \
    --disk "path=$dir/run/agent.img,image_type=raw,readonly=on,serial=fm-agent" \
    --cpus boot=2 --memory size=2048M --balloon size=0,free_page_reporting=on,deflate_on_oom=on \
    --vsock "cid=3,socket=$dir/run/vsock.sock" --serial "file=$serial" --console off \
    --api-socket "path=$dir/run/api.sock" \
    --landlock --landlock-rules "path=$dir/run,access=rw" "path=$dir/guest,access=r" \
    > "$dir/run/ch-$1.log" 2>&1 &
  pid=$!
}

power_off() {
  i=0
  while kill -0 "$pid" 2>/dev/null; do
    # A failed disk check can appear on the console before logind starts
    # listening for ACPI events. A button press in that window is lost.
    if [ $((i % 20)) -eq 0 ]; then
      if ! curl -fsS --unix-socket "$dir/run/api.sock" -X PUT http://localhost/api/v1/vm.power-button; then
        if kill -0 "$pid" 2>/dev/null; then fail "couldn't send the power button"; fi
        break
      fi
    fi
    i=$((i + 1))
    [ "$i" -lt 120 ] || { tail -n 60 "$serial" >&2; fail "the VM didn't power off within a minute"; }
    sleep 0.5
  done
  pid=""
}

check() {
  cat > "$dir/check.exs" <<EXS
alias ForemanAgent.VM.Link
fail = fn what -> IO.puts("e2e/guest: FAIL #{what}"); System.halt(1) end
{:ok, link} = Link.start_link(socket: "$dir/run/vsock.sock", config: %{"allowed_git_hosts" => ["github.com"]})
Enum.find(1..600, fn _ -> Process.sleep(100); Link.connected?(link) end) || fail.("never connected")
version = :sys.get_state(link).guest_version || (Process.sleep(500); :sys.get_state(link).guest_version)
if version != ForemanAgent.Identity.version(), do: fail.("guest agent #{inspect(version)}")
{:ok, []} = Link.query(link, "inventory")
{:ok, %{}} = Link.query(link, "ports")
{:ok, cmd} = ForemanProtocol.Command.new("box.restart", %{boot_id: ForemanProtocol.uuid()})
{:error, "box.restart isn't run in an environment's VM"} = Link.run(link, cmd, fn _, _ -> :ok end)
{:ok, cmd} = ForemanProtocol.Command.new("box.gc", %{})
{:ok, _} = Link.run(link, cmd, fn _, data -> IO.write(data) end)
# All of the page cache: the root helper reclaims it, compacts, and drains
# the per-CPU free lists (which also checks it put the fraction back).
case Link.reclaim(link, 0) do
  {:ok, %{reclaim: r, compact: "ok", drain: "ok"} = done} when r in ["ok", "partial"] ->
    IO.puts("e2e/guest: reclaimed #{done.file_before_mb - done.file_after_mb} MiB of page cache " <>
      "(#{r}, #{done.reclaim_ms} ms), compacted (#{done.compact_ms} ms), drained (#{done.drain_ms} ms)")
  other -> fail.("reclaim: #{inspect(other)}")
end
IO.puts("e2e/guest: the guest agent (#{version}) answers")
EXS
  "$dir/rel/bin/foreman_agent" eval "$(cat "$dir/check.exs")"
}

for n in 1 2; do
  echo "e2e/guest: boot $n"
  start=$(date +%s)
  boot "$n"
  check || { tail -n 40 "$dir/run/serial-$n.log"; cat "$dir/run/ch-$n.log"; fail "boot $n"; }
  echo "e2e/guest: boot $n answered within $(( $(date +%s) - start ))s"
  power_off
  if grep -a -q "FAILED" "$dir/run/serial-$n.log"; then
    grep -a "FAILED" "$dir/run/serial-$n.log"
    fail "a unit failed on boot $n"
  fi
done

[ "$(blkid -p -s UUID -o value "$dir/run/data.raw")" = "$uuid" ] || fail "data filesystem changed"

# A new disk uses the developer UID. A data disk from the previous
# guest keeps its private files and named volumes under their old IDs.
owner() {
  debugfs -R "stat $1" "$dir/run/data.raw" 2>/dev/null |
    awk '/^User:/ {print $2 ":" $4}'
}
[ "$(owner /srv)" = 1000:1000 ] || fail "unexpected workspace owner on a fresh disk"
mkdir -p "$dir/seed/srv" "$dir/seed/agent"
echo legacy > "$dir/seed/srv/legacy"
chmod 0600 "$dir/seed/srv/legacy"
rm "$dir/run/data.raw"
mkfs.ext4 -q -F -L fm-data -d "$dir/seed" "$dir/run/data.raw" 8G
for path in /srv /srv/legacy /agent; do
  debugfs -w -R "sif $path uid 997" "$dir/run/data.raw"
  debugfs -w -R "sif $path gid 993" "$dir/run/data.raw"
done
boot legacy
check || fail "the guest could not run with a legacy data disk"
power_off
[ "$(owner /srv)" = 997:993 ] || fail "legacy workspace ownership changed"
[ "$(owner /srv/legacy)" = 997:993 ] || fail "legacy file ownership changed"
debugfs -R 'cat /etc/passwd' "$dir/run/root.raw" 2>/dev/null |
  grep -q '^foreman:[^:]*:997:993:' || fail "the guest agent lost access to legacy files"

# Ordinary boots must leave volumes intact when the ownership marker is
# lost or replaced. Work against the stopped ext4 image between boots.
echo canary > "$dir/canary"
debugfs -w -R "mkdir /docker/volumes/check" "$dir/run/data.raw"
debugfs -w -R "write $dir/canary /docker/volumes/check/canary" "$dir/run/data.raw"
debugfs -w -R 'rm /.env-id' "$dir/run/data.raw"
for marker in missing wrong; do
  if [ "$marker" = wrong ]; then
    debugfs -w -R "write $dir/canary /.env-id" "$dir/run/data.raw"
  fi
  boot "$marker"
  i=0
  until grep -aq 'data disk ownership does not match' "$dir/run/serial-$marker.log" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 120 ] || fail "guest did not report the $marker marker"
    sleep 0.5
  done
  power_off
  [ "$(debugfs -R 'cat /docker/volumes/check/canary' "$dir/run/data.raw" 2>/dev/null)" = canary ] ||
    fail "boot with $marker ownership removed the volume"
done

# An unrecognizable data disk must survive a boot attempt byte-for-byte.
printf 'recoverable contents\n' > "$dir/run/data.raw"
truncate -s 16M "$dir/run/data.raw"
before=$(sha256sum "$dir/run/data.raw")
boot damaged
i=0
until grep -aq 'foreman-guest: could not mount data disk' "$dir/run/serial-damaged.log" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 120 ] || fail "guest did not report the unreadable data disk"
  sleep 0.5
done
power_off
[ "$(sha256sum "$dir/run/data.raw")" = "$before" ] || fail "guest modified an unreadable data disk"
echo "e2e/guest: ok"
