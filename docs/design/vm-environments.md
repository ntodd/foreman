# Environment VMs

Status: design spec, 2026-11-16, with the open questions settled for the first implementation in [Implementation decisions](#implementation-decisions). The direction is decided, and the mechanisms were validated in two spikes and a validation run on the same day. Where an implementation decision differs from a requirement below, the decision wins.

This spec replaces the shared-Docker model in [architecture.md](../architecture.md) and [security.md](../security.md): each environment gets its own virtual machine, with its own kernel and its own Docker daemon, under Cloud Hypervisor. The first implementation (protocol 6) is built, and those two documents now describe it; this one keeps the reasoning and the measurements.

## How to read this

Every requirement has an id (`NET-3`, `STO-1`) so design discussions can point at it. Each carries one of these marks:

| Mark | Meaning |
|---|---|
| **Decided** | Nate decided it on 2026-11-16. Changing it is a product decision. |
| **Validated** | Measured or demonstrated in the spikes. The evidence is in [Validation results](#validation-results). |
| **Proposed** | A design recommendation that follows from the results but was not itself tested. |
| **Open** | Needs a decision or more work. Collected in [Open questions](#open-questions). |

## Summary

- One Cloud Hypervisor VM per environment. The VM runs Docker, and the devcontainer runs in that Docker as it does today.
- The agent on the box stops running containers. It becomes a VM manager: it creates disks, taps and VMs, and relays the existing environment commands to an agent inside the guest over vsock.
- The guest is hostile. Everything the guest says is untrusted, and the network policy lives on the box.
- Shared Docker goes away completely. Mac boxes go away with it until [#180](https://github.com/ntodd/foreman/issues/180).
- Prebuilds become possible: a new environment from a prebuilt disk was running 2.5 s after power-on, and a suspended environment was back in 0.3 s.

## Goals

1. **Isolation (primary).** Contain the blast radius of anything running in an environment, a rogue coding agent included. An environment must not reach another environment, the box, or the tailnet as the box.
2. **Fast starts (secondary).** A new environment from a prebuild in seconds, where a cold `devcontainer up` takes minutes.
3. **Docker inside environments.** Privileged containers and docker-in-docker come back, because the VM is now the boundary.
4. **Keep both Linux box types.** A native install on Debian or Ubuntu, and Flatcar (as a VM or on metal).

## Non-goals

- Firecracker. It was looked at earlier and judged too serverless-oriented.
- Mac boxes in this release. They return with [#180](https://github.com/ntodd/foreman/issues/180) on Apple's hypervisor.
- A shared-Docker fallback for boxes without KVM.
- GPU passthrough, live migration between boxes, and nested VMs inside an environment.
- Changing how people reach environments. Each environment stays a tailnet node with Tailscale SSH.

## Decisions

| Id | Decision | Mark |
|---|---|---|
| DEC-1 | Environments move into per-environment Cloud Hypervisor VMs. | Decided |
| DEC-2 | The default Linux install is the agent and Cloud Hypervisor on the host (bare-metal Debian or Ubuntu), with environment VMs directly under the host's KVM. | Decided |
| DEC-3 | Flatcar stays as an option for the outer layer, both as a VM and installed on metal. The docs note the nested-virtualization cost of the VM form. | Decided |
| DEC-4 | Flatcar on metal is wanted but may ship untested at first. Tracked in [#179](https://github.com/ntodd/foreman/issues/179). | Decided |
| DEC-5 | The guest is hostile: "that is the whole point of this architecture, to minimize blast radius of rogue agent." | Decided |
| DEC-6 | Shared Docker is removed outright, with no fallback mode. | Decided |
| DEC-7 | Mac boxes are dropped in the release that removes shared Docker and return with [#180](https://github.com/ntodd/foreman/issues/180): the agent on macOS, environment VMs on Apple's hypervisor. | Decided |
| DEC-8 | Docker-in-docker and privileged containers are turned back on once the VM boundary is verified. | Decided |
| DEC-9 | LAN access from guests: allowed by default, with a per-box option to block it. | Open (recommended) |
| DEC-10 | Environment disks live on a reflink-capable volume (XFS). Full copies on ext4 are a slower fallback. | Open (recommended) |
| DEC-11 | VM environments ship for amd64 only until arm64 has been tested on real hardware. | Open (recommended) |

## Implementation decisions

Settled on 2026-11-16 for the first implementation, so the build has an answer to every open question. Each can be revisited; the reasoning is here so that's cheap.

| Id | Decision |
|---|---|
| DEC-9, NET-14 | Guests reach the box's LAN by default. `install.sh --block-lan` adds the block, with an exception for DNS to the resolvers guests are given. |
| DEC-10, STO-4 | The installer doesn't make volumes: partitioning someone's disks from a script is too easy to get wrong. It checks whether `/srv/foreman` can reflink, says so, and the agent reports it; the box page shows "full copies" when it can't. The setup docs explain how to put `/srv/foreman` on XFS. |
| DEC-11, BOX-4 | amd64 only. An arm64 agent reports that it can't run environment VMs, and the box page says so. |
| SUS-7 | Stop powers the VM off. Suspend is its own action. |
| LIM-8 | Noted in the Flatcar docs; nothing else. |
| ARC-4, ARC-5, ARC-8 | A root helper, `foreman-vmctl`: a POSIX shell script that install.sh puts in `/etc/foreman-agent` (root's, so the agent can't change it), run by a socket-activated unit for each connection on `/run/foreman-vmctl.sock` (group `foreman`, mode 0660). One request line, one answer line. The vocabulary is `version`, `start`, `restore`, `stop` and `release`, each taking an environment id and sizes or versions that it checks against fixed patterns, never paths. It owns the tap, the address and the VM's unit: `systemd-run --unit foreman-vm-<id>` in `foreman.slice`, as the `foreman` user with the `kvm` group, with CPU, memory and task limits and systemd's sandboxing. It builds Cloud Hypervisor's command line itself. VMs are never children of the agent, so they survive agent restarts and updates. |
| ARC-9, ARC-11 | Three disks per VM. `root.raw` is the environment's copy (a reflink where it can be) of the guest system image, and is made again whenever the image changes. `data.raw` is the environment's own, a sparse file the guest formats on first boot and mounts for Docker's data, the clone and the guest agent's state. `agent.img` is a read-only image of the box's agent release, one per agent version, shared by every VM, so the guest always runs the same agent as the host and agent updates don't need a new guest image. |
| ARC-9 | The guest system image (kernel and root filesystem, built from Ubuntu 24.04 packages by `guest/build.sh`) is a release artifact. The release workflow builds it, and the amd64 agent is built with its URL and SHA-256, so the agent downloads it and checks it against a digest it carries. `FOREMAN_GUEST_URL` and `FOREMAN_GUEST_SHA256` override both, for development and the end-to-end run. |
| ARC-12, SUS-4 | The host sends its time with every connection and command, and the guest agent steps its clock when it's more than two seconds out. |
| CHA-7 | The guest runs the same agent release in guest mode (`FOREMAN_AGENT_MODE=guest`): no control plane connection; `Ops`, `Outbox` and the existing environment code; a server on a unix socket that `socat` joins to vsock port 1024. Frames are JSON with a four-byte length, at most 4 MiB from the host (commands carry secrets files) and 1 MiB from the guest. The host sends `hello`, `cmd` (a protocol command, same op id), `cancel`, `ack` and `query` (inventory, ports, reclaim); the guest sends `hello` (with an instance id its `Ops` picks at start), `event` (`op.accepted`, `op.log`, `op.result`, acknowledged like the control plane does) and `reply`. A command resent after a reconnect gets the guest's stored result, exactly as with the control plane; when the instance id changes, the guest has forgotten what it ran, and the host fails the commands it had sent rather than send them again. The host checks every frame: unknown types, events for operations it didn't send and replies for other environments are dropped. Decoding a frame is bounded in memory and time, each operation's log in bytes, and the host stops reading while a caller is behind on its log or past a per-link read-rate limit (the decode runs in the host agent, not the VM's cgroup, so without the limit a guest could spend host CPU its `CPUQuota` never sees). |
| SEC-1, SEC-4 | The host keeps each environment's latest secrets on its own tmpfs, readable by the agent alone, as it does today, and writes them into the guest after every boot and with every `env.secrets.write` while it runs. A stopped environment's secrets write succeeds, so the control plane's order after a reboot (secrets, then start) works unchanged. |
| NET-4 | Each VM gets a /30 from `10.250.0.0/16`, recorded by the helper so a resumed VM gets the same one. `install.sh --vm-subnet` changes the pool. |
| NET-6 | Guests get the box's upstream resolvers (systemd-resolved's list when the box uses its stub), loopback and IPv6 ones dropped, and 1.1.1.1 when that leaves none. |
| NET-10 | Anti-spoofing uses the routing table rather than a set of addresses: `fib saddr . iif oif missing` drops anything a tap sends from an address that isn't routed back through that tap. The table then has no per-VM state, so the firewall's reload every 15 seconds can't wipe it. |
| NET-12 | The firewall unit also accepts forwarding from `fm-` interfaces (and replies to them) at the top of iptables' `FORWARD` chain when iptables is there, for Docker's and ufw's drop policies, and turns on IPv4 forwarding. The reload timer puts the rules back. |
| NET-18 | The helper picks the MAC from the address. The guest finds its NIC by that MAC and retries until udev has settled. |
| SEM-1, SEM-2, SEM-3 | The compose policy (`ForemanAgent.Env.Policy`, `ComposeScan`), `FOREMAN_POLICY` and the policy alerts go, and `initializeCommand` runs (in the guest). |
| LIF-4 | The overlay still strips published ports. Nothing reaches them from outside the box anyway, and Tailscale is how people reach an environment. |
| LIF-5 | Protocol 6. The control plane accepts only protocol 6 agents: a protocol 5 agent runs shared Docker, which this release removes, so it's refused at join with a message to re-run the install script. |
| VM-7 | Size: the environment's or repo's limits when set, otherwise the box's defaults (`FOREMAN_VM_CPUS`, `FOREMAN_VM_MEMORY_MB`, 4 and 8192), capped at the box's own. Disk: `FOREMAN_VM_DISK_GB`, 64. |
| VM-8, STO-8 | No resizing yet. |
| VM-10 | The box asks for a reclaim when it runs short of memory, not on a timer: below `FOREMAN_VM_RECLAIM_BELOW` percent available (20), VMs quiet for ten minutes by their cgroup's CPU (no 30 s sample over half a core: healthchecks and file watchers keep an idle VM over a tenth, and the box sees more than the guest since every vCPU wakes for each one; an idle VM running [#200](https://github.com/ntodd/foreman/issues/200)'s compose stack, healthchecked every second, measured 0.13 cores in the guest and 0.25 to 0.30 from the box, and 0.003 to 0.011 with the stack down), longest quiet first, then biggest, keeping `FOREMAN_VM_RECLAIM_KEEP_MB` (2048), until what the guests say they freed covers the gap to five points past the threshold. Then it waits 90 s for free page reporting and measures again, since the box gets back less than a guest frees. Active VMs aren't asked. An idle timer (`FOREMAN_VM_RECLAIM_IDLE_MINUTES`) is there for a box that wants one, off by default. |
| PRE-3 | A prebuild is for one repo, branch and devcontainer config on one box. A user's own features are applied when the environment is created, so they rebuild only their layer. |
| PRE-4 | The prebuild runs `devcontainer up` with the lifecycle hooks the CLI runs on create, so `onCreateCommand`, `updateContentCommand` and `postCreateCommand` run there; the environment made from it runs `postStartCommand` and, for its new container, the create hooks again. |
| PRE-5 | The prebuild clones with the GitHub App's installation token (contents: read), which is removed before the disk is kept. |
| PRE-6 | Prebuilds live on the box that built them. An environment uses one when its box has a ready prebuild for its repo, branch and config; otherwise it builds cold. |
| PRE-7 | The Foreman feature's entrypoint already skips `tailscale up` without an auth key; the prebuild has none. |
| — | Not in this implementation: memory-snapshot clones (stage 3), idle auto-stop, Flatcar on metal ([#179](https://github.com/ntodd/foreman/issues/179)), Mac boxes ([#180](https://github.com/ntodd/foreman/issues/180)). |

## Box types

| Box | Environment VMs run | Tier | Status |
|---|---|---|---|
| Debian or Ubuntu on metal | under the host's KVM | first class | Validated on Ubuntu (kernel 7.0) |
| Flatcar on metal | under the host's KVM | first class | Not tested, [#179](https://github.com/ntodd/foreman/issues/179) |
| Flatcar as a VM (`vm.sh`, Proxmox) | nested, under the Flatcar VM's KVM | slower | Validated on Flatcar stable 4757.2.3 under QEMU |
| Debian or Ubuntu as a VM (Proxmox, other KVM) | nested, under the VM's KVM | slower | Validated on the production box, Debian 13 in a Proxmox-style VM; see [Nested in a Proxmox-style VM](#nested-in-a-proxmox-style-vm-production-box) |
| Mac | not supported | none | Dropped until [#180](https://github.com/ntodd/foreman/issues/180) |

- **BOX-1 (Validated):** a box needs `/dev/kvm`. A box that is itself a VM needs nested virtualization exposed by its hypervisor (`-cpu host` under QEMU, the CPU type `host` on Proxmox). Proxmox's default CPU type, `x86-64-v2-AES`, hides SVM and VMX: the VM has no `/dev/kvm` and can't run environments at all.
- **BOX-2 (Validated):** nested works but costs CPU-bound and I/O-bound work. A clean compile took 37–57 s nested against 34–36 s on bare KVM, and random I/O was about a third. The Flatcar docs must say so.
- **BOX-3 (Proposed):** the agent reports whether the box has KVM and whether it is nested, and the control plane shows the tier on the box's page.
- **BOX-4 (Open):** arm64. Cloud Hypervisor supports it, but nothing here was run on arm64. See DEC-11.

## Architecture

```
Browser ──LiveView──► Control plane (unchanged)
                         ▲  WSS (agent dials out)
                    host agent (unprivileged)
                         │  asks for taps, firewall entries and VM units
                    VM helper (root, fixed vocabulary)
                         │
        ┌────────────────┼────────────────┐
   cloud-hypervisor  cloud-hypervisor  cloud-hypervisor     one per environment,
        │ vsock           │ vsock           │ vsock          own unit and cgroup
   ┌────┴─────┐      ┌────┴─────┐      ┌────┴─────┐
   │ guest    │      │ guest    │      │ guest    │
   │  agent   │      │  agent   │      │  agent   │
   │ dockerd  │      │ dockerd  │      │ dockerd  │
   │ compose  │      │ compose  │      │ compose  │
   │ project  │      │ project  │      │ project  │──tailscaled──► tailnet
   └──────────┘      └──────────┘      └──────────┘
     tap fm-…          tap fm-…          tap fm-…   ──► box firewall ──► NAT out
```

### Host agent

- **ARC-1 (Proposed):** the host agent keeps its connection, enrollment, protocol and update machinery. It stops talking to Docker. Its job per environment is the disk, the tap, the VM and the vsock relay.
- **ARC-2 (Proposed):** the existing environment code (`ForemanAgent.Env`, the overlay, compose scanning, the Runner and Docker behaviours) moves into the guest agent largely as it is. The Runner and Docker behaviours are already the boundary: on the host they become a relay over vsock.
- **ARC-3 (Proposed):** the host agent holds no trust in anything the guest returns. See [Host and guest channel](#host-and-guest-channel).
- **ARC-4 (Proposed):** a VM must not be a child of the agent. Today the agent kills a command's whole process tree on cancel, and containers survive an agent update because the Docker daemon owns them. VMs need the same property, so each one runs as its own systemd unit (or transient scope) and the agent finds running VMs again after it restarts.

### VM helper

The agent runs unprivileged with `NoNewPrivileges`. Three things an environment VM needs are root's: creating a tap, changing the firewall's guest set, and starting a unit with resource limits in the system slice.

- **ARC-5 (Proposed):** a small root helper with a fixed vocabulary (create tap, delete tap, add or remove a guest in the firewall set, start or stop the VM unit for an environment id). It takes ids and sizes, never paths or command lines. The existing `foreman-restart.path` unit is the precedent for giving the agent one narrow root action.
- **ARC-6 (Validated):** Cloud Hypervisor itself needs no privilege. It ran as an ordinary user in the `kvm` group on a tap that root had created and handed to that user.
- **ARC-7 (Validated):** the mechanisms the helper would use all worked: `ip tuntap add … user <agent>`, an nftables set of `ifname . ipv4_addr`, and `systemd-run --scope --uid --gid -p CPUQuota -p MemoryMax -p IOWriteBandwidthMax`.
- **ARC-8 (Open):** whether the helper is a socket-activated service, templated units (`foreman-vm@<id>.service` plus a path unit), or a setuid-free combination of both.

### Guest

- **ARC-9 (Proposed):** Foreman ships the guest as a release artifact: a kernel and a root filesystem holding Docker, Compose, the devcontainer CLI with its Node, git, and the guest agent. It is signed like the agent release, and a box installs the guest version its agent was built with.
- **ARC-10 (Validated):** a guest built from Ubuntu 24.04 packages (kernel 6.8 `linux-image-virtual`, Docker 29.1.3, Compose 2.40.3, devcontainer CLI 0.90.0) boots by direct kernel boot with no initrd and has Docker ready 1.3–1.4 s after launch.
- **ARC-11 (Proposed):** split the guest's storage into a read-only system disk shared by every VM on the box and a per-environment data disk (Docker's data, the clone, Tailscale state). Guest updates then replace one file, and the system disk's pages are shared between VMs. The spikes used a single disk, so the split is untested.
- **ARC-12 (Proposed):** the guest kernel needs `ptp_kvm` or another way to read the host's clock. The stock `linux-image-virtual` kernel has neither that nor an RTC under Cloud Hypervisor. See SUS-4.
- **ARC-13 (Validated):** the guest's root filesystem can be built with no root and no loop mounts, which suits CI: install the packages in a container, tar the container's own filesystem, and make the image with `mkfs.ext4 -d rootfs.tar`.

## The VM

The validated Cloud Hypervisor v54.1 invocation is in [Appendix B](#appendix-b-cloud-hypervisor-invocations).

- **VM-1 (Validated):** static musl builds of `cloud-hypervisor` and `ch-remote` run unmodified on Ubuntu and on Flatcar. The agent release can carry them, as it carries Node.
- **VM-2 (Validated):** v54 needs `image_type=raw` on every `--disk`.
- **VM-3 (Validated):** disks are attached with `direct=on` and one queue per vCPU.
- **VM-4 (Validated):** the balloon runs with `size=0,free_page_reporting=on,deflate_on_oom=on`. A guest that allocated and freed 3 GB gave it back to the host within 20 s. Only freed pages return: the guest's page cache keeps the VM's memory up until the guest drops it. See VM-10.
- **VM-5 (Proposed):** memory is plain private memory. No virtio-fs, no vhost-user devices, no hugepages, no virtio-mem and no device passthrough: by Cloud Hypervisor's documentation each of those makes copy-on-write restore fall back to a full copy. The tests used none of them.
- **VM-6 (Proposed):** `--cpus nested=off` is the v54 default by its documentation, so a guest cannot start VMs of its own. Keep it.
- **VM-7 (Proposed):** a VM has a fixed size, where containers today have no limits by default. Size comes from the environment's limits, then the repo's defaults, then `hostRequirements`, then a box default. See LIM-5.
- **VM-8 (Open):** resizing a running VM (CPU hotplug, virtio-mem) was not tested. virtio-mem also disables copy-on-write restore.
- **VM-9 (Proposed):** pin the Cloud Hypervisor version and check its digest, as the launchers do for Flatcar and vfkit.
- **VM-10 (Validated):** an idle VM gives back the memory its page cache holds when the guest reclaims its file LRU down to what it keeps, through `memory.reclaim` at its root cgroup, then compacts (`compact_memory`): free page reporting only reports free blocks of 2 MiB or more, and the guest doesn't compact on its own. On the production box, an idle 32 GiB VM holding 14.3 GiB after a session held 6.2 GiB after reclaiming all but 2 GiB of cache and compacting, and the next round of work was 0.7 s slower out of 26 s. `drop_caches` alone, a balloon inflated from the box, `page_reporting_order=0`, and `memory.reclaim` on the VM's cgroup from the box all did worse; see [#200](https://github.com/ntodd/foreman/issues/200). A big reclaim also leaves free pages on the guest's per-CPU lists, which since kernel 6.7 only shrink from per-CPU vmstat work that idle CPUs don't run; a few to a 2 MiB block, they keep those blocks from coalescing. [#203](https://github.com/ntodd/foreman/issues/203)'s run on the production box found about 100 MiB of them holding back some 1,400 blocks, so after compacting, the guest raises `vm.percpu_pagelist_high_fraction`, runs that work on every CPU through `stat_refresh`, compacts again and puts the fraction back as it was, which took 30 to 45 ms there. Reclaiming file pages down to 2 GiB and then draining left the VM holding 8,772 MiB of the box 120 s later (two runs), against 9,366 MiB without the drain (one run). That run drained 30 s after the reclaim; the helper drains straight after it. The writes need root in the guest, so a socket-activated root helper in the guest image (`foreman-guest-reclaim`, on `/run/foreman-reclaim.sock`, root and the guest agent's group) does them, and the agent keeps `CAP_SYS_TIME` alone. On the guest's 6.8 kernel `memory.reclaim` can swap anon pages too; the guest has no swap.

## Storage

- **STO-1 (Validated):** raw disk images. qcow2 overlays are out: an overlay on a raw base managed 11k/6k random IOPS and 151 MB/s sequential against 194k/234k and 2,042 MB/s for raw, and upstream has an open backing-file corruption issue (cloud-hypervisor#8621).
- **STO-2 (Validated):** on XFS, a reflink clone of the environment disk takes 0.01 s or less and no extra space, whatever the image size.
- **STO-3 (Validated):** a full copy works but costs twice. The copy itself took 0.8–1.1 s for 3.5 GB of data, and the first boot then waits for the host to flush the copy to disk, because the VM opens the file with `O_DIRECT`. That added about 1.5 s: the guest mounted its root at 1.7–2.3 s instead of 0.4 s. Both costs grow with image size.
- **STO-4 (Open, recommended):** the installer requires or creates an XFS volume for `/srv/foreman` (DEC-10). ext4 hosts get the full-copy fallback and a note on the box's page.
- **STO-5 (Validated):** the cost of reflink is on the first write to data shared with the prebuild. Random 4K overwrites of shared data ran at 10.5k IOPS against 150k on a full copy, and at 113–137k once the data had been rewritten. Copying 1.2 GB in 17,710 files, sequential writes and fsync-heavy writes showed no penalty.
- **STO-6 (Validated):** tuning did not help. `cowextsize 1m` changed nothing. `direct=off` raised the first-overwrite rate to 47k but doubled the file-copy time, so `direct=on` stays.
- **STO-7 (Validated):** discard works by default. A guest that wrote 3 GB, deleted it and ran `fstrim` returned the space in the host's file (3,510 MB to 6,510 MB and back to 3,509 MB).
- **STO-8 (Proposed):** the disk file's size is the environment's disk quota. Growing it is a truncate plus a filesystem resize in the guest, untested.
- **STO-9 (Proposed):** the guest runs `fstrim` on a timer, or mounts with `discard`, so deleted data returns to the box.
- **STO-10 (Open):** btrfs also has reflinks and was not tested.
- **STO-11 (Validated):** Flatcar's own `mkfs.xfs` turned on features its 6.12 kernel calls experimental (exchange-range, parent pointers). The installer should pass explicit `mkfs.xfs` options.

### Layout on the box (Proposed)

```
/srv/foreman/                      XFS, reflink
  guest/<version>/vmlinuz          guest kernel
  guest/<version>/system.raw       guest system disk, read-only, shared
  prebuilds/<prebuild_id>/data.raw prebuilt data disk
  envs/<env_id>/data.raw           the environment's disk, a reflink of a prebuild or of an empty disk
  envs/<env_id>/snap/              memory snapshot, when suspended
/run/foreman/vms/<env_id>/         api.sock, vsock.sock, serial.log
```

## Networking

### Shape

- **NET-1 (Validated):** one tap per VM, routed, no bridge. The box holds one address of a /30 and the guest the other. With no shared segment there is no ARP spoofing between guests.
- **NET-2 (Validated):** taps are named `fm-…`. The shipped `foreman.nft` matches `iifname "fm-*"`, so its tailnet rules cover a tap with no change: a guest's connections to the box's tailnet address and to a tailnet peer were rejected immediately on a box running the released firewall.
- **NET-3 (Validated):** outbound traffic is masqueraded on the box.
- **NET-4 (Open):** the address pool the /30s come from, and how a box avoids a pool that collides with its LAN. The spikes used `10.250.0.0/16`.
- **NET-5 (Validated):** IPv6 was disabled on the taps and dropped in the firewall. Guests are IPv4-only for now.
- **NET-6 (Open):** DNS. The spikes gave guests a public resolver. A guest cannot use a resolver on the box itself, because input from taps is dropped (NET-8), and the shipped table's MagicDNS exception does not help once that drop is in place. Decide between handing guests the box's upstream resolvers and adding a narrow DNS exception.
- **NET-7 (Open):** network throughput was not measured. v54 turns virtio-net offloads off by default.
- **NET-18 (Open):** how a guest learns its address. The tests passed it on the kernel command line and a script set it at boot. That script raced udev renaming the NIC on slow boots, so whatever does this in the guest agent should pick the NIC by MAC or retry.

### Firewall

The prototype table is in [Appendix A](#appendix-a-firewall-prototype). It loads next to the shipped table and leaves that table alone.

- **NET-8 (Validated):** drop everything arriving from a tap for the box itself, replies aside. Without this a guest reached the box's sshd on the tap's gateway address and on the box's other addresses. The shipped table only rejects tailnet destinations on input.
- **NET-9 (Validated):** drop forwarding from one tap to another. Without this a guest reached its neighbour's sshd.
- **NET-10 (Validated):** pin each tap to its guest's address with a set of `ifname . ipv4_addr`. Packets from a guest with a neighbour's address or a public source address were dropped.
- **NET-11 (Validated):** drop new connections forwarded into a tap. The box can still reach its guests, and reached a port a guest's container had published.
- **NET-12 (Validated):** a box that also runs Docker has a forward policy of drop, so tap traffic needs accept rules in `DOCKER-USER`. This applies to a personal deployment (control plane in Docker on the same machine) and to every Flatcar box.
- **NET-13 (Proposed):** the agent's firewall report covers the new table, so the control plane flags a box without it as it does today.
- **NET-14 (Open, recommended):** guests may reach the box's LAN by default, as environments can today, with a per-box option to block RFC 1918 and link-local destinations (DEC-9). The block rule worked. Blocking probably pushes a guest's Tailscale onto relays for peers on the same LAN, which was not tested.
- **NET-15 (Proposed):** review the gateway table a Flatcar VM box installs today (it keeps environments off the QEMU gateway, which reaches the host's loopback) so that it matches taps.

### Tailscale

- **NET-16 (Proposed):** unchanged. The Foreman feature starts tailscaled in userspace mode in the devcontainer, and its state lives in a Docker volume, now on the environment's disk.
- **NET-17 (Validated):** from a container in a guest, behind the box's NAT and every rule above, tailscaled had working UDP, reached its nearest relay in 13 ms, and was offered a login by the control server. No node was joined to a tailnet in the tests.

## Host and guest channel

- **CHA-1 (Validated):** Cloud Hypervisor's hybrid vsock. The host connects to a unix socket and sends `CONNECT <port>`; a guest's connection to the host lands on `<socket>_<port>`, and only if the host is listening there.
- **CHA-2 (Validated):** it needs no privilege and no network. Every host-tier test drove its guest over vsock with no NIC in the VM.
- **CHA-3 (Validated):** a guest could not reach a host port nothing listened on, and could not reach another guest. Every guest has the same CID and there is no path between them.
- **CHA-4 (Validated):** the channel works again straight after a restore: a command over vsock ran in the app container 0.23–0.36 s after `--restore`.
- **CHA-5 (Proposed):** the host agent treats the guest agent as it treats repo content today. Frames have a length limit, results are validated against a schema, and nothing from the guest becomes a path, an argument or a log line without going through the same redaction and validation as today.
- **CHA-6 (Proposed):** the host connects to the guest, never the other way. The host does not listen on any `<socket>_<port>`.
- **CHA-7 (Open):** the protocol itself: whether it is the existing command vocabulary re-serialised, how logs stream, how a long operation survives a host agent restart, and how the guest agent's version is negotiated.
- **CHA-8 (Proposed):** the host has no IP path into the guest's management. Reaching the guest by IP was only a convenience in the nested tests.

## Secrets

- **SEC-1 (Proposed):** secrets go to the guest over vsock after boot, and the guest agent writes them to tmpfs as the host agent does today. The ordering after a box reboot stays as it is: secrets, then start.
- **SEC-2 (Proposed):** a prebuild never holds secrets. A prebuild is built with no user secrets, no GitHub token and no Tailscale auth key in the guest.
- **SEC-3 (Proposed):** a memory snapshot holds whatever was in the guest's memory, secrets included. Today secrets only ever touch tmpfs, so suspending to disk is a change to the security model. Snapshot files are 0600, owned by the agent, deleted on resume and on destroy, and never copied off the box.
- **SEC-4 (Proposed):** the box no longer holds every environment's secrets in a directory the agent user can read. They pass through the host agent's memory on the way to the guest.

## Lifecycle

How each command in the agent protocol maps:

| Command | Today | With VMs |
|---|---|---|
| `env.create` | clone, overlay, secrets, `devcontainer up` | create the disk (reflink of a prebuild or an empty disk), tap and VM, boot, deliver secrets, then the same steps inside the guest |
| `env.start` | `devcontainer up` | boot or resume the VM, deliver secrets, `devcontainer up` in the guest |
| `env.stop` | `docker compose stop` | graceful stop in the guest, then power off (or suspend, see SUS-7) |
| `env.restart` | stop and start | inside the guest, without restarting the VM |
| `env.rebuild` | recreate containers | inside the guest |
| `env.destroy` | `compose down -v`, delete the clone | power off, delete the disk, snapshot, tap and firewall entry |
| `env.secrets.write` | rewrite the tmpfs directory | relayed |
| `env.logs`, `env.git_status`, `env.connect` | Docker on the box | relayed |
| `box.inventory` | Docker labels | the VM directories and units on the box |
| `box.stats` | `docker stats` | the VM's cgroup, plus the guest's own breakdown (untrusted) |
| `box.gc` | prune images and volumes | prune inside guests, and unused prebuilds on the box |
| `box.restart`, `agent.update` | unchanged | unchanged, see OPS-1 and OPS-2 |

- **LIF-1 (Validated):** `devcontainer up` on a prebuilt disk tried to pull the base image on every start, because BuildKit keeps a build's base in its cache without tagging it in the image store. A prebuild must pull the devcontainer's base images by tag. With that, `devcontainer up` on a stopped environment ran with no network in about 1.2 s, against 3.3 s before.
- **LIF-2 (Validated):** powering off a guest with a running environment took 1.7–2.5 s. Eight at once took 1.9 s.
- **LIF-3 (Proposed):** the overlay's `fm-` bridge names are no longer needed for the box's firewall, since a guest's bridges are its own. The slug stays the compose project name and the Tailscale hostname.
- **LIF-4 (Open):** whether the overlay still strips published ports. Inside a VM a published port is reachable only from the box.
- **LIF-5 (Proposed):** a protocol version bump. An environment needs a VM size, and the control plane needs to know a box runs VMs.

## Prebuilds

Three stages, each useful without the next.

### Stage 1: disk prebuilds

- **PRE-1 (Validated):** a new environment from a prebuilt disk: clone the disk, boot, `devcontainer up`, exec in the app container. On bare KVM with a full copy, 4.4–5.5 s; the guest itself was ready 2.5–2.6 s after power-on. Nested with a reflink clone, 3.5–4.1 s end to end.
- **PRE-2 (Proposed):** on bare KVM with a reflink clone the expected figure is about 2.7 s. That is an estimate from PRE-1, since the test box has no XFS volume.
- **PRE-3 (Open):** what a prebuild is keyed on. At least the repo, the commit or branch, the devcontainer config and the guest version. A user's own devcontainer features go into the image, so they either become part of the key or are applied after the clone.
- **PRE-4 (Open):** which lifecycle hooks run in the prebuild and which after a user takes the environment. Codespaces runs `onCreateCommand` and `updateContentCommand` in the prebuild and `postCreateCommand` after.
- **PRE-5 (Open):** the credential a prebuild clones with. Environment tokens today are scoped user tokens, and a prebuild has no user.
- **PRE-6 (Open):** where prebuilds live. One per box that builds it is simplest; moving them between boxes is a later question.
- **PRE-7 (Proposed):** the Foreman feature's entrypoint must do nothing when there is no auth key, so a prebuild never joins the tailnet.

### Stage 2: suspend and resume

See [Suspend and resume](#suspend-and-resume). Same environment, same disk, same identity, so none of the cloning problems apply.

### Stage 3: new environments from a memory snapshot

- **PRE-8 (Validated):** it works. Four VMs restored from one snapshot of a running environment, each on its own copy of the disk, were all usable within 1.75 s on bare KVM. Each took about 165 MB of memory of its own (PSS) because they share the snapshot's pages. The procedure is in [Appendix C](#appendix-c-cloning-a-vm-from-a-memory-snapshot).
- **PRE-9 (Validated):** the disk clone must be taken while the VM is paused for the snapshot, so memory and disk match. All clones passed a filesystem check after writing.
- **PRE-10 (Validated):** clones are the same machine. They shared `machine-id`, the kernel's `boot_id` and SSH host keys, and would share a Tailscale node key, RNG state and any secret in memory. A clone must be re-keyed before use, and the snapshot must be taken before secrets and the Tailscale join.
- **PRE-11 (Validated):** a clone comes up with the original's address. Nested, two clones were re-addressed over vsock and reached the internet from their app containers at 3.9 s and 5.4 s.
- **PRE-12 (Proposed):** treat stage 3 as later work. Stage 1 already reaches a few seconds, and stage 3 adds the identity problems above.

## Suspend and resume

- **SUS-1 (Validated):** pausing takes 0.01 s. Writing the snapshot of an 8 GB guest took 2.2–3.4 s, and of a 3 GB guest 1.6 s.
- **SUS-2 (Validated):** a snapshot is the guest's full RAM on disk, 8.2 GB for an 8 GB guest that was using 0.3–0.9 GB. It is not sparse.
- **SUS-3 (Validated):** restore with `memory_restore_mode=copyonwrite`. A command ran in the app container 0.23–0.36 s after launch, processes in the container carried on, and the VM used 264–391 MB afterwards. `copy` took 2.3–6.4 s and 8.2–8.4 GB. `ondemand` needs userfaultfd, which Flatcar's kernel lacks and Ubuntu restricts.
- **SUS-4 (Validated):** on bare KVM the guest's clock stays behind by the time it was down (7 s, 16 s and 25 s behind over three rounds). The guest has no RTC and the tested kernel has no `ptp_kvm`, so the host has to push the time over the channel after every resume, or the guest kernel has to gain a clock source it can step from. The one nested resume showed no skew.
- **SUS-5 (Validated):** the network works after a restore on the same tap, MAC and address, and the serial console still writes.
- **SUS-6 (Validated):** a restored VM maps the snapshot file. Do not overwrite or truncate a snapshot while a VM restored from it is running; write the next snapshot somewhere else.
- **SUS-7 (Open):** whether Stop suspends or powers off. Suspend is a natural fit for idle auto-stop, which isn't built yet.
- **SUS-8 (Proposed):** a box reboot does not preserve VMs. Environments come back by cold boot, as containers do today, unless the box suspends them first.

## Confinement and limits

- **LIM-1 (Validated):** the Cloud Hypervisor process ran as an unprivileged user with an empty capability set, `NoNewPrivs` and a seccomp filter on every thread (vCPUs, disk queues, vsock, balloon, API server).
- **LIM-2 (Validated):** `--landlock` with a rule for the VM's own directory. A snapshot to a directory outside the rules was refused. The setting is saved in the snapshot's config (`landlock_enable` and the rules), and a VM restored from it refused the same write. Cloud Hypervisor adds its own disk and kernel paths to the rules, so a disk elsewhere on the box still opens.
- **LIM-3 (Validated):** a cgroup per VM. A CPU quota of 150% gave 153% while the guest ran four busy vCPUs, and 100% gave 102%. A write cap of 40 MB/s gave 38.1 MiB/s, and a read cap of 2,000 IOPS held. Foreman leaves VM disk throughput unrestricted by default. An operator who needs a ceiling can set `IO_BANDWIDTH` (bytes per second, with systemd size suffixes) or `IO_IOPS` in the root-owned `/etc/foreman-agent/io.conf`. Each configured ceiling applies separately to reads and writes on the device backing VM storage. Use `IO_DEVICE` to specify a backing device explicitly.
- **LIM-4 (Validated):** memory. A guest filling 95% of its 8 GB peaked at 7.9 GB in its cgroup under an 8.6 GB limit and was not killed. A 3 GB limit on a guest touching 6 GB got the VM killed by the kernel, which protects the box and loses the environment.
- **LIM-5 (Proposed):** the memory limit is the guest's RAM plus an allowance for Cloud Hypervisor itself. The allowance needs measuring under I/O load; start at 512 MB.
- **LIM-6 (Validated):** CPU, memory and pids limits work from the agent's own user manager with no root. I/O limits need a system scope, which is one reason for ARC-5.
- **LIM-7 (Validated):** density. Eight VMs of 2 vCPU and 4 GB, each running the environment, on four host threads: all ready in 6.8–7.6 s, about 780 MB each, and 3.6% of one core between them when idle.
- **LIM-8 (Open):** Cloud Hypervisor uses core scheduling to keep two VMs' vCPUs off sibling hyperthreads where the kernel has it. Flatcar's kernel does not (`CONFIG_SCHED_CORE` unset). Decide whether that matters for Flatcar boxes.
- **LIM-9 (Proposed):** one uid per VM would keep a compromised VMM away from other VMs' disks. The tests ran every VM as one user with Landlock doing that job.

## Security model

### What changes

| Today | With VMs |
|---|---|
| Environments share the box's kernel (gap 13). A container escape lands on the box. | An escape lands in the guest. Reaching the box means breaking Cloud Hypervisor's device emulation, under seccomp, Landlock and an unprivileged user. |
| The agent is in the `docker` group, which is root on the box (gap 1). | The host agent needs no Docker access. Its root actions are the helper's fixed vocabulary. |
| Anyone with Docker access on a box reads every environment's secrets. | Secrets live in each guest. The box has no directory of them. |
| The compose policy refuses anything that would be root on the box. | Those rules protected the box from containers. Inside a VM they protect nothing. |
| Privileged containers and docker-in-docker are refused. | Allowed (DEC-8). Both ran in a guest in the first spike. |
| No default resource limits (gap 14). | Every VM has a size and a cgroup. |
| Symlink races between the agent and the workspace (gap 4). | The racing code and the checking code are both in the guest. The host agent never reads the workspace. |

- **SEM-1 (Open):** the future of `ForemanAgent.Env.Policy` (1,136 lines). The rules that exist because containers share the box (privileged, host namespaces, the Docker socket, host binds, devices, external networks, unreviewed compose keys, `provider` services) can go. Go through them one by one; a few may still protect the guest agent's own files from the repo.
- **SEM-2 (Open):** `initializeCommand` is dropped today because it would run on the box. In a guest it would run in the guest.
- **SEM-3 (Proposed):** `FOREMAN_POLICY` and the red alert for a box that loosened a rule go away with the rules.
- **SEM-4 (Proposed):** the repo conventions lose "no privileged containers" and "remove docker-in-docker".

### What does not change

- A compromised control plane can still run repo code on every box (gap 5), now inside VMs.
- Tokens in an environment are usable by anything in it (gap 12).
- An environment has unfiltered internet access. The host firewall blocks link-local metadata independently of the LAN setting.
- Tailscale's userspace mode still hands tailnet connections to localhost listeners in the environment.

### New things to defend

- **SEM-5:** the guest agent's messages (CHA-5).
- **SEM-6:** snapshot files on disk holding secrets (SEC-3).
- **SEM-7:** the VM helper's vocabulary (ARC-5).
- **SEM-8:** Cloud Hypervisor's device emulation. Nothing here tested it; the defence is upstream's work plus LIM-1 and LIM-2. Keep the pinned version current.
- **SEM-9:** resource exhaustion on the box that cgroups don't cover, conntrack entries from a guest's traffic for one.

## Reporting

- **REP-1 (Proposed):** per-environment CPU and memory come from the VM's cgroup on the box, which the guest cannot falsify. "Provisioned" becomes the VM's size.
- **REP-2 (Proposed):** listening ports are read inside the guest and reported by the guest agent. Today the agent reads them from `/proc/<pid>/net/tcp` on the box. They are display-only and untrusted.
- **REP-3 (Proposed):** the Tailscale node id already comes from inside the repo's container and is already checked against the tag and hostname before a delete. That stays.
- **REP-4 (Proposed):** host metrics (`box.metrics`) and the reboot flag are unchanged.

## Operations

- **OPS-1 (Proposed):** an agent update must not stop VMs (ARC-4).
- **OPS-2 (Proposed):** guest updates. With the split in ARC-11 a new guest version applies on an environment's next boot. With a single disk it needs a rebuild.
- **OPS-3 (Proposed):** the box page shows a suspended state, the VM's size, and the tier (BOX-3).
- **OPS-4 (Validated):** Flatcar specifics. Stable 4757.2.3 (kernel 6.12) has `/dev/kvm` (group `kvm`), nested VMX, tun, vhost-net, vhost-vsock, the XFS module, `mkfs.xfs`, Landlock, block throttling, `ncat`, `socat` and `jq`. It has no `setpriv`, no Python, no userfaultfd and no core scheduling.

## Install

- **INS-1 (Proposed):** `install.sh` on Debian or Ubuntu: check `/dev/kvm`, add the agent user to `kvm`, set up `/srv/foreman` on XFS (STO-4), install the helper and the new firewall table, and stop requiring Docker.
- **INS-2 (Proposed):** a box that also runs Docker gets the `DOCKER-USER` rules (NET-12).
- **INS-3 (Proposed):** Flatcar: the same through the Ignition config, with the binaries under a writable path since `/usr` is read-only. Details in [#179](https://github.com/ntodd/foreman/issues/179).
- **INS-4 (Proposed):** `vm.sh` and the Proxmox instructions must expose nested virtualization and say what it costs (BOX-2).

## Migration

- **MIG-1 (Decided):** the release that ships VM environments removes shared Docker and Mac boxes.
- **MIG-2 (Proposed):** existing environments are not converted. Their named volumes live in the box's Docker, so people push their work and recreate. The upgrade notes say so, and tell Mac box owners to move their environments to a Linux box first.
- **MIG-3 (Proposed):** take Mac out of "Add a box" and stop serving `mac.sh` in that release ([#180](https://github.com/ntodd/foreman/issues/180) lists this).
- **MIG-4 (Proposed):** boxes without KVM cannot run environments after the upgrade. The control plane says so on the box's page before the upgrade, from BOX-3's report if an agent release can carry it first.

## Validation results

All on 2026-11-16, on one shared box: Intel i7-12700, 62 GB RAM, NVMe on ext4, Ubuntu with kernel 7.0, Cloud Hypervisor v54.1. Guests were 4 vCPU and 8 GB pinned to four P-core threads unless noted. The box was running other people's environments at the time, so treat spreads as noise from that. Nothing on the box was changed permanently: each run was torn down and the box's interfaces, firewall tables and images compared with a snapshot taken before.

Two tiers:

- **Bare KVM:** Cloud Hypervisor as an unprivileged user on the box's own KVM. In the validation run these VMs had no NIC and were driven over vsock. The first end-to-end spike used one tap with real NAT.
- **Nested:** inside a throwaway Flatcar 4757.2.3 VM started the way `vm.sh` starts one (QEMU, `-cpu host`, 8 vCPU, 20 GB), with taps, nftables and an XFS volume inside it.

### Compute and I/O (first spike)

| | Clean `mix compile` | 4K random read / write IOPS |
|---|---|---|
| Docker on the host | 35.5–35.8 s | 1,201k / 440k |
| Cloud Hypervisor on bare KVM | 34.4–35.7 s | 487k / 460k |
| Docker in a Flatcar VM | 35.2–35.7 s | 387k / 382k |
| Cloud Hypervisor nested in the Flatcar VM | 37–57 s over nine runs, median about 44 | about 155k / 155k |

### Start-up

| | Bare KVM | Nested |
|---|---|---|
| Launch to Docker ready | 1.28–1.44 s | 1.61–1.80 s |
| Launch to sshd answering | 1.0–1.2 s | not measured |
| Cold `devcontainer up`, pulling images | about 24 s | not measured |
| `devcontainer up` on a running environment | 0.4–0.6 s | not measured |
| `devcontainer up` on a stopped, prebuilt environment | about 1.2 s, with no network | 1.4–1.8 s |
| Disk prebuild to exec in the app container, full copy | 4.4–5.5 s | 10.7–11.0 s |
| Disk prebuild to exec in the app container, reflink | not measured, about 2.7 s expected | 3.5–4.1 s |
| Reflink clone | not measured | 0.00–0.01 s |

### Memory snapshots

| | Bare KVM | Nested |
|---|---|---|
| Pause | 0.01 s | not measured |
| Pause and snapshot | 2.2–3.4 s (8 GB guest) | 1.6 s (3 GB guest) |
| Snapshot size | 8,193 MB | 3,073 MB |
| Restore `copyonwrite` to first guest activity | 0.13 s | 0.32 s |
| Restore `copyonwrite` to exec in the app container | 0.23–0.36 s over vsock | 2.1 s over SSH on the tap |
| Memory after restore `copyonwrite` | 264–391 MB | 279 MB |
| Restore `copy` | 2.3–6.4 s, 8.2–8.4 GB | not measured |
| Restore `ondemand` | fails without privilege | fails, no userfaultfd |
| Clones from one snapshot | 4 usable at 0.43, 0.81, 1.37 and 1.75 s; 506 MB RSS and 163–167 MB PSS each | 2 usable at 3.9 and 5.4 s; 188–222 MB PSS |

### Reflink write cost (nested, XFS)

| | Full copy | Reflink clone |
|---|---|---|
| 4K random overwrite of prebuilt data, first time | 150k IOPS | 10.5k IOPS |
| Same, after the data was rewritten once | | 113–137k IOPS |
| Copy 1.2 GB in 17,710 files, then sync | 3.6 s | 2.9 s |
| 1M sequential write to a new file | 1,926 MiB/s | 1,800 MiB/s |
| 8K write with an fsync each | 100 IOPS | 73 IOPS |
| Reflink clone with `direct=off` | | 47k IOPS first overwrite, 6.2 s file copy |
| Reflink clone with `cowextsize 1m` | | 9.6k IOPS first overwrite |

In an earlier pass, random writes to a file the guest had only just created (blocks the host file had never allocated) ran at 13–27k IOPS. Sequential first writes are unaffected.

### Density and limits

| | Result |
|---|---|
| 8 VMs (2 vCPU, 4 GB) on 4 host threads, bare KVM | all environments ready in 6.8–7.6 s |
| Memory per idle environment | 756–793 MB, 6.2 GB for eight |
| CPU for eight idle environments | 3.6% of one core |
| 4 VMs (2 vCPU, 3 GB), nested, with networking | ready in 6.0–6.7 s, 677–703 MB each |
| Power off eight | 1.9 s |
| `CPUQuota=150%`, guest burning 4 vCPUs | 153% |
| `CPUQuota=100%`, nested | 102% |
| `MemoryMax=8600M`, guest filling 95% of 8 GB | survived, peak 7,876 MB, 693 MB 20 s after the guest freed it |
| `MemoryMax=3G`, guest touching 6 GB | VM killed by the kernel |
| `IOWriteBandwidthMax` 40 MB/s | 38.1 MiB/s |
| `IOReadIOPSMax` 2,000 | held |
| Free page reporting, guest frees 3 GB | back on the host within 20 s |
| Discard, guest deletes 3 GB and trims | host file back to its earlier size |

### Isolation probes (nested, from inside a guest as root)

| Probe | Shipped table only | With the prototype table |
|---|---|---|
| Box sshd on the tap's gateway address | reached | dropped |
| Box sshd on the box's other address | reached | dropped |
| Neighbouring guest's sshd | reached | dropped |
| Neighbour's gateway address | reached | dropped |
| Neighbour's published container port | not run | dropped |
| Tailnet address | rejected (first spike, on the box's live firewall) | rejected |
| LAN address, with the LAN option on | not run | rejected |
| Ping the box | not run | dropped |
| Neighbour's address as source | not run | dropped |
| Public address as source | not run | dropped |
| Privileged container on the guest's host network, to the box | not run | dropped |
| Bridged container to the neighbour | not run | dropped |
| Port scan of the box, top 30 TCP ports | not run | all filtered |
| vsock to a host port with no listener | not a firewall matter | refused |
| vsock to another guest's CID | not a firewall matter | no route |
| Internet over HTTPS, from the guest and from a container | needs the NAT rule | works |
| Box to a container port published in a guest | not run | works |

From the first spike, on bare KVM: `docker run --privileged` and docker-in-docker (`docker:28-dind`) both ran in a guest, and vsock carried data in both directions.

### Nested in a Proxmox-style VM (production box)

The production box (Threadripper 9980X, 64 cores with SMT, 125 GB, Debian 13 on bare KVM with `kvm_amd nested=1`) with Foreman inside a VM set up the way Proxmox VE sets one up, without Proxmox itself:

- **The VM:** QEMU 10.0 with machine `q35` and SeaBIOS, 32 vCPUs, 64 GB, and CPU type `host`.
- **Disk:** virtio-blk with an iothread on a raw file, `cache=none,aio=io_uring,discard=on`.
- **Rest of the hardware:** virtio-net with vhost (NAT, not a bridge), a balloon with free page reporting, a VGA device.
- **Software:** the guest OS is Debian 13 genericcloud, running the agent and guest image built from this design's implementation.

The full VM end-to-end run passed inside it: install, isolation probes, stop and start, suspend and resume, an agent restart, prebuilds and destroy.

| | Bare KVM | Nested in the Proxmox-style VM |
|---|---|---|
| Guest boot to Docker ready | 0.90–1.21 s | 1.26–1.32 s |
| Launch to the guest agent's hello | 1.44–1.50 s | 1.96–2.05 s |
| Cold create (clone, pulls, `devcontainer up`) | 24–30 s | 38.6–40.8 s (about 18 s of it the 950 MB base image pull, as slow in the VM itself) |
| Start after a power-off | 3.44–3.62 s to running | 4.87–5.02 s |
| New environment from a prebuild (ext4 copy) | 6.0–6.4 s | 9.44–9.90 s |
| Resume to the guest agent's hello | 0.10–0.11 s | 0.15–0.21 s |
| Resume to the environment up | 0.64–0.72 s | 2.38–3.16 s (secrets and the guest's `devcontainer up`, slowed like any fork-heavy work) |
| 8 GB snapshot | 3.35 s | 2.8–5.5 s |
| stress-ng `matrixprod`, environment against host | within 1.3% | 4–9% slower |
| Kernel build at -j16, environment against the VM it runs in | 3% faster | 15% slower (page-fault-heavy work runs at about half speed) |
| fio 4K random read / write, IOPS in an environment | 542–582k / 589–594k | 262–269k / 173–223k once allocated (the VM's own disk caps at about 560k) |
| fio 1M sequential write | 9–11 GiB/s | 8.5–9.2 GiB/s |
| Network, environment to the LAN / LAN to environment | 4.1 / 14 Gbit/s | 2.7 / 11 Gbit/s |
| 16 environments (2 vCPU / 4 GB) from a prebuild at once | 8.1 s, 32 in 9.5 s | 17.2 s |
| Memory per idle environment | 928–960 MB | 934–970 MB |
| Idle CPU per environment, on the host | about 0.5% of a thread | about 3.4% of a thread |

- **NEST-1 (Validated):** nested on this box is the slow tier BOX-2 describes, and usable for a team's interactive environments. Lifecycle operations take 1.4–4× as long, CPU-bound work loses 5–15%, random I/O and fork- or page-fault-heavy work about half, and an idle environment costs the host about seven times the CPU. Memory per environment is the same.
- **NEST-2 (Validated):** most of the cost is exits. Each I/O in an environment caused about 2.25 exits on the host against 0.06 for the same I/O in the VM, through two virtio layers. The host's TLB flushes ran at about twice the nested switches, which fits the CPU-bound and fault-heavy loss.
- **NEST-3 (Validated):** what the Proxmox VM needs:
  - CPU type `host`, and `kvm_amd nested=1` (or `kvm_intel nested=1`) on the Proxmox host.
  - VirtIO disks with an iothread, `cache=none` and `aio=io_uring`, on raw storage. One iothread is the first I/O cap; a second disk for `/srv/foreman` with its own iothread, or NVMe passthrough, wasn't measured.
  - Ballooning with free page reporting on: memory a guest freed went back through both levels within about 20 s.
  - A VGA device (Proxmox's default). Without one, the Debian 13 cloud image looped in GRUB under SeaBIOS; check boots if a VM uses `vga: serial0`.
  - Host memory for the VM's full size. The VM's page cache, which copying prebuild and root disks fills, keeps host memory that free page reporting can't return: after 16 creates the VM used 18.9 GB and QEMU held 58.6 GB.
  - Hugepages and NUMA settings aren't needed on this box: host THP already backs the VM with 2 MB pages, and it has one NUMA node.
- **NEST-4 (Validated):** the kernel that runs Cloud Hypervisor decides core scheduling, the VM's when nested. Neither Debian kernel on this box has it (the box's, or the cloud kernel in the VM), so Cloud Hypervisor warns there's no SMT isolation: with SMT on, two environments' vCPUs can share a core, as on Flatcar.

## Not validated

1. **arm64.** No hardware. Cloud Hypervisor supports it.
2. **A real tailnet join from a guest.** Reachability only (NET-17).
3. **Reflink on bare KVM, and btrfs.** Reflink was measured nested.
4. **Flatcar on metal** ([#179](https://github.com/ntodd/foreman/issues/179)).
5. **The agent under load.** The host agent, the helper and the guest agent are built and run end to end (`e2e/vm/run.sh`) nested on a CI runner and in a throwaway VM, with the isolation probes, suspend and resume, and prebuilds. Not yet on a busy bare-metal box for days.
6. ~~The split system and data disks~~ (ARC-11): built, and run end to end.
7. **Attacks on Cloud Hypervisor's device emulation.**
8. **Network throughput** (NET-7), and DNS through the box (NET-6).
9. **Long runs.** Nothing ran for more than a few minutes. No soak test, no more than eight VMs, no memory pressure across VMs.
10. **Resizing a disk or a running VM.**
11. **A real repository.** The environment was the agent's `hello` fixture: an app container on `mcr.microsoft.com/devcontainers/base:debian` with an Alpine sidecar.
12. **Per-VM uids** (LIM-9), and the allowance in LIM-5.
13. **Guest memory under the host's page cache pressure** after a copy-on-write restore, where the snapshot's pages are page cache.

### Found while building it

- **Forwarding and LRO.** Turning IPv4 forwarding on at runtime turns LRO off on every NIC, and on the production box's Aquantia NIC (atlantic) that resets the link: the box dropped off the network for a few seconds. The install script writes `/etc/sysctl.d/90-foreman.conf`, so forwarding is on from boot and the firewall unit's own setting changes nothing. A box sees the reset once, at install.
- **MagicDNS as a guest's resolver.** On a box on the tailnet, systemd-resolved lists `100.100.100.100`, which guests can't reach (the firewall rejects `100.64.0.0/10`). The helper leaves tailnet resolvers out (NET-6).
- **Landlock and taps.** See [Appendix B](#appendix-b-cloud-hypervisor-invocations): the rules need the tap's sysfs directory and `/dev/net/tun`.
- **The guest agent's user.** As root in the guest, the devcontainer CLI gave the container's user root's uid, so the 0600 secrets and the clone weren't theirs. The guest agent runs as an unprivileged user with `CAP_SYS_TIME` alone, for putting the clock right.
- **Connected isn't ready.** The guest's vsock listener accepts before its agent is up, so the box waits for the guest agent's hello before it sends anything.
- **A resume reruns nothing.** `postStartCommand` doesn't run again after a resume (the containers never stopped), so checks that need to see a resume read a running container's output instead.
- **Production box** (Threadripper 9980X, 64 cores with SMT, 125 GB, Debian 13 on bare KVM, ext4 on NVMe), with this implementation's agent, guest image and vmctl:
  - Boot to Docker ready 0.90–1.21 s; to the guest agent's hello 1.44–1.50 s with a NIC. A cold create (clone, pulls, `devcontainer up`) 24–30 s.
  - `env.start` after a power-off 1.98–2.11 s (4.83–5.64 s before the compose policy went); launch to running 3.44–3.62 s. About 0.7 s of that is the devcontainer CLI resolving the Foreman feature's dependencies from ghcr.io on every start, so environments still need the network to start.
  - A new environment from a prebuild on ext4 (a full copy of a 1.52 GB disk, 0.33–0.48 s) was up 6.0–6.4 s after the copy started; with reflinks on a loop XFS 6.9–7.2 s. A reflinked disk's first random writes to shared blocks ran at 2.7–5.3k IOPS (p99 about 300 ms) against 400k on a full copy on the same filesystem, and 96–98k even after every block was rewritten. ext4 is the default to recommend (STO-5 understated the cost; measure on a real XFS volume before choosing it).
  - Resume (copy-on-write) to the guest agent's hello 0.10–0.11 s, to the environment up 0.64–0.72 s, 516–648 MB resident after. The guest clock is behind by the time since the snapshot until the agent steps it at hello (then within 10 ms). An 8 GB snapshot takes 3.35 s and 8,193 MB of disk.
  - Guests run at host speed: stress-ng within 1.3% at 4 and 16 vCPUs, and a kernel build at -j16 in 107.8 s against 111.1 s on the host.
  - fio in a guest's data disk: 542–582k random-read and 589–594k random-write IOPS at 4K, about 9–11 GiB/s sequential write.
  - Network: guest to the LAN through NAT 4.1 Gbit/s (CH's defaults: one queue pair, no offloads), LAN to guest 14 Gbit/s.
  - Density: 32 environments (2 vCPU / 4 GB) started at once from a prebuild were all up in 9.5 s, at 928–960 MB each (30.2 GB in all), idling at 16% of one thread together. Memory bounds density (about 100 idle environments here), not CPU. Free page reporting gave back 4 GB a guest freed within about 15 s.
  - Not good for hostile tenants as it stands: the CPU reports Transient Scheduler Attacks unmitigated (no microcode from Debian yet), and SMT is on without core scheduling.

## Open questions

Decisions for Nate:

| Id | Question | Recommendation |
|---|---|---|
| DEC-9, NET-14 | Can guests reach the box's LAN? | Yes by default, with a per-box block |
| DEC-10, STO-4 | Does the installer require XFS? | Require or create it, with full copy on ext4 as a fallback |
| DEC-11, BOX-4 | arm64 Linux boxes | amd64 only until tested |
| SUS-7 | Does Stop suspend or power off? | Power off at first; suspend for idle auto-stop later |
| LIM-8 | Does the lack of core scheduling on Flatcar matter? | Note it in the Flatcar docs |

Design work:

| Id | Question |
|---|---|
| CHA-7 | The guest agent protocol |
| ARC-8 | The shape of the root helper |
| ARC-11 | One disk or a system disk plus a data disk |
| STO-10 | Whether btrfs is supported as well as XFS |
| SEM-1, SEM-2 | Which policy rules survive, and `initializeCommand` |
| LIF-4 | Published ports in the overlay |
| NET-4, NET-6, NET-18 | The address pool, DNS, and how a guest learns its address |
| VM-7, VM-8 | Default VM sizes, and resizing |
| PRE-3 to PRE-6 | Prebuild keys, hooks, credentials and placement |
| ARC-12, SUS-4 | The guest's clock source |
| MIG-4 | Warning boxes without KVM before the upgrade |

## Suggested build order

1. The guest image and guest agent: the existing environment code behind a vsock relay, tested on one VM started by hand.
2. The host side: disks, the helper, taps, the firewall table and the VM unit. An environment created from the control plane, cold.
3. Remove shared Docker and the compose policy, turn privileged and docker-in-docker on, drop Mac boxes, write the upgrade notes.
4. Reporting from cgroups, limits as VM sizes.
5. Disk prebuilds.
6. Suspend and resume, then idle auto-stop.
7. Flatcar on metal ([#179](https://github.com/ntodd/foreman/issues/179)).
8. Memory-snapshot clones, if stage 1 isn't fast enough.
9. Mac boxes ([#180](https://github.com/ntodd/foreman/issues/180)).

Tests to add along the way: the probe matrix above as an `e2e/` suite against a real box, protocol contract tests for the guest channel, and a fake guest agent for the host agent's unit tests, as the Docker and Runner fakes are used today.

## Appendix A: firewall prototype

Loaded next to the shipped `foreman.nft`. The `lan` chain is the per-box option in NET-14 and was on for the tests. This is the prototype as tested. The implementation names the table `foreman_guests` (install.sh already has a `foreman_vm` table for a Flatcar VM's gateway) and replaces the `guests` set with a routing check (NET-10 in [Implementation decisions](#implementation-decisions)).

```nft
table inet foreman_vm {
	# tap . the one address its guest may use
	set guests {
		type ifname . ipv4_addr
	}

	chain from_guest_to_box {
		ct state established,related accept
		counter drop
	}

	chain from_guest {
		iifname . ip saddr != @guests counter drop
		meta nfproto ipv6 counter drop
		oifname "fm-*" counter drop
	}

	chain lan {
		ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } counter reject with icmpx type admin-prohibited
	}

	chain input {
		type filter hook input priority filter - 9; policy accept;
		iifname "fm-*" jump from_guest_to_box
	}

	chain forward {
		type filter hook forward priority filter - 9; policy accept;
		iifname "fm-*" jump from_guest
		iifname "fm-*" jump lan
		oifname "fm-*" ct state established,related accept
		oifname "fm-*" counter drop
	}

	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;
		iifname "fm-*" oifname != "fm-*" masquerade
	}
}
```

Per VM:

```sh
ip tuntap add dev fm-<id> mode tap user <agent user>
ip addr replace 10.250.<n>.1/30 dev fm-<id>
ip link set fm-<id> up
sysctl -w net.ipv6.conf.fm-<id>.disable_ipv6=1
nft add element inet foreman_vm guests '{ "fm-<id>" . 10.250.<n>.2 }'
```

On a box that runs Docker (first spike):

```sh
iptables -I DOCKER-USER -i fm-<id> -j ACCEPT
iptables -I DOCKER-USER -o fm-<id> -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```

The wildcard `fm-*` also matches Docker bridges named `fm-…` on a box that still has shared-Docker environments, which matters only during a migration.

## Appendix B: Cloud Hypervisor invocations

Boot, as an unprivileged user in the `kvm` group:

```sh
cloud-hypervisor \
  --kernel vmlinuz \
  --cmdline "console=ttyS0 root=/dev/vda rw quiet" \
  --disk path=data.raw,image_type=raw,direct=on,num_queues=4 \
  --cpus boot=4 --memory size=8G \
  --balloon size=0,free_page_reporting=on,deflate_on_oom=on \
  --net tap=fm-<id>,mac=52:54:00:fa:00:<n> \
  --vsock cid=3,socket=vsock.sock \
  --serial file=serial.log --console off \
  --api-socket api.sock \
  --landlock --landlock-rules path=<vm dir>,access=rw
```

- Passing no `ip`, `mask` or `mtu` to `--net` is what lets it use a tap it doesn't own the configuration of, with no `CAP_NET_ADMIN`.
- With `--landlock` and a tap, the rules need `/dev/net/tun` (read and write) and the tap's sysfs directory, `/sys/devices/virtual/net/<tap>` (read): Cloud Hypervisor adds the disks and kernel to its rules itself, but not those, and fails with "Failed to read the TAP flags from sysfs". Found in the first run with networking; the spikes' Landlock test had no NIC.
- Suspend: `ch-remote --api-socket api.sock pause`, then `snapshot file://<dir>`, then `shutdown-vmm`.
- Resume: `cloud-hypervisor --api-socket api.sock --restore source_url=file://<dir>,memory_restore_mode=copyonwrite,resume=true`. Passing `--landlock` together with `--restore` failed in the test with a request for a kernel. It isn't needed: the saved config carries the Landlock settings.
- A snapshot is `config.json`, `state.json` and `memory-ranges`.
- Graceful stop: power off from inside the guest, and Cloud Hypervisor exits.

## Appendix C: cloning a VM from a memory snapshot

1. Bring the source environment up, before secrets and the Tailscale join.
2. `pause`, `snapshot`, and clone the disk while still paused.
3. For each clone, make a snapshot directory with a hard link to `memory-ranges`, a copy of `state.json`, and a `config.json` with four fields changed: `disks[0].path`, `net[0].tap`, `vsock.socket` and `serial.file`.
4. Create the clone's tap and firewall entry.
5. Restore with `memory_restore_mode=copyonwrite,resume=true`.
6. Over vsock: replace the guest's address and default route, set the hostname, step the clock, and re-key (machine-id, SSH host keys, RNG).
7. Deliver secrets and let Tailscale join as a new node.

Until step 6 the clone sends from the source's address, which the firewall's guest set drops.

## Appendix D: rejected options

| Option | Why |
|---|---|
| Firecracker | Too serverless-oriented for long-lived development machines |
| qcow2 overlays for clones | 17 to 38 times slower random I/O than raw in the test, and an open corruption issue upstream |
| virtio-fs for the workspace | Needs shared guest memory, which turns copy-on-write restore into a full copy |
| `memory_restore_mode=ondemand` | Needs userfaultfd: missing on Flatcar, privileged on Ubuntu |
| Environment VMs nested in a Flatcar VM on a Mac | Nested virtualization on Apple's hypervisor is poor; [#180](https://github.com/ntodd/foreman/issues/180) uses the hypervisor directly |
| Keeping shared Docker as a fallback | Two isolation models to maintain, and the weaker one is the one being removed |
| Sysbox, Podman, Kata, rootless Docker | See "Docker inside an environment" in [architecture.md](../architecture.md#docker-inside-an-environment) |
