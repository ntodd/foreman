# Flatcar boxes

A box can run [Flatcar Container Linux](https://www.flatcar.org/)
instead of a general-purpose distribution: as a VM on a Mac (see
[mac.md](mac.md)) or on a Linux machine with KVM, or straight on the
hardware. Flatcar is a small, read-only OS built to run containers. It
updates itself to its other partition and rolls back if the new one
doesn't boot, and it has Docker, git and nftables already.

What a Flatcar box gets you over the install script on Ubuntu:

- **The OS updates itself.** Nothing to `apt upgrade`. An update waits
  for a reboot, which Foreman shows on the box's page, and an admin
  reboots it from there.
- **As a VM, environments are walled off from the machine it runs on.**
  Code in an environment that gets out of its container is in the VM,
  not on your desktop.
- **It's set up from Foreman.** "Add a box" makes the box's first-boot
  config, and the box sets itself up and enrolls on its first boot.

## How a box sets itself up

**Boxes → Add a box** creates the join token as usual and offers four
ways in: **Linux** (the install script), **Mac**, **Linux VM** and
**Flatcar**. The last three boot Flatcar with a first-boot config
([Ignition](https://www.flatcar.org/docs/latest/provisioning/ignition/))
that the control plane makes for the token. On its first boot the box:

1. Adds Docker Compose and Tailscale as system extensions from Flatcar's
   [sysext bakery](https://extensions.flatcar.org), checked against
   digests pinned in Foreman.
2. Joins the tailnet with a key of its own (see
   [The box on the tailnet](#the-box-on-the-tailnet)).
3. Waits until the control plane answers, then runs its install script
   with the join token, which installs the agent, the box's firewall and
   the reboot unit, and enrolls the box.
4. Deletes the join token and the Tailscale key from the disk.

Progress shows on the box's console (`foreman-box logs` for the
launchers). It usually takes a minute or two; most of it is downloads.

The join token expires in an hour, like every join token. A box that
first boots after that can't enroll; make a new token and a new config.

## On a Linux machine, as a VM

```sh
curl -fsSL https://desktop.tail1234.ts.net/agent/vm.sh | sudo sh -s -- --token fj_...
```

Run it on the machine that hosts the box. It needs systemd and KVM
(`/dev/kvm`). On Debian and Ubuntu it installs QEMU and the UEFI firmware
if they're missing (`qemu-system-x86 ovmf`, or `qemu-system-arm
qemu-efi-aarch64` on arm64); elsewhere, install them first. Then it:

- downloads Flatcar, checks it against the digest pinned in the script,
  and writes the box's disk, `/var/lib/foreman-box/disk.img`, a sparse
  file that only takes what the box uses;
- installs `foreman-box.service`, which runs QEMU as the `foreman-box`
  user, sandboxed by systemd, with nothing of the machine but KVM and its
  own directory;
- starts the box, prints its progress, and returns once it has enrolled.

| Option | Default | |
|---|---|---|
| `--cpus N` | half the machine's | virtual CPUs |
| `--memory GiB` | half the machine's, at most 16 | |
| `--disk GiB` | 100 | the disk's size; the file grows into it |
| `--ssh-port N` | 2222 | where `foreman-box ssh` reaches the box, on 127.0.0.1 |

The box reaches the network through QEMU's user-mode networking (IPv4):
it connects out through this machine, and nothing on this machine's
network changes, Docker's included. Nothing can connect in, which a box
doesn't need; the agent dials out. From inside the VM, this machine is
the gateway, `10.0.2.2`, which reaches its loopback: a control plane on
the same machine can listen on 127.0.0.1 and the box still reaches it.
The box's firewall keeps environments from reaching it. Freed memory goes back to the machine (the
balloon's free page reporting), so a box that ran a big build doesn't
hold on to it.

Running the script again updates the launcher and keeps the box, its
disk and its enrollment; it needs no token. `--cpus` and `--memory` then
change the box's size from its next start.

`foreman-box` manages the box:

| Command | |
|---|---|
| `foreman-box status` | size, disk use, whether it's running |
| `foreman-box stop`, `start`, `restart` | stop shuts the box down cleanly (its power button), and waits for it |
| `foreman-box ssh` | a shell on the box as `core` |
| `foreman-box logs` | the box's console |
| `foreman-box uninstall --yes` | stops the box and deletes it, disk and all; revoke it in Foreman too |

The box starts with the machine. When the machine shuts down, systemd
shuts the box down first.

## On Proxmox

Flatcar publishes a disk image for Proxmox VE, and a VM made from it
takes the box's first-boot config from its cloud-init drive. Proxmox is
a [community-supported](https://www.flatcar.org/docs/latest/deploy/virt-options/proxmoxve/)
Flatcar platform: it works, but Flatcar's release tests don't run on it.
The commands below are Flatcar's own, with the box's config and size
added. Run them as root on the Proxmox host.

Before the first box, let a storage hold snippets, which is where
Proxmox reads custom cloud-init files from: **Datacenter → Storage →
local → Edit → Content**, and add **Snippets**. The examples use `local`
for the snippet and `local-lvm` for disks; use your own storage names.

1. In Foreman, **Boxes → Add a box → Flatcar**, and download the amd64
   config (`studio-amd64.ign` for a box named `studio`). The join token
   in it lasts an hour, so the box has to boot for the first time within
   the hour.

2. Copy it to the Proxmox host's snippets, readable by root alone. It
   holds the join token and the box's Tailscale key:

   ```sh
   scp studio-amd64.ign root@pve:/var/lib/vz/snippets/studio.ign
   ssh root@pve chmod 600 /var/lib/vz/snippets/studio.ign
   ```

3. On the Proxmox host, download Flatcar's image, make the VM, grow its
   disk and start it:

   ```sh
   VM_ID=123   # any free id
   wget https://stable.release.flatcar-linux.net/amd64-usr/current/flatcar_production_proxmoxve_image.img

   qm create "$VM_ID" --name studio \
     --bios ovmf --efidisk0 local-lvm:1 \
     --arch x86_64 --machine q35 --args "-machine sata=off" \
     --cpu host --cores 8 --memory 16384 \
     --net0 "virtio,bridge=vmbr0" --ipconfig0 "ip=dhcp" \
     --virtio0 "local-lvm:0,import-from=$PWD/flatcar_production_proxmoxve_image.img" --boot order=virtio0 \
     --scsihw virtio-scsi-pci --scsi0 local-lvm:cloudinit \
     --cicustom "user=local:snippets/studio.ign" \
     --onboot 1

   qm disk resize "$VM_ID" virtio0 100G
   qm start "$VM_ID"
   ```

   The image's disk is small; Flatcar grows its filesystem into
   whatever the disk is resized to when it boots. `--cores`, `--memory`
   and the disk size are the box's, so set them for the environments it
   will run. `--cpu host` gives the box the machine's own CPU features,
   and `--onboot 1` starts it with the host.

4. Watch the VM's console in Proxmox. The box prints its progress as
   `foreman-box: …` lines and ends with `enrolled; this box shows as
   online in Foreman`. It usually takes a minute or two.

5. Once it has enrolled, the token and the key in the snippet are spent,
   but they're still on the host. Proxmox reads the file each time the
   VM starts, so put an empty config in its place rather than deleting
   it:

   ```sh
   echo '{"ignition":{"version":"3.4.0"}}' > /var/lib/vz/snippets/studio.ign
   ```

   Flatcar only applies a first-boot config once, so the box doesn't
   notice.

Things to know:

- **The network.** The box takes its address from DHCP on the bridge and
  only connects out: to the control plane over the tailnet, and to
  Flatcar, the extension bakery, registries and your git host over the
  internet. Nothing needs to reach it. Give it a DHCP reservation if you
  want a fixed address.
- **The gateway.** The box's firewall keeps environments from reaching
  the VM's gateway address, DNS aside (see
  [security.md](../security.md)). If the Proxmox host does the VM's NAT,
  that address is the host, which is the point. Anything environments
  need should live somewhere other than the gateway's own address.
- **No login.** The config from Add a box has no password and no SSH
  key, so nobody can log in to the box, the console included. For a
  shell as `core`, ask the control plane for the config with your public
  key instead of downloading it from the page, from a machine that
  reaches the control plane:

  ```sh
  curl -fsS -X POST https://desktop.tail1234.ts.net/agent/flatcar/ignition \
    --data-urlencode "join_token=fj_..." --data-urlencode "arch=amd64" \
    --data-urlencode "ssh_keys[]=$(cat ~/.ssh/id_ed25519.pub)" -o studio.ign
  ```

- **One VM, one box.** A box's identity is on its disk. Don't clone an
  enrolled VM or turn it into a template; make each box from the image
  with a token and a config of its own.
- **Removing it.** Revoke the box in Foreman, `qm stop` and `qm destroy`
  the VM, delete its snippet, and remove its node from the tailnet.

## On bare metal

Flatcar installs from its live image onto the machine's disk, with the
box's config beside it. The machine needs a wired network with DHCP
and a disk you don't mind losing: **the install erases it.**

1. In Foreman, **Boxes → Add a box → Flatcar**, and download the config
   for the machine's architecture. It holds the join token and the box's
   Tailscale key, so keep it to yourself. The token lasts an hour.

2. Boot the machine from Flatcar's
   [live ISO](https://www.flatcar.org/docs/latest/deploy/bare-metal/booting-with-iso/)
   on a USB stick. It starts a shell on the console without asking for
   a password. The ISO only boots in BIOS (CSM) mode; on a machine that
   is UEFI only, boot any Linux live image instead and fetch
   `flatcar-install` as
   [Installing to disk](https://www.flatcar.org/docs/latest/deploy/bare-metal/installing-to-disk/)
   describes. The installed box boots either way.

3. Get the config onto the live system. From a second USB stick:

   ```sh
   lsblk                       # find the stick, say /dev/sdb1
   sudo mount /dev/sdb1 /mnt
   cp /mnt/studio-amd64.ign .
   sudo umount /mnt
   ```

   Or over the network: `sudo passwd core` on the console, then `scp`
   the file to `core@` the machine's address.

4. Find the disk to install to, and install. `flatcar-install` downloads
   Flatcar, checks its signature and writes it over the whole disk:

   ```sh
   lsblk                       # the machine's own disk, say /dev/nvme0n1
   sudo flatcar-install -d /dev/nvme0n1 -C stable -i studio-amd64.ign
   ```

5. Take the USB sticks out and `sudo reboot`. On its first boot from the
   disk the box sets itself up and enrolls; the console shows the same
   `foreman-box: …` lines, ending with `enrolled`. The box deletes the
   config from its disk when it's done. Delete your copy too.

The **No login** note above applies here as well: without an SSH key in
the config, the installed box has no way in.

## On another hypervisor

Any hypervisor that can boot Flatcar takes the same config: libvirt or
a cloud, each the way [Flatcar's docs](https://www.flatcar.org/docs/latest/)
describe. A box only needs to connect out.

## The box on the tailnet

The control plane is only on the tailnet, so a Flatcar box joins it as a
node of its own. With a Tailscale OAuth client set up (see
[tailscale.md](tailscale.md)), the control plane mints each Flatcar box a
single-use, pre-authorized key when its config is made, tagged
`tag:foreman-box` (`FOREMAN_TAILSCALE_BOX_TAGS` changes the tags). Add
the tag to the policy and to the OAuth client, and let boxes reach the
control plane:

```jsonc
"tagOwners": {
  "tag:foreman-box": ["autogroup:admin"]
},
"grants": [
  {"src": ["tag:foreman-box"], "dst": ["tag:foreman"], "ip": ["443"]}
]
```

Without an OAuth client, "Add a box" takes a key you made in the
Tailscale console (**Settings → Keys**), stored encrypted with the token.
Without either, the box only reaches the control plane if its network
does: a Mac's VM, for one, goes out through the Mac, and so reaches the
tailnet if the Mac is on it.

The box's own node is like any box's: its firewall keeps environments
from reaching the tailnet as the box, and environments join the tailnet
as nodes of their own (see
[tailscale.md](tailscale.md#boxes-on-the-tailnet)). Revoking a box in
Foreman doesn't remove its node; remove it in the admin console.

## Updates and reboots

- **Flatcar** checks for updates itself and applies one to its other
  partition. The install script turns off Flatcar's reboot manager
  (`REBOOT_STRATEGY=off`) and flags the waiting update the way Debian
  flags one, as `flatcar-<version>`.
- **Compose and Tailscale** update from the bakery (systemd-sysupdate,
  daily), and a new one is flagged the same way.
- **The agent** updates itself from the control plane, as on any box.

A flagged update shows as **This box needs a reboot** on the box's page,
with **Reboot now**. Environments stop for the reboot and come back once
the agent rejoins. Nothing reboots the box on its own. If the new
partition doesn't boot, Flatcar goes back to the old one.

## Performance

A VM costs little where it counts. Measured with the launchers as they
ship, the box against Docker with the same four CPUs and 8 GB, on a
clean `mix compile` of the control plane (deps and NIFs included), `npm
ci --offline` of a React, Next, MUI, Jest and webpack tree, and fio:

| Linux, i7-12700 | Docker on the host | Flatcar VM (`vm.sh`) |
|---|---|---|
| `mix compile` | 36.3 s | 34.5 s |
| `npm ci` | 3.6 s | 4.2 s |
| 4K random read | 435K IOPS | 346K IOPS |
| 4K random write | 398K IOPS | 360K IOPS |
| 1 MB sequential write | 6.0 GB/s | 6.0 GB/s |
| A 470 MB download | 65 MB/s | 67 MB/s |

| Mac, M4 Max | Docker Desktop, volume | Docker Desktop, bind mount | Flatcar VM (`mac.sh`) |
|---|---|---|---|
| `mix compile` | 19.0 s | 23.4 s | 19.4 s |
| `npm ci` | 4.9 s | 28.5 s | 4.4 s |
| 4K random read | 191K IOPS | 65K IOPS | 321K IOPS |
| 4K random write | 156K IOPS | 51K IOPS | 270K IOPS |
| 1 MB sequential write | 14.7 GB/s | 4.4 GB/s | 16.2 GB/s |

The box's disk is a sparse file, so the first write to a part of it
costs the host an allocation; rewrites run at full speed. Flatcar on
bare metal is just Linux, with no VM at all.
