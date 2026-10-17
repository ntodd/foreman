# VM per environment: evaluation

Status: prototype on `feature/vm-isolation`, 2026-10-17. Not merged.

A box with `FOREMAN_ISOLATION=vm` runs each environment in its own Incus
VM, with its own kernel and Docker, instead of as containers on the box's
Docker. This page is what the prototype does, what it costs, and what it
buys, measured against the same environments as plain devcontainers.

## Verdict

It works, and it closes the gaps it was meant to close: a container
escape lands in a VM holding one environment, and docker-in-docker (which
several repos use and Foreman refuses today) runs safely. It is not a
drop-in replacement yet. On the test box it costs:

- **Memory.** An idle environment holds about 4.7 GB of the box's memory
  instead of about 70 MB, because the VM keeps its page cache. Free page
  reporting plus a cache drop gets that to about 1.9 GB; it never gets
  near the container figure.
- **Creating environments.** A second environment of a repo takes about
  110 s instead of 6 s, because VMs don't share an image cache. A cold
  create takes 2.5x as long.
- **Starting.** 23 s instead of 3 s: the VM boots. Stopping shuts the VM
  down, which is what gives its memory back.
- **Compile and test speed.** 30% slower for an Elixir compile and the
  test suite, 3x for `npm ci`, and a quarter of the fsync rate. These are
  nested-virtualization numbers from a Mac, the worst case; a bare-metal
  Linux box should land much closer to containers (see
  [What the numbers mean](#what-the-numbers-mean)).

Make it a per-box option for environments that run untrusted code (coding
agents on public input) or need Docker inside, not the default. Before it
could be the default it needs per-repo prebuilt VM images and memory
reclaim, and numbers from a bare-metal box.

## What was built

- **Agent** (`apps/foreman_agent`): `ForemanAgent.Env.Vm` manages one VM
  per environment through the `incus` CLI (`ForemanAgent.Vm.Incus`). The
  agent copies its own release into the VM and runs each operation there
  once as `ForemanAgent.Guest`, which calls the same `ForemanAgent.Env`
  code a container box runs. The host hands the operation over as a
  validated command file and reads logs and the result back
  (`ForemanAgent.Guest.Wire`); it never reads the clone. Inventory comes
  from the VMs (stopped VMs are `stopped`, unreachable ones `partial`,
  never `missing`), usage from Incus. incusd owns the VMs, so they survive
  agent restarts and self-updates the way containers do.
- **Image** (`apps/foreman_agent/priv/vm`): Docker Engine with Compose and
  Buildx, git, Node and the devcontainer CLI, and a `foreman` user, built
  once per box with `build-image.sh`.
- **Protocol 3**: the join payload carries the box's isolation. The
  control plane records it, always sends a VM box a size (environment
  limits, then the repo's, then `hostRequirements`, then a default),
  counts VM environments at their VM's size, shows VM boxes with a badge
  and a note on what a VM doesn't keep in, gives a connect command
  through `incus exec`, and won't recreate or act on environments after a
  box changes isolation.
- **Policy**: inside a VM everything is allowed by default
  (`FOREMAN_VM_POLICY` tightens it), and that's what the box reports.

## Testbed

| | |
|---|---|
| Host | Apple M5 Max, 18 cores, 128 GB, macOS 27 |
| Box | Lima VM (Apple Virtualization, nested virtualization on), Ubuntu 24.04 arm64, 14 vCPU, 64 GB, Docker 29.9, Incus 7.5.1 (Zabbly) |
| Environment | 4 CPUs and 8 GB in both modes: container limits on the devcontainer service, or a 4 vCPU / 8 GB VM |
| Fixture | `e2e/vmbench`: an Elixir/Phoenix + Postgres devcontainer like the repos Foreman runs (app sharing the database's network, Node from a feature), with Foreman's own control plane, Redis and a Vite/React/TypeScript project as workloads |
| Method | The real flow: a control plane and two agents from the same release, environments created through the control plane, workloads run in the app container. 3 repetitions, medians. Two full rounds; the container numbers matched to within 3%. |

The box is itself a VM, so container environments run at one level of
virtualization (L1) and VM environments at two (L2). That makes this a
worst case. Exits (I/O, timers, IPIs, page faults on fresh memory) cost
an order of magnitude more nested than in a single-level VM, while pure
computation runs at full speed in both.

## Results

Round 2, nothing else running. "Change" is the VM against the container.

### Developer workloads

| | Container | VM | Change |
|---|---|---|---|
| Elixir: clean compile (deps + app) | 19.1 s | 25.3 s | 33% slower |
| Elixir: recompile after touching a core module | 0.51 s | 1.16 s | 2.3x |
| `mix test` against the Postgres sidecar (282 tests) | 7.8 s | 10.4 s | 33% slower |
| Redis `make -j4` | 10.8 s | 9.4 s | 13% faster |
| `npm ci` from a warm cache | 2.1 s | 6.6 s | 3.2x |
| `tsc` (300 components) | 4.4 s | 5.9 s | 35% slower |
| `vite build` | 1.0 s | 1.7 s | 67% slower |
| `git add` + commit, 4,200 files | 0.32 s | 0.37 s | 16% slower |
| `git status`, 20 times | 0.10 s | 0.10 s | same |

Redis builds faster in the VM, probably because the container's 4-CPU
limit is a CFS quota (throttled in 100 ms slices) and the VM's 4 vCPUs
are not.

### The parts underneath

| | Container | VM | Change |
|---|---|---|---|
| Syscall | 127 ns | 134 ns | 5% |
| fork + exec | 183 µs | 222 µs | 22% slower |
| Page fault on fresh memory | 393 ns | 1,611 ns | 4.1x (1.2x without free page reporting) |
| Pipe round trip between two processes | 37 µs | 75 µs | 2x |
| sysbench CPU, 1 and 4 threads | | | 6–7% slower |
| Memory bandwidth | 50.7 GB/s | 47.6 GB/s | 6% slower |
| Random 4k read, QD32 | 162k IOPS | 77k IOPS | 0.48x |
| Random 4k write, QD32 | 154k IOPS | 58k IOPS | 0.38x |
| Sequential write | 17.0 GB/s | 8.3 GB/s | 0.49x |
| 4k write + fdatasync | 3,090/s | 721/s | 0.23x |

Root disk bus made no difference (virtio-scsi and virtio-blk within 2%;
emulated NVMe was ten times worse).

### Lifecycle

| | Container | VM | Change |
|---|---|---|---|
| Create, cold box (images pulled and built) | 43 s | 111 s | 2.6x |
| Create, second environment of the same repo | 5.9 s | 108 s | 18x |
| Stop | 10.2 s | 11.9 s | 17% slower |
| Start | 3.0 s | 22.9 s | 7.6x |
| Restart all | 13.0 s | 16.6 s | 28% slower |

Of a VM create: 7 s to copy the image (Incus `dir` storage), 28 s to boot
(nested), a few seconds to copy the agent in, then the same build as a
container box, slower, with nothing cached.

### Memory and disk

| | Container | VM |
|---|---|---|
| Environment, idle after warm-up | 71 MB | 4,723 MB |
| Environment, after the workloads | 97 MB | 5,449 MB |
| VM after dropping guest caches and compacting | | 1,875 MB |
| Disk per environment (this repo) | shared images | 4.5 GB: its own images (1.8 GB) and build cache (1.4 GB) |

Container memory is what the containers use. VM memory is the VM's
resident size on the box: guest kernel, Docker, and a page cache the
guest keeps because it has no reason to give it back. Free page reporting
(on in round 2) returns memory processes free (6.7 GB down to 5.4 GB after
the workloads) at the cost of slower faults on fresh memory.

## Capabilities

`e2e/vmbench/capabilities.sh` (17 of 17 pass), `netcheck.sh` and
`reboot.sh`, through the control plane:

| | Container box | VM box |
|---|---|---|
| docker-in-docker feature, `docker run`, `docker build` | refused (privileged) | works |
| Privileged container visible to the box's Docker | | no, it's inside the VM |
| A new secret reaches a running environment | yes | yes |
| Restart affected | yes | yes |
| Environments survive an agent restart | yes | yes |
| Stop gives the memory back | partly (processes stop) | yes (VM shuts down) |
| Secrets come back after stop and start | yes | yes (from the host's copy) |
| Destroy removes everything | yes | yes |
| Reach another environment on the box | no | no (NIC port isolation; with it off, the same probe connects) |
| Reach box services bound to 0.0.0.0 (sshd, a git server) | yes | yes |
| Reach the control plane bound to loopback | no | no |
| Reach the internet | yes | yes |

### Tailscale

A private tailnet (headscale) with a "laptop" node on the box, and the
feature's own userspace Tailscale in an environment of each kind:

| | Container | VM |
|---|---|---|
| Join, MagicDNS names, Tailscale SSH as vscode and root (lands in the app container), ports by name, outbound through the proxy | works | works |
| Rejoins after `docker restart` without a key | yes | yes (once of five, the laptop took ~3 min to pick up the new disco key; looks like a client race, not the VM) |
| Path | direct | direct (after 3 DERP pings, cold) |
| Round trip over the tailnet | 1.4 ms | 2.1 ms |
| `ssh … true` | 20 ms | 20 ms |
| iperf3 laptop → env | 5.6 Gbit/s | 2.6 Gbit/s |
| iperf3 env → laptop | 6.5 Gbit/s | 0.5 Gbit/s (1.0 with the VM's NIC on one queue) |
| Over DERP | same | same |

SSH and editors feel the same. Bulk transfers out of a VM environment
are slower here, mostly from the testbed: tailscaled in userspace mode
across four NAT layers, nested, with packet reordering from the VM NIC's
multiple queues.

### Box reboot

`reboot.sh`, one environment of each kind running with a secret set,
then the box restarted:

| | Container | VM |
|---|---|---|
| Running again after boot | 13 s | 30 s |
| `env.start` | 2.9 s | 22.3 s (the VM boots) |
| Secret back in the environment | yes | yes |

The first try failed for the VM: after the reboot Docker set the
kernel's FORWARD policy to DROP again, the VM had no route out, and the
start timed out fetching feature metadata. A box running both needs
`{"ip-forward-no-drop": true}` in `/etc/docker/daemon.json`; with it,
the second reboot above came back cleanly. Incus starts no environment VM
by itself (`boot.autostart=false`): the control plane does, after
sending its secrets, as it does for containers.

## Security

What a VM adds, against [security.md](security.md)'s known gaps:

- **13, shared kernel:** a container or kernel escape lands in that
  environment's VM: its own secrets, token and tailnet identity. Not the
  other environments, not the agent's key.
- **1, privileged:** privileged containers and docker-in-docker are root
  in one VM, not on the box.
- **3, secrets in `ps`:** the devcontainer CLI's `docker exec -e` runs
  inside the VM, so other users on the box don't see it.
- **4, symlink races:** the host never reads the clone; the races move
  into the VM, where they only reach that environment.
- **14, resource limits:** every environment has a hard CPU and memory
  size.

What it doesn't change, or adds:

- **Network.** Same reach as containers: box services on any address,
  the internet, cloud metadata. Incus makes it easy to block metadata
  (`169.254.169.254` is rejected by the `foreman-env` ACL on the test
  box) but box services need a host firewall rule for traffic from the
  bridge, because an Incus ACL's reject always beats its allow and the
  box answers on every address it has (tailnet included).
- **The agent is still root-equivalent**: `incus-admin` is, like the
  `docker` group. Incus's restricted projects could narrow it.
- **New attack surface**: QEMU (sandboxed by Incus: seccomp, AppArmor,
  an unprivileged user) and incusd, a root daemon. On cloud boxes the
  outer hypervisor's nested-virtualization code belongs to the provider.
- **The owner's registry credential stays out.** It's shared by all of an
  owner's repos, and root in a VM is the environment's, so it isn't passed
  into VMs: private images don't pull on a VM box unless it sets
  `FOREMAN_VM_REGISTRY_AUTH=allow`, which makes that credential readable
  by its environments. A credential per repo, or a pull-through proxy on
  the host that adds it, would remove the choice.
- **Guest output is untrusted**: the host decodes it as data, caps line
  length, ignores a second result, validates the container list it
  reports, holds the usage it reports to the VM's size, and takes VM size,
  isolation and slug from its own records rather than from what the
  guest says. Requests (which carry secrets) are staged on the secrets
  tmpfs, not on disk.

## Ease of use

- **SSH and editors**: unchanged; see Tailscale below.
- **Box setup**: Incus from Zabbly (Ubuntu's 6.0.0 can't start arm64
  VMs), `incus admin init`, a bridge, the `foreman-env` profile (port
  isolation, the metadata ACL), `build-image.sh` (80 s), and
  `install.sh --isolation vm`. With Docker on the same box (a personal
  deployment runs the control plane in Docker), Docker's FORWARD policy
  drops the bridge's traffic after every reboot unless `daemon.json` sets
  `ip-forward-no-drop`.
- **Image pitfalls review caught**: the first image gave every VM the
  same machine id, so every VM got the same DHCP address, and left every
  root filesystem at 10 GB whatever the disk size. Both are fixed in
  `provision.sh` and checked (distinct addresses, a 62 GB root on a 64 GB
  disk). The workload numbers come from one VM at a time; the lifecycle
  numbers, which have two VMs up at once, came out within 3% when
  measured again on the fixed image (second environment 105 s).
- **Debugging**: `incus exec fm-<env_id> -- docker ...` instead of
  `docker ...`; the environment page shows the command.
- **Reliability seen on the test box**: two of about thirty VM operations
  (a create and a Restart affected) failed on a DNS timeout fetching
  feature metadata. The test box's
  upstream DNS times out on about 1% of lookups for both modes; VM
  environments do more cold lookups (nothing is cached across them), and
  the devcontainer CLI doesn't retry. A retry on network errors in the
  agent would cover it.
- **Mac testbed only**: Incus backs guest RAM with shared memfd, which
  under Apple's nested virtualization made VMs boot 4–14x slower (or not
  at all). The `foreman-env` profile overrides it with anonymous RAM.

## Where it can run

Per-environment VMs need `/dev/kvm` on the box:

| Box | KVM | Levels |
|---|---|---|
| Linux desktop | yes | L0 → L1, the cheapest case |
| DigitalOcean droplet | works (foreman-1 shows `svm`, nested=1), not officially supported, live migration can break nested guests | L1 → L2 |
| EC2 | Intel M7i/C7i/R7i/8i families (nested, since Feb 2026) or `.metal`; no AMD or Graviton | L1 → L2, or L0 → L1 on metal |
| Hetzner Cloud | no | |
| Hetzner/OVH dedicated | yes | L0 → L1 |

foreman-1 (1 vCPU, 2 GB) fits at most one small VM environment next to
what it runs today.

## What the numbers mean

The Mac is two levels of virtualization for VM environments and one for
containers, so it overstates the speed cost. Published single-level KVM
numbers put compile workloads 2–10% behind bare metal, and nested ones
10–25% behind single-level, with I/O and IPIs worst. Expect a bare-metal
desktop to be much closer to containers on compile and test speed than
the tables above. Expect the memory, cache and boot-time costs to hold
anywhere: they come from what a VM is, not from nesting.

## Next steps, if this goes ahead

1. **Measure on bare metal and on the droplet**: `e2e/vmbench/bench.sh`
   and `e2e/vmbench/droplet/run.sh`. The droplet run is ready and waiting
   on SSH access.
2. **Prebuilt VM images per repo**: build a repo's images once in a
   builder VM and start its environments from a copy-on-write clone.
   Copying a built VM took 3.5 s; with a boot that puts a second
   environment at about 40 s here instead of 110 s, and closer to 15 s on
   bare metal.
3. **Memory reclaim**: free page reporting on (one `raw.qemu.conf` line),
   plus guest-side reclaim of idle page cache.
4. **A host firewall rule** for traffic from the VM bridge, and the
   metadata block, in the install script.
5. **Retry `devcontainer up` once on a network error.**
6. **Faster boots**: a stripped image (no cloud-init, direct kernel
   boot), or stateful stop.

## Reproducing

On a Linux box with Docker and Incus (`apps/foreman_agent/priv/vm` for
the image), from this repo:

```sh
docker build -f docker/control-plane.Dockerfile -t foreman-cp:bench .
docker build -f docker/box.Dockerfile --target agent-tarball -o /tmp/agent-out .
sudo e2e/vmbench/bench.sh setup
sudo e2e/vmbench/matrix.sh                 # both modes, workloads and lifecycle
sudo e2e/vmbench/capabilities.sh
sudo e2e/vmbench/netcheck.sh
e2e/vmbench/summarize.py /var/lib/vmbench/results/ct-4.jsonl /var/lib/vmbench/results/vm-4.jsonl
```
