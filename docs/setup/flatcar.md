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

## On bare metal, or another hypervisor

**Add a box → Flatcar** offers the box's first-boot config for amd64 and
arm64. It holds the join token and the box's Tailscale key, so keep it to
yourself. Boot Flatcar's live image (USB or PXE, see
[Installing to disk](https://www.flatcar.org/docs/latest/deploy/bare-metal/installing-to-disk/))
and install it with the config:

```sh
sudo flatcar-install -d /dev/sda -i studio-amd64.ign
sudo reboot
```

Any hypervisor that can boot Flatcar takes the same config: Proxmox,
libvirt or a cloud, each the way Flatcar's docs describe.

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
