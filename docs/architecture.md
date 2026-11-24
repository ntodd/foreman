# Foreman architecture

Status: implemented (v1), 2026-10-13. Environments moved from the box's shared Docker into a VM each on 2026-11-16 (protocol 6, released in 0.6.0); the design and its measurements are in [design/vm-environments.md](design/vm-environments.md), and this document describes the result. See "Implementation notes" at the end for where the build differs from the plan below.

Foreman is a self-hosted replacement for GitHub Codespaces. A Phoenix control plane manages devcontainer environments on Linux boxes you own, each environment in a VM of its own. A small agent on each box does the work. Every environment joins a Tailscale tailnet, and that's how you reach it. Nothing publishes ports.

## Goals

- Pick a GitHub repo that has a devcontainer, choose a box, get a running environment.
- Run several copies of the same repo side by side without hand-assigning ports or hostnames.
- Manage secrets at owner, repo, user and environment levels, each overriding the one before it. Inject them at boot.
- Let secret changes take effect with an optional restart ("restart now" or "restart later").
- Give each environment a GitHub token scoped to its repo by default, with a per-repo opt-out.
- Use one agent protocol for local and remote boxes. The agent always dials out, so boxes need no inbound ports.
- Agents update themselves.

## Non-goals

- Codespaces compatibility. Repos can change to fit Foreman.
- Multi-tenancy. Each deployment serves one team. A personal setup and a team setup are separate deployments.
- A browser editor. You connect with your own editor or tools over SSH on the tailnet.
- Non-compose devcontainers (`image` / `dockerFile` configs) in v1. Every target repo uses compose.

## Deployments

| | Personal | Team |
|---|---|---|
| Control plane | Linux desktop | Small EC2 instance |
| Database | SQLite (the default) | Postgres: Neon or RDS (`FOREMAN_DB=postgres` at build) |
| Boxes | The desktop (local agent) | One or more Linux boxes per developer |
| Users | 1 | A few |
| GitHub App installed on | Your account | The org |
| Tailnet | Personal | The team's (Standard plan) |

Both deployments run the same code with different config. Team secrets never live on a personal deployment.

## Components

```
Browser ──LiveView──► Control plane (Phoenix, SQLite or Postgres, tailnet-only)
                         ▲  WSS (agent dials out)
          ┌──────────────┼───────────────┐
     agent (desktop)  agent (box-a)  agent (box-b)      unprivileged
                         │  taps and VM units through foreman-vmctl (root)
          ┌──────────────┼───────────────┐
   cloud-hypervisor  cloud-hypervisor  cloud-hypervisor  one VM per environment
          │ vsock        │ vsock         │ vsock
     guest agent      guest agent     guest agent        the same release, guest mode
     dockerd          dockerd         dockerd
     compose project  compose project compose project ── tailscaled ──► tailnet ◄── laptops
          tap fm-vm0      tap fm-vm1      tap fm-vm2 ──► box firewall ──► NAT out
```

### Control plane

A Phoenix app that owns all durable state: users, repos, secrets, boxes, environments, desired state and the audit log.

- **UI:** LiveView. Environment status, build logs and box usage stream live.
- **Agent link:** Phoenix Channels. Connected agents register their box IDs in `Foreman.Registry`.
- **One GenServer per environment:** a state machine that sends commands to the agent and records the results.
- **Oban:** durable jobs such as GitHub token refresh, Tailscale device cleanup, idle auto-stop and agent update rollouts.
- **Encryption:** Cloak.Ecto for secrets and stored GitHub tokens.

It is reachable only on the tailnet; see [Networking](#networking).

### Agent

An Elixir release running under systemd on each box, as a dedicated, unprivileged `foreman` user (`NoNewPrivileges`, and a read-only system apart from its own directories). It isn't in the `docker` group, and the box needs no Docker.

The same release runs in two modes. On the box (host mode):

- It connects out to the control plane over WSS with Slipstream.
- It runs each environment in a VM of its own (see [Environment VMs](#environment-vms)). It makes the VM's disks, asks the root helper to start, stop or release the VM, and relays the environment's commands to the agent inside it, passing logs and results back to the control plane.
- It reports on the box: environments from the VMs on it and what each guest says about itself, usage from each VM's cgroup, and host metrics from `/proc` and `df`.
- It holds no durable state beyond a record per VM (`/srv/foreman/vms/.records/<env_id>.json`: the slug, the size, and the guest image and agent the VM boots). The VM cannot mount this directory. When upgrading from a release that kept the record beside the disks, the box takes limits from the control plane on start or stop. The old file supplies inventory and image references. The control plane owns desired state.
- VM helper version 3 restricts attachment to each tap using a dedicated group. Re-run the box installer to update the root-owned helper. Existing VMs adopt the new tap and service settings on their next stop and start. An agent upgrade alone leaves running VMs in their original units.

In an environment's VM (guest mode, `FOREMAN_AGENT_MODE=guest`), it runs the environment code that ran on the box before VMs:

- It uses the VM's own Docker through the Engine API (unix socket) for inventory, start/stop, logs and stats, and Docker labels in the VM record what exists (`foreman.env_id`, `foreman.repo`, `foreman.owner`).
- It brings devcontainers up itself (`ForemanAgent.Devcontainer`), following what `@devcontainers/cli`'s `up` does for a compose-based devcontainer: features, image metadata, the compose overrides, the remote user's uid, lifecycle commands and dotfiles. An environment made by one can be taken over by the other. There is no Node in the release, on the box or in the guest image. It leaves out what Foreman never used: devcontainers that aren't compose-based, Podman, builds without BuildKit, GPU reservations, and the two feature formats the CLI calls deprecated (GitHub-release features and `devcontainer-features.json`).
- It takes commands from the box's agent, never from the control plane, and refuses the ones that belong to the box (updates, reboots).

In both modes it runs child processes under MuonTrap. Cancelling an operation, or a command running past its timeout, kills the command's whole process tree (found through `/proc`), and the environment's next operation waits until it's gone. Every command has a timeout: three hours for `devcontainer up`, 30 minutes for the rest.

The local agent on the personal desktop is the same binary, pointed at `localhost`. There is no separate local runner.

**Host prerequisites:**
- amd64 Linux with KVM (`/dev/kvm`; a box that is itself a VM needs nested virtualization). An arm64 box enrolls but can't run environments yet.
- systemd, nftables, iproute2, e2fsprogs and util-linux (`flock`)
- Tailscale on the host, because the control plane is tailnet-only

No Docker and no git: the guest image has both. Or Flatcar Container Linux, which has all of that from its first boot (see [Flatcar boxes](#flatcar-boxes)).

### Environment VMs

Each environment runs in a Cloud Hypervisor VM, with its own kernel, Docker and Compose. The devcontainer runs in that Docker as it would anywhere else.

- **Cloud Hypervisor** comes in the agent release (its static build, v54.1, pinned by digest in `rel/tools/cloud-hypervisor.sha256`), so the release signature covers it. amd64 only for now.
- **The guest image** (`guest/`): Ubuntu 24.04's HWE virtual kernel and a root filesystem built from Ubuntu 24.04 packages, with Docker, Compose, buildx, git and socat, booted straight from the kernel with no initrd. It's a release artifact, `foreman-guest-<version>-linux-amd64.tar` on the GitHub release. An amd64 agent is built with its URL and SHA-256; it downloads the image the first time an environment needs it, checks it against that digest and unpacks it to `/srv/foreman/guest/<sha256>/`. `FOREMAN_GUEST_URL` and `FOREMAN_GUEST_SHA256` override both, for development and the end-to-end runs.
- **Three disks** per VM, in `/srv/foreman/vms/<env_id>/` unless noted:
  - `root.raw`: the environment's copy of the guest image's root disk. It's made again whenever the image changes; a running VM keeps the one it booted.
  - `data.raw`: the environment's own disk, a sparse file of `FOREMAN_VM_DISK_GB` (64), which the box formats before its first boot. It holds Docker's data, the clone and the guest agent's state: everything the environment keeps.
  - `agent.img`: the box's agent release as a read-only ext4 image, one per agent version in `/srv/foreman/agent-disks/`, shared by every VM. The guest runs the same agent as the box, and an agent update needs no new guest image. A running VM keeps the agent it booted with until its next boot.

  Where `/srv/foreman` can reflink (XFS, btrfs), a new root disk is a reflink: instant, and no extra space. On ext4 it's a full copy. The install script says which, and the box's page shows "full-copy disks" when it can't reflink.
- **The root helper**, `foreman-vmctl`: a POSIX shell script that the install script puts in `/etc/foreman-agent/vmctl` (root's, so the agent can't change it), run by a socket-activated unit for each connection on `/run/foreman-vmctl.sock` (group `foreman`, mode 0660). One request line, one answer line. Its vocabulary is `version`, `landlock`, `tap`, `start`, `restore`, `stop` and `release`; each takes an environment id and sizes or versions, checked against fixed patterns, never paths. It makes the VM's tap and address, builds Cloud Hypervisor's command line itself, and runs the VM with `systemd-run` as a unit of its own, `foreman-vm-<env_id>` in `foreman.slice`. `foreman-restart.path` was the precedent: the agent gets a few narrow root actions and nothing else.
- **The VM's unit** runs Cloud Hypervisor as the agent's user with the `kvm` group: no capabilities, `NoNewPrivileges`, a read-only system apart from the VM's directory, and `/dev/kvm` and `/dev/net/tun` as its only devices. Its limits are a `CPUQuota` of 100% per vCPU, a `MemoryMax` of the guest's memory plus 512 MB for Cloud Hypervisor, no swap, and 1024 tasks. Cloud Hypervisor adds a seccomp filter on every thread and Landlock rules that keep it to the VM's own directory, the guest image, the agent disk and its tap. Every VM runs as the same user, so without Landlock one VM's process could reach the agent's files and other VMs' through `/proc/<pid>/root`: a box whose kernel can't apply it (Linux 6.2 or later, with `landlock` in its LSM list) runs no VMs. The helper refuses them, and the box's report says why. On a resume, Cloud Hypervisor v54.1 starts the virtio workers before it applies Landlock, so they run without it until the VM next boots ([cloud-hypervisor#9118](https://github.com/cloud-hypervisor/cloud-hypervisor/issues/9118)). VMs are never children of the agent, so they keep running through agent restarts and updates.
- **Size.** At each cold boot the box resolves CPU and memory independently. Each uses the environment override, then the repo default, then the box setting (`FOREMAN_VM_CPUS`, normally 4, and `FOREMAN_VM_MEMORY_MB`, normally 8192). The box rounds vCPUs up to whole numbers and caps each resource at its own capacity. The environment's Resources editor saves overrides for the next cold boot. A snapshot resumes at its saved size. The balloon's free page reporting gives memory the guest frees back to the box.
- **Host memory reserve.** The installer sets `MemoryMax=90%` on `foreman.slice`, the parent of all environment and prebuild VMs. The remaining 10% of physical RAM is outside the VMs' budget for the agent, networking and other host services. To change the ceiling, run `sudo systemctl edit foreman.slice` and set `MemoryMax` under `[Slice]` (for example, `MemoryMax=85%`). The drop-in survives installer reruns. Lowering a live ceiling below current usage can trigger reclaim and an OOM kill immediately.
- **VM out-of-memory exits.** The box reports systemd's `oom-kill` result and exit time before sending stopped inventory. The environment page keeps the latest such exit through a restart. Normal exits and failures with other causes do not produce this notice. Re-run the installer on existing boxes to install the slice and updated root helper. VMs started with the updated helper retain their failed unit until its next start.
- **Out-of-memory kills inside a VM.** A VM that runs out of its own memory keeps running: its kernel kills a process (a dev server, a language server, the guest agent) and nothing changes on the box. The kernel prints `Out of memory: Killed process <pid> (<name>)` on its console, or `Memory cgroup out of memory: ...` for a container over its own limit, at a level the `quiet` boot leaves on. Every 15 seconds the box's agent reads what each VM's `serial.log` has gained and sends `box.guest_oom` with the names it found and the time it saw them. It needs nothing from the guest, so it also covers the guest agent being the process killed. The file is read through the VM file helper (never a link, at most the last 64 KiB), and a name with control characters is dropped. The control plane keeps the latest kill and its process names on the environment. The environment's page shows them, lists mark the environment "Out of memory" for a day, and the owner and admins get a notice, at most one per environment every five minutes. A box stopping a whole VM raises the same notice and mark. What a console already held when the agent started isn't reported, so a kill during an agent restart or update is missed. A control plane older than this event refuses it and the agent carries on.
- **Page cache:** a VM keeps the box memory its guest's page cache filled, because free page reporting only hands back what the guest frees. When less than `FOREMAN_VM_RECLAIM_BELOW` percent (20) of the box's memory is available, the box's agent asks VMs that have been quiet for ten minutes (no sample over half a core, sampled every 30 seconds from their cgroups) to reclaim all but `FOREMAN_VM_RECLAIM_KEEP_MB` (2048) of their page cache and compact, longest quiet first, then biggest, until what they say they freed covers the gap to five points past the threshold. It then waits 90 seconds for the memory to come back and measures again. A VM is asked again once it has grown a GiB past where it settled, or after an hour. `FOREMAN_VM_RECLAIM_IDLE_MINUTES` also asks a VM quiet that long, once per quiet stretch. Half a core, because healthchecks and file watchers keep an idle VM over a tenth, and the box sees more than the guest since every vCPU wakes for each one: an idle VM running [#200](https://github.com/ntodd/foreman/issues/200)'s compose stack, each container healthchecked every second, measured 0.13 cores in the guest and 0.25 to 0.30 from the box. A build takes several. The guest can ignore it, so nothing counts on it: the VM's `MemoryMax` is what protects the box, and placement doesn't assume a reclaim will happen. On a 32 GiB VM after a session, this took the box's share from 14.3 to 6.2 GiB, and cost the next round of work 0.7 s out of 26 ([#200](https://github.com/ntodd/foreman/issues/200)).
- **Host transparent huge pages.** On boxes where host page compaction slows concurrent boots, set `Environment=FOREMAN_VM_THP=0` in a `[Service]` drop-in for `foreman-vmctl@.service` and run `systemctl daemon-reload`. This requires the updated root helper. New cold boots pass `thp=off` to Cloud Hypervisor for guest RAM. Resumes use the setting saved in the snapshot. Removing the drop-in restores the hypervisor default on subsequent cold boots. Benchmark memory-intensive workloads on the box when choosing this setting.
- **Compressed guest swap (opt-in per box).** Set `Environment=FOREMAN_VM_ZRAM=1` in the `[Service]` section of a systemd drop-in for `foreman-vmctl@.service`. Reload systemd after changing the drop-in. The updated helper passes the setting on the next cold boot. Resuming a snapshot keeps the original setting. The guest uses LZ4 and keeps swap in RAM, with a logical size of half its RAM capped at 16 GiB. When the box asks a quiet guest for memory, it reclaims excess file cache first. A separate request compresses up to two thirds of resident anonymous pages, limited to 2.5 GiB and the remaining swap space. The helper then compacts and drains once. Removing the drop-in disables the feature on subsequent cold boots.
- **The channel** between the box's agent and the guest agent is Cloud Hypervisor's hybrid vsock. The box connects to the VM's `vsock.sock` and asks for port 1024, where `socat` in the guest joins it to the guest agent's unix socket; the box always connects, the guest never does, and no network is involved. Frames are JSON with a four-byte length, at most 4 MiB from the box and 1 MiB from the guest, which the box reads no faster than a per-link byte-rate limit and decodes under a memory and time bound (a hostile guest otherwise spends the box's CPU outside its cgroup). The box sends `hello` (its time, and the clone hosts the box allows), `cmd` (a protocol command with the control plane's op id), `cancel`, `ack` and `query` (inventory, ports, or a reclaim of the guest's page cache); the guest sends `hello`, `event` (`op.accepted`, `op.log`, `op.result`, acknowledged as the control plane acknowledges them) and `reply`. A command resent after a reconnect gets the guest's stored result, so it runs once. The guest steps its clock to the box's when it's more than two seconds out.
- **The guest is hostile.** Anything in the environment can take the VM over, so the box's agent checks every frame: an oversized one closes the connection, and anything that isn't a valid hello, event or reply, an event for an operation the box didn't send, or an inventory or ports reply about another environment, is dropped.
- **The guest agent** runs as its own unprivileged user in the VM, in Docker's group, with `CAP_SYS_TIME` for the clock and nothing else. It gives the container's remote user its own uid (the devcontainer spec's `updateRemoteUserUID`), so the clone and the 0600 secrets are the container user's own. Giving back page cache needs writes as root (`memory.reclaim` at the guest's root cgroup, then `compact_memory`, then a drain of the per-CPU free lists through `percpu_pagelist_high_fraction` and `stat_refresh` and a second compaction), so a root helper in the guest image does them: `foreman-guest-reclaim`, socket-activated on `/run/foreman-reclaim.sock` (root and the agent's group), one request line (the bytes to reclaim) and one answer line.

### Flatcar boxes

A box can run Flatcar Container Linux: in a VM on a Linux machine with KVM (`vm.sh`: QEMU as an unprivileged user under systemd, with user-mode networking and `-cpu host`, so the box has nested virtualization for its environment VMs), or on bare metal (not yet tested with environment VMs, [#179](https://github.com/ntodd/foreman/issues/179)). Environments on a Flatcar VM run nested, which is slower: see [setup/flatcar.md](setup/flatcar.md#performance). The control plane makes the box's first-boot config (Ignition) for a join token, `Foreman.Boxes.Flatcar`: Compose and Tailscale as system extensions from Flatcar's sysext bakery, pinned by digest and updated by systemd-sysupdate; the box's own Tailscale key, minted by the control plane's OAuth client (`tag:foreman-box`) or pasted with the token; and a oneshot unit that joins the tailnet, waits for the control plane and runs its install script. The launcher fetches the config from `POST /agent/flatcar/ignition` with the token; "Add a box" offers it to download for bare metal and Proxmox.

The config reaches the box the way its platform allows. Under QEMU, Flatcar reads it from `fw_cfg`; Proxmox reads it from a cloud-init drive.

Flatcar updates itself to its other partition. The install script turns off its reboot manager and flags an applied update in `/run/reboot-required`, as it does a new extension, so both show as a reboot the box needs and wait for an admin's Reboot. See [setup/flatcar.md](setup/flatcar.md).

Until environments moved into VMs, a Mac could be a box too: `mac.sh` ran Flatcar under vfkit on Apple's hypervisor. Nested virtualization there is poor, so Mac boxes went with shared Docker and come back with [#180](https://github.com/ntodd/foreman/issues/180), which runs environment VMs on Apple's hypervisor directly.

### Environment

One devcontainer compose project, plus a Foreman overlay and the Foreman devcontainer feature, in a VM of its own. An environment belongs to one user, one repo and one box.

## Agent protocol

### Enrollment and auth

1. An admin creates a one-time join token in the UI.
2. The install script runs on the box: `curl …/install.sh | sh -s -- --token …`.
3. The agent generates an ed25519 keypair and registers its public key using the join token. The token is then consumed.
4. On every connect, the agent sends `agent_id`, a timestamp and a signature over both, in a header. The control plane checks the signature against the stored public key and rejects clocks more than 60s off.
5. Revoking an agent deletes its public key. Its socket is disconnected immediately.

Distributed Erlang is not used between the control plane and agents. It is a full-trust mesh, so any connected node could run code on any other.

### Relayed API requests

An environment reaches the public API from inside itself through its box, with no token of its own. The box sends each request over HTTP to `/api/agents/relay/v1/…`, which mounts the same routes as `/api/v1`, and signs it with its enrolled key (`ForemanProtocol.Auth.relay_headers/4`). The signature covers the environment the request is for, the method as sent, the path and query, the body's SHA-256 and the idempotency key or the lack of one, with a timestamp and a nonce. It is good for that one request: the control plane refuses a signature that is stale, made for a different request, or for an environment the box doesn't run, and it accepts each nonce once. Accepted nonces are kept in the database (`relay_nonces`), by the request's own timestamp, so a control plane that restarts, or a second one, refuses a replay too. A relay signature opens nothing under `/api/v1`, and a bearer token opens nothing under the relay.

The request then acts as the environment's owner on a grant made for that environment (`Foreman.OAuth.EnvironmentConnection`). The grant reaches that environment and nothing else of the owner's: its state, operations and logs, its own secrets, and stopping, starting and restarting it. It can't destroy the environment, create another, list repositories or boxes, or touch user, repository or owner secrets, whatever the owner's role. No token is issued for it. It ends when the environment is destroyed or its owner is disabled or loses access, and a service account's environment has none.

Who asked for a state and whose authority supplies an environment's credentials are two things, and this grant can only be the first. A stop or a start asked from inside is recorded as the grant's request, so a later repair of that state is authorized the way the request was. The grant is never recorded as the one an environment runs on, never takes a workspace over from the connection that launched it, and isn't what its credentials are made from. So a restart from inside runs with the credentials the environment already had, and is refused once the connection that launched it has been revoked. An environment can't renew its own access.

A box can only ever speak for its own environments, which it already runs and whose secrets it already holds. A request a box signed counts against that box's allowance for that environment, then the box's own, before anything is looked up for it. One environment can't use up its box's allowance, and a box can't spend an allowance on another box's account. Unsigned requests count against the address they came from, as refused agent connects do.

Inside the VM, the guest agent listens on `api.sock` in the environment's directory, which the devcontainer already has read-only at `/run/foreman`, and speaks plain HTTP/1.1 there (`ForemanAgent.Guest.API`). The socket has the mode the secrets beside it have, so whoever can read them can ask. Each request goes to the box as one `api` frame on the VM's link and comes back as one `api.reply`. The link is the environment's, so the box knows which environment is asking without being told, and nothing in a frame can say otherwise.

The guest is hostile, so the box passes very little (`ForemanAgent.VM.Relay`): `GET`, `POST` and `PATCH`; a target under `/api/v1/` made of plain path segments and a plain query, with no dots alone, no encoding in the path and no empty segment; a body on a change only; and an idempotency key of printable characters. No other header of the guest's reaches the control plane. At most four requests are in flight for a VM, each has a time limit, and none outlives the connection it came on. The frames are read under the same byte-rate limit as everything else the guest sends.

The box relays over HTTPS, or to a control plane on its own loopback. The signature protects the request, but nothing vouches for the answer over plain HTTP, so there the box refuses unless `FOREMAN_RELAY_INSECURE=1` is set on a network its operator trusts.

### Messages

Each agent joins topic `agent:<agent_id>`. Commands are a fixed vocabulary; there is no generic `exec`.

| Command | Purpose |
|---|---|
| `env.create` | Make and boot the VM, then clone, write overlay and secrets, `devcontainer up` in it |
| `env.start` / `env.stop` / `env.restart` | Lifecycle. Start boots the VM if it's off; stop powers it off after the environment's own stop |
| `env.rebuild` | Recreate containers, keeping volumes and the clone; with `pull`, fast-forward the clone to its branch first |
| `env.destroy` | Power the VM off and delete its disks (containers, volumes and the clone with them) and its tap |
| `env.secrets.write` | Rewrite the environment's tmpfs secrets directory, on the box and in the VM |
| `env.logs` | Stream container or build logs |
| `env.git_status` | Dirty tree / unpushed commits check before destroy; the clone's HEAD and merge base, which the environment page compares with the branch on GitHub |
| `env.connect` | Run an action of a connect hook a feature installed (pairing a client, say) and return its result, which the control plane shows once and doesn't store; see [connect-hooks.md](setup/connect-hooks.md) |
| `box.inventory` | Report the environments with a VM on the box, with the state and containers each running guest reports |
| `box.stats` | Report CPU, memory and disk, per environment (from each VM's cgroup) and in total |
| `box.gc` | Prune unused images, build cache and orphaned volumes in every running VM, and drop guest images and agent disks no VM uses |
| `box.restart` | Reboot the box, if it's still on the boot the control plane saw |
| `agent.update` | Install a new agent release |

Every command carries an `op_id`. The agent records in-flight `op_id`s, so a command retried after a reconnect is not run twice. Long operations keep running if the socket drops. The agent sends their progress and result once it reconnects.

The agent sends its version and protocol version when it joins. The control plane accepts protocols 6 through 8, and only sends a protocol-N field to agents that reported N, so upgrade the control plane before the agents (an older control plane refuses newer agents). Protocol 2 added `keep` to `env.secrets.write`. Protocol 3 added `features` (a user's own devcontainer features) to `env.create` and `env.rebuild`, where an environment on an older agent builds without them, `pull` to `env.rebuild`, which isn't offered on older agents, and the `gpu` policy rule. Protocol 4 added `registry_auth` to `env.start` and `env.restart`, which run `devcontainer up` and resolve the repo's features again; an environment with a private feature on an older agent only starts on a rebuild. Protocol 5 added `box.restart`, and `can_restart` and `boot_id` to the `box.reboot` event; the control plane only offers a reboot for boxes that report they can. Protocol 6 runs every environment in a VM: the join reports whether the box can run them (`vm`: whether it's ready and why not, whether its VMs are nested, and whether its disks can reflink) and no longer reports a compose policy. A protocol 5 agent runs environments on the box's shared Docker, which protocol 6 removed, so the control plane refuses it at join, and the box's page says "Agent too old" until the install script runs on it again. Protocol 7 added the environment's assigned size (`limits`) to `env.start` and `env.stop`, so a box upgrading from a build that kept the VM record beside the disks takes the size from the control plane. Protocol 8 adds the effective VM defaults and host caps to the join, and the boot allocation to inventory. Protocols 6 and 7 both came in with 0.6.0. The join's optional `feature_version` came without a new protocol: control planes before it refuse agents that send it. `env.connect` and the `connect` field of up results came without one too, in 0.4.8, and older control planes are fine with agents that have them: they ignore the field and never send the command. The control plane only sends `env.connect` for hooks an agent reported, which older agents never do. Once boxes run agents on a protocol, the control plane can't be rolled back past the release that introduced it: an older control plane refuses them at join.

### Reconciliation

When an agent joins, it reports what's on the box. The control plane compares that with the desired state of each environment (`running`, `stopped` or `destroyed`) and sends the commands needed to match.

VMs don't come back on their own after a box reboots, and the overlay sets `restart: "no"` on every service, so the agent controls start order. That matters because secrets live on tmpfs, which a reboot clears:

1. The box boots and the agent starts and connects.
2. The control plane resolves secrets and sends `env.secrets.write`. The VMs are off, so the agent keeps the files on the box's tmpfs, and the write succeeds.
3. The control plane sends `env.start` for every environment whose desired state is `running`. The agent boots each VM and writes the secrets into it before the environment starts.

As a result, environments don't come back after a reboot until the control plane is reachable. The personal control plane runs on the same box, so this only affects team deployments.

## Environment lifecycle

### Naming

- **Slug:** `<repo>-<n>` on the personal deployment, `<repo>-<login>-<n>` on a team deployment. For example `storefront-2` or `storefront-alice-1`.
- **The slug is used as:**
  - the compose project name (`COMPOSE_PROJECT_NAME`), which makes every named volume unique per copy
  - the Tailscale hostname
- **The VM's directory:** `/srv/foreman/vms/<env_id>/` on the box.
- **The clone:** `/srv/foreman/envs/<env_id>/workspace/<repo>` in the VM, on its data disk.
- **Secrets directory:** `/run/foreman/envs/<env_id>/`, on tmpfs both on the box (the agent's copy) and in the VM (the one the environment mounts).

### Create flow

1. The control plane picks the box, then resolves the slug, secrets, GitHub token and Tailscale auth key. It won't place an environment on a box that can't run VMs.
2. The box's agent keeps the secrets on its tmpfs, makes the VM's disks (downloading the guest image the first time; the data disk is a copy of the box's prebuild of the repo's branch when it has one, see [Prebuilds](#prebuilds)), asks the root helper to start the VM, waits for the guest agent's hello, and writes the secrets into the VM. It then relays `env.create` to the guest agent, which does the rest inside the VM.
3. The guest agent writes the secrets directory and clones the repo. It uses a credential helper that reads the token file, so the token never appears in the URL or `.git/config`.
4. It reads `.devcontainer/devcontainer.json` (JSONC) and writes two files to its own directory:
   - an override config that appends the overlay to `dockerComposeFile`, using absolute paths
   - the overlay itself

   If `--override-config` can't add the overlay (spike 1), repos opt in instead: each lists a gitignored `foreman.compose.yml` in `dockerComposeFile`, and the agent writes that file into the clone.
5. It runs, with `COMPOSE_PROJECT_NAME` set and compose-interpolated secrets in the process environment:

   ```
   devcontainer up \
     --workspace-folder <clone> \
     --override-config <override> \
     --id-label foreman.env_id=<id> \
     --additional-features '{"./.foreman/feature": {"tailscale": true}, <user's own features>}' \
     [--dotfiles-repository <user's dotfiles repo>]
   ```

   Build output streams back to the UI, through the box's agent.
6. The agents report the result. The control plane records the Tailscale device ID once the node shows up.

### Prebuilds

An admin has a box build a prebuild of a repo's default branch
(`box.prebuild`). The box runs an `env.create` in a VM of its own under
the prebuild's id, with an installation token that reads the repo and no
one's secrets, tells the guest it's a prebuild (it also pulls its
Dockerfiles' base images by tag, so later builds don't ask the registry
about them), powers it off and keeps the data disk as
`/srv/foreman/prebuilds/<id>/data.raw`. The VM it was built in is never
reported as an environment.

A create on that box and branch carries the prebuild's id, once the
user's own GitHub token has shown it reads the repo and its extra repos
(with no GitHub App configured, there's no one to ask). The box
copies the disk (a reflink on XFS) instead of making an empty one, and
names the environment on the guest's kernel command line. A disk made
for someone else loses its containers, volumes, networks and guest-agent
state before Docker starts (some containers restart on their own), and
keeps its images and build cache. The guest agent then takes over the
prebuild's clone: it resets the clone's git settings and hooks to a fresh
clone's, fetches the branch with the environment's own token and checks
it out (cloning afresh if that fails), and runs `devcontainer up` as
usual, which makes the environment's containers from the cache. The
guest agent's home is on tmpfs, so nothing the prebuild left runs as it. Building another replaces the
ready one; `box.prebuild.delete` frees a box's copy, and `box.gc` names
every prebuild the control plane knows on the box so it deletes the
rest. A build fails when the box's agent rejoins without it, and one that
never reports back fails after five hours; a result that arrives later
still counts.

### Generated overlay

```yaml
services:
  app:                      # the devcontainer's "service"
    ports: !reset []
    restart: "no"
    volumes:
      - /run/foreman/envs/<env_id>:/run/foreman:ro
      - tailscale-state:/var/lib/tailscale
    environment:
      FOREMAN_ENV: <slug>
      TS_HOSTNAME: <slug>
  db:                       # every other service gets the same reset
    ports: !reset []
    restart: "no"

volumes:
  tailscale-state:
```

Before environment VMs, the overlay also put every network on a bridge named `fm-<12 hex>`, which is how the box's firewall picked out environment traffic, and the compose policy refused any network that didn't end up on one. A VM's bridges are its own, so both went: the firewall picks out a VM's traffic by its tap.

### Foreman feature

A devcontainer feature that ships inside the agent release, so a box installs the feature version its agent was built with. The agent copies it into the clone at `<config dir>/.foreman/feature` (excluded through `.git/info/exclude`) and adds it with `--additional-features`, so repos don't declare it. (Spike 1 showed the CLI resolves local features against the repo's devcontainer folder, not the override config's.)

The feature goes into the image, and the CLI builds the image only when it creates the container, so a start or restart that reuses a container keeps the feature it was built with. The overlay labels the devcontainer with `foreman.feature_version`, which Docker sets when the container is created and the CLI never changes on a container it reuses (it passes `--no-recreate`); every other service gets an empty one, so a repo can't label a service it later makes the devcontainer. With replicas, the oldest label counts, since a replica scaled up later skips the build. The agent reads that label to report the version in up and restart results, and reports the version it ships when it joins. The environment page offers a rebuild when the box ships a newer one. A start or restart rebuilds a container whose label is below the agent's floor (1.1.0, which dropped `NET_ADMIN` and `NET_RAW`) or missing; the start a pull needs first doesn't, so a refused pull leaves the container as it was.

- **Tailscale:**
  - Installs `tailscale` and `tailscaled` from the static tarball, with a checksum check.
  - Its `entrypoint` starts tailscaled and runs `tailscale up --ssh --auth-key=file:/run/foreman/ts-authkey --hostname=$TS_HOSTNAME …`.
  - tailscaled always uses userspace networking, so the devcontainer gets no TUN device and no `NET_ADMIN`, and tailscaled never touches its routes, firewall or DNS. Connections into the environment (Tailscale SSH, its ports, `tailscale serve`) work as usual; connections out to other tailnet machines go through a SOCKS5 and HTTP proxy on `127.0.0.2:1055` (not 127.0.0.1, which tailscaled forwards tailnet connections to). In this mode tailscaled hands connections from the tailnet to `127.0.0.1:<port>`, so servers bound only to localhost are reachable from the tailnet too, and see every tailnet peer as 127.0.0.1.
  - Because it is an entrypoint, it runs on every container start, including `docker restart`. A `postStartCommand` only runs when the agent brings the devcontainer up.
- **Secrets hook:** installs `/etc/profile.d/foreman.sh`, which sources `/run/foreman/secrets.env`. A zsh equivalent goes in `/etc/zsh/zprofile`. The hook also prints `/run/foreman/notices` when it isn't empty.
- **Container environment over SSH:** Tailscale SSH (and VS Code over SSH) starts a clean login shell, without the container's environment: compose `environment:`, `containerEnv`, or a `PATH` the image set. The entrypoint saves that environment to `/etc/foreman/container.env` on every start, and the hook loads it before the secrets, so an SSH shell sees what `docker exec` would.
- **Git:**
  - Installs an `/etc/gitconfig` that includes `/run/foreman/gitconfig`.
  - Installs a git credential helper that reads `/run/foreman/github-token`.
  - Points `gh` at the same token file.
- **Ownership:** Tailscale bootstrap now belongs to the feature. Repo-level copies (`install-tailscale.sh`, `tailscale-up.sh`, the shared `devcontainer-authkey` mount) go away.

### Stop, restart, rebuild, destroy

- **Stop:** `docker compose stop` in the VM, then the VM powers off (its ACPI power button, and a forced stop after a minute). Sidecars get a graceful shutdown; for example, a Neon Local sidecar deletes its branch on stop.
- **Suspend:** pauses the VM, writes its memory and device state to `/srv/foreman/vms/<env_id>/snapshot/` and stops it. Nothing in the environment notices: processes, open shells and containers carry on where they were when it comes back. A snapshot is the VM's whole memory (8 GB for an 8 GB VM), so it costs disk where a stop doesn't.
- **Start:** resumes a suspended VM from its snapshot (in well under a second), or boots the VM if it's off. Either way the box then puts the guest's clock right, writes the secrets into it, and runs `devcontainer up`. The snapshot is deleted once the VM is back from it; one that won't resume, or that was taken by a box agent or guest image the box has since replaced, is thrown away and the VM boots instead. So is one whose saved config isn't the one start gave the VM: Cloud Hypervisor restores whatever it says, Landlock included, and the snapshot is in the VM's own directory, which the VM can write. A stop of a suspended environment resumes it first, so its own stop runs; a destroy deletes the snapshot with the rest of the VM. Secrets that changed while it was suspended stay pending a restart after the resume, since its processes kept the ones they had.
- **Restart:** a stop followed by a normal start, as one operation, inside the VM; the VM keeps running. Nothing is rebuilt.
- **Rebuild:** `devcontainer up --remove-existing-container`. Named volumes, the clone and the Tailscale identity survive.
- **Pull and rebuild:** a rebuild that first fast-forwards the clone to `origin/<branch>`. git runs inside the devcontainer (started first if it's stopped), as the remote user with the environment's own credential helper, never as the agent. It refuses, before anything is torn down, if the tree has uncommitted changes, the clone has commits the branch doesn't, another branch is checked out, or the fast-forward fails; the environment stays running and the page shows why.
- **Destroy:**
  1. The agent runs `env.git_status`. The UI warns about a dirty tree or unpushed commits.
  2. The box's agent has the root helper stop the VM and remove its tap, then deletes the VM's directory (its disks, and with them the containers, volumes and clone) and the box's copy of the secrets.
  3. The control plane deletes the Tailscale device the environment joined as through the API.

## Networking

### An environment VM's network

- **One tap per VM**, `fm-vm<n>`, routed with no bridge. The root helper gives each VM a /30 from `10.250.0.0/16` (`install.sh --vm-subnet A.B` picks another /16) and records it, so a VM keeps its address until it's destroyed: the box holds one address and the guest the other. With no shared segment there's no ARP spoofing between guests. Guests are IPv4 only.
- **The box routes and masquerades** what a guest sends. The install script turns IPv4 forwarding on from boot (`/etc/sysctl.d/90-foreman.conf`), not only when the firewall loads: turning it on later makes the kernel turn LRO off on every network card, and some drivers (atlantic, for one) reset the link to do that. The first install still does it once.
- **The firewall's table for guests**, `inet foreman_guests`, loaded with the box's other table (see [The box's firewall](#the-boxs-firewall)): nothing from a guest reaches the box itself, on any of its addresses, apart from replies to the box's own connections; guests don't reach each other; nothing a guest sends goes to the tailnet, MagicDNS included; a guest sends only from its own address (a routing check, `fib saddr . iif oif missing`, drops anything that wouldn't be routed back through its tap, so the table has no per-VM state); and nothing outside the box starts a connection into a guest. Guests reach the box's LAN by default; link-local services, including cloud metadata, are blocked in either mode. `install.sh --block-lan` also blocks RFC 1918 destinations. DNS to configured resolvers is allowed.
- **Past other firewalls:** Docker and ufw set iptables' `FORWARD` policy to drop. A small script, `guest-forward`, accepts traffic from the taps and the replies to it at the top of `FORWARD` when iptables is there, and the reload timer puts it back.
- **DNS:** a guest gets the box's upstream resolvers (systemd-resolved's list when the box uses its stub), without loopback, IPv6 or tailnet ones, and 1.1.1.1 when that leaves none. A guest can't use a resolver on the box or MagicDNS.
- **Addressing in the guest:** the helper passes the address, gateway, resolvers and the NIC's MAC (which goes with the address) on the kernel command line, and the guest finds its NIC by that MAC.

### The box's firewall

The install script loads `foreman.nft` (shipped with the agent) through `foreman-firewall.service`, and a timer (`foreman-firewall-check.timer`) loads it again every 15 seconds, in case something flushed the ruleset. It has two tables:

- `inet foreman` keeps anything arriving on an interface named `fm-…` (every VM's tap) or, on a box with Docker, Docker's default bridge, off the tailnet and the box's own tailnet addresses. `--default-bridge-reaches-tailnet` leaves the default bridge out.
- `inet foreman_guests`, above.

A Flatcar box that is a VM gets a third, `inet foreman_vm`, that keeps environments off its gateway (DNS aside), which is the machine it runs on. The agent reports whether the firewall is loaded, and from which rules; the control plane flags a box without it, or with older rules than its agent ships.

### Tailscale per environment

- **Auth keys:** the control plane holds a Tailscale OAuth client with the `auth_keys` scope. It mints one key per environment (`?ephemeral=false&preauthorized=true`) tagged `tag:foreman-env`, plus any tags configured on the repo (for example `tag:staging-access`).
  - Tagged devices have key expiry disabled.
  - The auth key is only needed the first time. State persists in the `tailscale-state` volume, in the VM's Docker on its data disk, so rebuilds keep the same node.
- **Hostname:** the slug, so you reach environments at `storefront-2`, `storefront-2:4000`, and so on.
- **HTTPS:** a plain-HTTP tailnet hostname is not a secure context, which breaks secure cookies, WebAuthn, clipboard access and service workers. Repos that need those run `tailscale serve` to get `https://<slug>.<tailnet>.ts.net`.
  - Hostnames land in public certificate transparency logs, so keep them bland.
  - Let's Encrypt rate limits are another reason to keep state persistent.
- **SSH:** Tailscale SSH.
  - The feature runs `tailscale up --ssh`, so `ssh vscode@storefront-2` works on port 22 with no keys and no sshd.
  - Tailnet ACLs decide who can log in as which local user.
  - SSH rules use `action: accept`, not `check`, so editors and other SSH tools aren't sent to re-authenticate.
- **DNS:** untouched. In userspace mode tailscaled doesn't change `resolv.conf`, so Docker's resolver keeps answering compose service names. MagicDNS names resolve for connections made through the proxy.
- **Cleanup:** after a create, rebuild or start, the agent asks the devcontainer's tailscaled for its node ID and reports it, and the control plane stores it as the environment's `tailscale_device_id`. Destroying the environment deletes that device and nothing else: two deployments on one tailnet can both have a `storefront-1`, so a hostname match isn't enough. An environment that comes back as a new node (its Tailscale state was lost) has the old device deleted and the new one renamed to the slug. The ID comes from inside the repo's container, so every delete also needs `tag:foreman-env`, the environment's hostname and, when one is configured, the deployment tag.
  - An hourly job retries the deletes for destroyed environments.
  - With `FOREMAN_TAILSCALE_DEPLOYMENT_TAG`, every environment also carries that tag, and the hourly job removes devices with it that don't belong to a live environment, recorded or not. Without it, devices Foreman has no record of are left alone.

### ACLs

Each environment is a full tailnet node, and anything running inside it (an npm postinstall script, for example) can use the network.

- `tag:foreman-env` may not initiate connections to user devices or to other environments.
- Repo tags grant extra access when needed.
- Team: environments also carry a per-developer tag (`tag:foreman-<login>`), owned by the OAuth client. That lets SSH and network rules limit each developer to their own environments. Whether developers can reach each other's environments is a team decision.

### Control plane exposure

The control plane listens only on the tailnet.
- The GitHub OAuth redirect happens in the browser, so a tailnet hostname works as the callback.
- GitHub webhooks would need public ingress, so v1 polls. If webhooks become necessary, expose one path with Tailscale Funnel.

### Pricing note

The Personal plan is free but non-commercial only. A team needs Standard ($8/seat/month), which includes 50 tagged devices and charges $1/month for each one after that. Environment nodes count as tagged devices, so cleaning up dead nodes saves money.

A Mac can be on only one tailnet at a time, so working on both deployments means switching between tailnets.

## Secrets

### Scopes and precedence

Secrets resolve in order of increasing priority:

1. **Owner:** the GitHub org, or the user account for personal repos.
2. **Repo**
3. **User:** applies to all of the user's environments, or to selected repos only.
4. **Environment:** applies to one environment. Useful when a second copy needs a different value.

Values are write-only in the UI: once saved, they can be replaced but not read back. Every change goes to the audit log.

- **Encryption:** Cloak.Ecto with AES-GCM. The personal key lives in the deployment's environment. A team deployment's key lives in AWS KMS or Secrets Manager.
- **Permissions:**
  - Owner and repo secrets: admins.
  - User secrets: the user.
  - Environment secrets: the environment's owner.

### Delivery

The control plane resolves secrets and sends the plaintext over WSS (TLS). The box's agent keeps the latest files in `/run/foreman/envs/<env_id>/` on the box's tmpfs, readable by it alone, and writes them into the VM after every boot and with every `env.secrets.write` while it runs. A write for a stopped environment only updates the box's copy, and succeeds, so the control plane's order after a reboot (secrets, then start) works unchanged. In the VM, the guest agent writes them atomically (write a temp file, then rename) into the same path on the VM's tmpfs. That directory is bind-mounted read-only at `/run/foreman`. It is mounted as a directory rather than as individual files: an atomic rename replaces the inode, and a file-level bind mount would keep showing the old one.

Files in that directory:
- `secrets.env`: resolved secrets, sourced by login shells through the feature's profile hook.
- `github-token`: the environment's GitHub token.
- `ts-authkey`: the Tailscale auth key, only needed on first boot.
- `gitconfig`: git identity and credential helper settings.
- `notices`: short messages that new shells print, such as "secrets pending restart" or "GitHub login expired".

Secrets reach a running environment in three ways:

| Channel | Example | When a change takes effect |
|---|---|---|
| `secrets.env` sourced at login (default) | most app secrets | New shells immediately; running processes after a restart |
| Compose interpolation (`${VAR}` in compose files) | sidecars such as Neon Local | After the affected services are recreated |
| GitHub token file | git, `gh` | On the next use; no restart needed |

Foreman has nothing like the devcontainer CLI's `--secrets-file` or `--remote-env`. Those values go on the host's `docker exec` command line as `-e NAME=VALUE`, where any user on that host can read them with `ps` ([devcontainers/cli#1317](https://github.com/devcontainers/cli/issues/1317), open).

The same issue covers environment variables probed from login shells during lifecycle hooks, and those include sourced secrets. The CLI's host is now the environment's VM, so they show in the VM's process list and not the box's. Before environment VMs, the advice for shared boxes was to mount `/proc` with `hidepid=2`.

### Changing secrets: restart now or later

Each environment records the hash of the secrets it last applied. When the resolved secrets change:

1. The agent rewrites the secrets directory right away, so new shells see the new values.
2. The UI marks the environment **secrets pending restart**, and the same notice appears in new shells.
3. The UI offers three actions:

| Action | What it does |
|---|---|
| **Restart affected** | Restarts the devcontainer service, so the entrypoint and `postStartCommand` run again. Recreates only the compose services that reference a changed name through `${NAME}`; the agent finds them by scanning the compose files. Everything else, including the database, keeps running. |
| **Restart all** | Stops and starts the whole compose project. |
| **Later** | Keeps the badge and notice until one of the restarts runs. |

A full recreate is a separate **Rebuild** action and isn't offered here.

## GitHub integration

### App

A GitHub App, installed on your account for a personal deployment or on the org for a team (the org install needs an org owner).

- **Login:** the app's user OAuth flow. Membership in the installed org (or a configured team) controls who can log in to a team deployment.
- **Tokens:** user access tokens last 8 hours. Refresh tokens last 6 months and are single-use. Refreshes are serialized per user with a row lock, so two concurrent refreshes can't burn the same refresh token.
- **Repo browsing:**
  - List the installation's repos.
  - Mark the ones that have `.devcontainer/devcontainer.json`, `.devcontainer.json` or `.devcontainer/*/devcontainer.json`.
  - Cache the results and refresh them by polling. Repos and owners are matched by GitHub id, so renames and transfers keep their settings and secrets; a different repo that takes a known repo's old name gets a row of its own, never the old one's secrets. Repos that leave the installation are hidden, not deleted. Only a 404 means a repo has no devcontainer: any other error keeps what's stored.

### Environment tokens

By default, each environment gets a scoped user token from `POST /applications/{client_id}/token/scoped`.

- **Scope:**
  - **Repos:** the environment's repo plus any extra repos configured on it, then any configured on its owner, which every one of the owner's repos gets.
  - **Permissions:** configured per repo, defaulting to `contents:write`, `pull_requests:write`, `issues:write` and `metadata:read`.
- **Identity:** the token acts as the user, so commits are pushed and PRs opened as you, not as a bot. On a team that keeps "can't approve your own PR" rules meaningful.
- **Refresh:** scoped tokens come without a refresh token. An Oban job refreshes the parent token and re-scopes it every few hours, then sends the new file through `env.secrets.write`. An environment is only handed a token with at least five hours left, and the job also catches users whose token would expire before its next run. A refresh runs in its own process, so a closed tab or a crash can't lose the rotated refresh token. Refreshing rotates the user's token (GitHub revokes the old one), so a refresh also queues fresh tokens for every running environment of that user.
- **GitHub unavailable:** a 5xx, timeout or other GitHub error isn't an expired login. Secrets still go out, without a new token and with a notice; agents on protocol 2 are told to keep the token they have (`keep`), older ones lose it until the retry. The next run of the job retries.
- **Opt-out:** a per-repo setting gives that repo's environments the user's unscoped token. Use it for repos where you regularly work across other projects.
- **When refresh fails:** this happens when the refresh token expires (6 months unused) or is revoked.
  - Environments keep running. There is no fallback to a bot token.
  - Git push and `gh` fail until the user logs back in to Foreman.
  - The UI shows a banner, and the agent writes a notice that new shells print.
  - After the user logs in again, Foreman re-scopes and sends fresh tokens to every running environment that user owns.

### Private container registries

Public images and features, including the Foreman feature, need no credentials. A repo whose devcontainer uses a private image or feature on GHCR does.

GHCR only accepts classic PATs; GitHub App tokens and fine-grained PATs can log in but can't pull. Foreman uses a machine user's classic PAT, and Foreman automates everything around it that it can:

- **First-class setting:** registry credentials (host, username, token) are an owner setting, separate from environment secrets.
- **Validation on save:**
  - Foreman checks that the token's `X-OAuth-Scopes` header includes `read:packages`.
  - It then test-fetches the manifest of every private feature and image referenced by the owner's repos.
- **Expiry tracking:** Foreman reads the token's `GitHub-Authentication-Token-Expiration` header and warns admins 14 days before it lapses.
- **Detection:** if a repo's devcontainer.json references a private `ghcr.io/<owner>/…` feature or image and no credential is set, the repo page links the runbook. The build doesn't run and fail.
- **Agent use:**
  - The agent in the environment's VM supplies the credential to both Docker (image pulls) and its own registry client (feature pulls).
  - It never puts the token on a command line or leaves it on disk. For example, it uses `docker login --password-stdin` into a throwaway `DOCKER_CONFIG` per build.
  - Spike 6 confirms which credential source the CLI reads.
- **Runbook:** `docs/setup/ghcr-machine-user.md` covers:
  - creating the machine user
  - granting it read access to the package
  - creating a classic PAT with only `read:packages`, then pasting it into Foreman

  GitHub has no API for creating PATs, so that step stays manual.

### Git identity and dotfiles

Each user sets defaults for these, and can override any of them for a specific repo. A repo override beats the user default. Any field left unset falls back to the default.

| Setting | How it's delivered | When a change takes effect |
|---|---|---|
| Git name and email | `/run/foreman/gitconfig` | Immediately |
| Dotfiles repo, install command and clone path | `--dotfiles-repository` / `--dotfiles-install-command` / `--dotfiles-target-path` | On the next rebuild, unless HOME is a volume (below) |

The Foreman feature installs an `/etc/gitconfig` that includes `/run/foreman/gitconfig`. The agent writes that file with `user.name`, `user.email` and the credential helper setting.

Because this is git config rather than an environment variable, every process sees it, including editors. Changes apply without a restart.

This replaces the per-repo `git config` and dotfiles steps in `postCreateCommand`.

The CLI clones dotfiles to `~/dotfiles` unless the clone path is set, so dotfiles that expect `~/.dotfiles` need it set. The CLI puts the path in its clone script unquoted, so Foreman only accepts a plain path under `~/` or an absolute one.

The CLI installs dotfiles once per HOME: it skips them while `~/.devcontainer/.dotfilesMarker` exists. A repo that keeps HOME in a named volume keeps the marker across rebuilds, so a dotfiles change only reaches its environments when they're created, or after deleting the marker and rebuilding.

If commits need signing, store an SSH signing key as a user secret.

### Your own devcontainer features

Each user can keep a list of devcontainer features that go on every environment they create, in any repo, without putting them in a shared `devcontainer.json`. Settings takes them in the shape of devcontainer.json's `features` object: an OCI ref and its options.

- **Private:** only that user's environments get them, and only they see them in their settings. Admins see everyone's on the People page, since a feature runs code in the environment.
- **Per repo:** each repo's page has a box per feature; unticking one leaves it out of the user's environments of that repo. The opt-out is by ref without a version, so moving from `:1` to `:2` keeps it off.
- **Delivery:** the command carries them as `features`. The agent adds them to the features it installs besides the repo's (the Foreman feature is one), so they're resolved and installed like the repo's. An error about one names it as "your feature … (from your Foreman settings)".
- **Conflicts:** a feature the repo's devcontainer.json already declares, at any version, is skipped (the operation log says so) and the repo's copy installs. Nothing can use the Foreman feature's id.
- **Refs:** OCI refs only. A local path would resolve against the repo's devcontainer folder, and a tarball URL skips the registry. Tags are accepted and aren't locked: a user feature has no lock file, so each rebuild gets what the tag points to then.
- **Registries:** a build's registry credentials are the repo owner's. A private user feature only pulls if those credentials can read it.
- **When it applies:** on the next rebuild, like dotfiles.
- **Audit:** `user.features` records the refs added, removed and changed, never their options.

## Capacity and resource limits

Foreman never assumes a box has room for everything provisioned on it. By default it reports contention and lets you decide.

### Limits

- **Default:** every environment's VM has a size and a cgroup, even with no limits set: the box's `FOREMAN_VM_CPUS` and `FOREMAN_VM_MEMORY_MB` (4 and 8192), capped at what the box has, and `FOREMAN_VM_DISK_GB` (64) of disk. Before environment VMs the default was no limits at all.
- **Optional limits:** CPU and memory limits can be set per repo as a default, and per environment as an override. When set, they size the VM (see [Environment VMs](#environment-vms)) and nothing inside it: the box keeps them out of the commands it relays to the guest, and the overlay never limits a service. The VM can be smaller than the limit asks for (it's capped at the box's cores), and Docker refuses a container more CPUs than its host has.
- **`hostRequirements`:** never treated as a limit. A repo that asks for 8 CPUs and 8 GB gets a warning when it's placed on a box that has less. On agents that report VM defaults, this check is independent of the allocation.

### Reporting

Each box reports total cores, memory and disk, plus live usage per environment every 30 seconds (`box.stats`). An environment's usage is its VM's, read from the VM's cgroup on the box (`foreman.slice`), which the guest can't touch: CPU over a one-second sample, and memory, which includes what Cloud Hypervisor itself uses. Every 5 seconds the agent also sends host-wide CPU, memory, swap, load and disk (`box.metrics`), read from `/proc` and `df`.

Every 5 seconds the agent also asks each running VM for the TCP ports listening in its devcontainer, and sends `box.ports` when they change and after every join. The guest agent reads them from its VM, not the container: Docker's inspect gives the container's pid in the VM, and `/proc/<pid>/net/tcp` and `tcp6` list the sockets in its network namespace, the one on the tailnet. The box's agent keeps only the report for the VM's own environment; the ports are shown, never acted on. Only listeners Tailscale reaches count: tailscaled runs in userspace mode and hands connections to `127.0.0.1` or `::1`, so a loopback or any-address listener is listed, and one on another address (tailscaled's own proxy on `127.0.0.2`, a compose network) isn't. When the listeners change, the agent names them from the fds of the container's processes (pids from Docker's top). It can only read processes with its own uid and gid, which the devcontainer CLI gives the remote user on Linux, so a listener running as anyone else (root's sshd) shows without a name. The control plane keeps the latest report in memory, and the environment's page links each port at `http://<slug>:<port>`. The event needs no new protocol version: a control plane without it refuses the event, and the agent drops it.

After every join, and whenever it changes (checked every 15 seconds), the agent sends `box.reboot`: whether `/run/reboot-required` exists, the packages listed in `/run/reboot-required.pkgs`, and whether a kernel livepatch is enabled under `/sys/kernel/livepatch` (Livepatch and kpatch both load them there, readable without root). The flag is Debian's convention for a package asking for a reboot: Ubuntu's update-notifier hooks write it for the kernel, libc and the like, and on Debian it's up to each package, so what it catches varies by distribution. A reboot clears it, and so can a Livepatch client that has confirmed the running kernel is covered, depending on its version and settings. The control plane stores the report on the box, shows an alert on the box's page (listing the packages, and noting a livepatch if there is one) and a badge on its cards, and sends an activity notice when a box starts needing a reboot. Like `box.ports`, the event needs no new protocol version.

An admin can reboot a box from its page (`box.restart`, protocol 5). The agent runs unprivileged, so the install script sets up a root path unit, `foreman-restart.path`, that watches `/run/foreman/restart` and reboots the box five seconds after the agent writes it, which leaves the agent time to answer. Environments run in their own VMs and see nothing of the box's `/run`, so nothing in them can ask. The agent reports whether that unit exists (`can_restart`) and the kernel's boot id on `box.reboot`, and the command names the boot the control plane saw: one resent after the reboot finds another boot and does nothing, and the box coming back on another boot finishes the operation whether or not the agent's answer got through. Nothing reboots a box on its own.

On Flatcar, the install script turns off Flatcar's own reboot manager (`REBOOT_STRATEGY=off`) and adds a timer that writes `/run/reboot-required` once update-engine has applied an OS update, with `flatcar-<version>` as the package, so an OS update shows the same way and waits for the same Reboot.

The control plane stores both (`box_metrics`, `env_metrics`, with Unix-second timestamps so bucketing is integer math on SQLite and Postgres) and keeps 7 days; an hourly Oban job (`PruneMetrics`) deletes older rows. Environment samples keep the slug and no foreign key, so a destroyed environment stays on its box's charts until it ages out. Reads are bucketed to about 240 points whatever the range (15 minutes to 7 days). The box page charts CPU and memory as the box total over each environment's share, plus disk and load against the core count, and updates live; the box list shows half-hour CPU and memory trends. Agents older than the metrics event keep working and their charts stay empty.

The UI shows:

- current usage per environment and per box
- **provisioned** CPU and memory for running VMs and pending starts. Protocol 8 agents report capped VM defaults and host capacity on join, and the size recorded at boot in inventory. Cold boots resolve CPU and memory independently from the environment override, repo default, then box default. Each is capped to the host. CPUs round up to whole cores, with a minimum of one CPU and 512 MiB of memory.
- Suspended VMs release their allocation. A resume checks the size saved in the snapshot. If the box reports that its agent or guest image has changed, the snapshot is incompatible and placement uses the cold-boot size. Changing limits changes the next cold boot. Creation, starts, resumes, and increases in cold-boot size use the box's placement policy.
- On protocol 6 or 7 agents Foreman estimates allocation from limits, then declared `hostRequirements`, then a 15-minute usage average. An unsampled VM with none of these counts as zero. Upgrade the control plane before the agent to enable VM size reporting.
- a contention badge when provisioned or observed usage passes a threshold of capacity

### Box policy

Each box has a CPU threshold and a memory threshold, fractions of its capacity (0.9 by default, up to 16 for CPU and 4 for memory). Past 1 overcommits, and the two carry different risks with VMs. An idle VM's vCPUs cost the box next to nothing and a busy one is capped at its size, so CPU overcommit means busy VMs share cores. Memory overcommit means the VMs' touched memory, page cache included, can pass the box's RAM, and with no swap the kernel then kills a VM. A resource is in contention when its provisioned total passes its threshold, or when what's in use passes its threshold or 90%, whichever is lower. Usage can't pass capacity, so without the 90% a box overcommitted on CPU would never show as busy. Placement checks provisioned totals only.

Set per box:

| Policy | Placing an environment beyond capacity |
|---|---|
| `allow` (default) | Shows the contention badge |
| `warn` | Asks for confirmation first |
| `refuse` | Blocks placement |

## Isolation and security model

### What the agent can do

The agent runs unprivileged and isn't in the `docker` group. Its only root actions are the VM helper's fixed vocabulary and the reboot unit. It does own every VM's disks and the box's copy of every environment's secrets, so a compromised agent has every environment on its box. A compromised control plane can't run commands on a box (there's no generic exec), but it can create environments from any repo the GitHub App sees, and it holds their secrets anyway, so the defences sit around the control plane:
- tailnet only
- GitHub login and org membership checks
- a fixed command vocabulary on the agent
- signed agent releases, with the signing key kept off the control plane

The fixed vocabulary limits what an attacker can do, but it doesn't make `env.create` safe. Creating an environment from a repo runs that repo's Dockerfiles and lifecycle hooks, now inside a VM of its own.

### The VM as the boundary

The guest is hostile: anything running in an environment (a dependency's install script, a coding agent following injected instructions) can take its VM over, root included. What it can reach from there:

- **The box:** only through Cloud Hypervisor's emulated devices (disks, network, vsock, balloon, serial), run as the agent's user with no capabilities, under seccomp and Landlock, in a cgroup with CPU, memory and task limits; and the vsock channel to the box's agent, which treats every frame as hostile.
- **The network:** the internet through the box's NAT, and the box's LAN unless the box blocks it. Not the box itself, not other VMs, not the tailnet as the box (see [An environment VM's network](#an-environment-vms-network)).
- **Other environments:** nothing. Every guest has the same vsock CID with no path between them, a tap of its own with no shared segment, and its own disks.

Secrets reach a guest only as files for its own environment.

### Docker inside an environment

Privileged containers and docker-in-docker work, and so do host namespaces, devices and seccomp turned off: inside a VM, the "host" is the environment's own guest, so those reach that environment and nothing else. `initializeCommand` runs too, in the VM.

Until environments moved into VMs (2026-11-16), environments ran on the box's shared Docker and had to be unprivileged. A privileged container was root on the box: it could mount the host's disks, load kernel modules, and read every environment's secrets and the agent's key. So the agent checked every compose file, `devcontainer.json` and feature on every start and refused privileged containers (the `docker-in-docker` feature included), host namespaces, the Docker socket, host binds and devices, and the overlay put every network on an `fm-` bridge the firewall knew. A box could loosen a rule with `FOREMAN_POLICY` and was shown with a red alert. Repos were told to move services into compose sidecars, image builds to a remote builder or CI, and image handling to `crane` or `skopeo`. That policy (`ForemanAgent.Env.Policy`, `ComposeScan`, `FOREMAN_POLICY`) is gone: with the VM as the boundary its rules protected nothing.

**Considered then, and superseded by environment VMs:** one Incus system container per developer per box, with `security.nesting=true`, its own dockerd and a Foreman agent inside it, deferred until boxes were actually shared.

**Ruled out as ways to make privileged Docker safe on a shared box:**

| Option | Why |
|---|---|
| Sysbox | Incompatible with `--privileged` and therefore with the official `docker-in-docker` feature; open nested-buildx breakage on Docker 28.5+ ([nestybox/sysbox#973](https://github.com/nestybox/sysbox/issues/973)) |
| Podman | The agent's devcontainer code is written for Docker, BuildKit and Compose (and the devcontainer CLI's own compose + features on Podman was broken, [devcontainers/cli#863](https://github.com/devcontainers/cli/issues/863)) |
| Kata / Firecracker | No network namespace sharing, so `network_mode: service:x` fails; Docker 28 broke Kata networking |
| Rootless Docker | Nested privileged dind is unverified, and Ubuntu 24.04's user namespace restrictions get in the way |

### Secrets exposure on a box

Code in an environment can't read another environment's secrets: they're in another VM. Root on the box, or anything running as the agent's user, can read them all: the agent keeps every environment's latest files on the box's tmpfs to write into its VM after a boot, and every VM's disks are the agent user's. On a box that also runs Docker, Docker access is root. On a team, that is a reason to keep boxes single-owner and to treat any access grant to another developer as a trust decision.

## Agent self-update

1. CI builds the agent release for each target architecture on a tag. It signs it with an ed25519 key that lives only in CI (`mix foreman_agent.sign`; the signature covers the version, target and SHA-256), builds the control plane images with the signed tarballs inside, and attaches the tarballs and signatures to a GitHub release. A control plane registers the agents its image carries at boot, checking each signature, and keeps the ones it already had. `scripts/publish-agent-release.sh` registers a GitHub release's agents by hand; the control plane only asks GitHub which release is newest, and never downloads agents from it.
2. A box follows the newest agent its control plane's image carries (for an image that carries none, the newest registered), unless an admin pins it to a version registered for its architecture. New boxes install the same version. A box whose agent runs another version receives `agent.update`.
3. The agent downloads the release from the control plane and verifies the signature against the public key compiled into it.
4. It unpacks to `/opt/foreman-agent/releases/<version>`, switches the `current` symlink (keeping the old target as `previous`) and writes an `update-pending` marker. It exits once nothing else is running and every result has been acknowledged (waiting up to an hour), and systemd restarts it on the new version. An update to the version already installed does nothing, and only one update runs at a time.
5. When the new version joins the control plane it clears the marker and `previous`. If it crash-loops, a systemd `OnFailure` unit switches the symlink back; if it runs but hasn't joined within five minutes, the agent rolls itself back and exits.
6. The control plane sends no new update while one is in flight or while the box's environments have operations running. An update counts as done only when the box rejoins on the new version, and as failed ten minutes after it was sent with no answer, or 70 minutes after the agent said it would restart (it can wait an hour for idle). After two failures in a row of the same version on a box, that version isn't sent to it again until an admin retries it from the box's page or picks another version.

Environments keep running throughout: each VM runs in a systemd unit of its own, not as a child of the agent, and the agent finds its VMs again when it starts. A running VM keeps the agent it booted with (its agent disk); its next boot gets the box's new one. Erlang hot code upgrades are not used.

The guest image isn't signed like the agent: each amd64 agent is built with the image's URL and SHA-256, so the signature on the agent covers which image it boots, and the agent checks the download against that digest.

An agent update can't change what the install script set up as root (the VM helper, the firewall, the units). An agent that needs a newer helper or firewall says so, the box's page shows it, and the install script has to run on that box again.

## Repo conventions

What a repo needs to work well under Foreman:

- **Required:**
  - A compose-based devcontainer.
  - No bind mounts to host paths outside the repo. The host is the environment's VM, which has none of your files.
- **Allowed** since environments moved into VMs: privileged containers and the `docker-in-docker` feature. See [Docker inside an environment](#docker-inside-an-environment).
- **Remove:**
  - Repo-level Tailscale setup: install scripts, `tailscale-up.sh`, `TS_*` settings, the authkey mount, and `cap_add`/`devices` added only for Tailscale. The Foreman feature replaces all of it.
  - `env_file` entries pointing at gitignored files. Those values become Foreman secrets.
  - Dotfiles, git identity and SSH `authorized_keys` setup in `postCreateCommand`. Foreman covers them.
  - The `sshd` feature and any published SSH port. Tailscale SSH replaces them.
- **Only if spike 1 falls back to opt-in:** list a gitignored `foreman.compose.yml` in `dockerComposeFile`.
- **Optional:** `ports:` can stay. The overlay strips them anyway.

## Data model (sketch)

- `users`: GitHub id and login, encrypted user and refresh tokens, role, default git identity and dotfiles, and their own devcontainer features (ref => options).
- `user_repo_settings`: user, repo, and optional git name, git email, dotfiles repo, dotfiles install command and dotfiles clone path. Unset fields fall back to the user's defaults. Also the user's features turned off for the repo, by ref without a version.
- `owners`: GitHub org or user account, plus installation id and the extra repos all of its repos' tokens reach.
- `repos`:
  - owner, full name, default branch, devcontainer path
  - token mode (`scoped` / `broad`), extra repos, token permissions
  - Tailscale tags
  - default CPU and memory limits
- `secrets`: scope (`owner` / `repo` / `user` / `environment`), scope id, name, encrypted value, optional repo selection for user secrets, updated by, updated at.
- `boxes`:
  - name, owner user, agent public key
  - agent and protocol version, desired version
  - capacity, capacity policy, sharing grants, last seen
  - whether it can run environment VMs (`vm`: ready or why not, nested, reflink), the firewall and reboot reports
- `environments`:
  - repo, user, box, branch, slug, index
  - desired state, observed state
  - CPU and memory limits
  - applied secrets hash, Tailscale device id
- `operations`: op id, environment, command, status, timestamps, log pointer.
- `agent_releases`: version, architecture, sha256, signature.
- `audit_events`

## Codebase layout

A monorepo with separate Mix projects. Not an umbrella, because the control plane and the agent ship on their own schedules.

```
apps/
  foreman/          # Phoenix control plane
  foreman_agent/    # agent release
  foreman_protocol/ # shared message structs and validation, path dep of both
features/
  foreman/          # the devcontainer feature (shell + devcontainer-feature.json)
guest/              # the guest system image environment VMs boot (kernel and root filesystem)
docs/
```

### Testing

- `foreman_protocol` gets contract tests, so the control plane and agent agree on every message.
- The agent's Docker calls, and bringing a devcontainer up, sit behind behaviours, with fakes for unit tests. The devcontainer code's own tests compare what it generates with files the devcontainer CLI wrote for the same project (`test/fixtures/devcontainer/oracle`). VMs sit behind one too (`ForemanAgent.VM.Machine`), with a fake machine that runs a guest agent in the test node over a stand-in for vsock.
- Integration tests against real Docker are tagged `:docker` and run on a Linux box or in CI. They drive the environment code a guest agent runs.
- `e2e/guest/run.sh` boots the guest image under Cloud Hypervisor; `e2e/vm/run.sh` runs environment VMs for real on a throwaway machine with KVM; `e2e/vmctl/test.sh` checks the root helper with stand-ins.
- Control plane tests use a fake agent that joins the Channel.

## Decisions

Locked in on 2026-10-13.

| Topic | Decision |
|---|---|
| Code layout | Monorepo of separate Mix projects |
| Overlay fallback | If `--override-config` can't add the overlay, repos opt in with a gitignored `foreman.compose.yml` |
| Restart after a secrets change | Restart affected, Restart all, or Later. Rebuild is a separate action. |
| Tailscale startup | Foreman feature entrypoint |
| SSH | Tailscale SSH, ACL action `accept` |
| Expired GitHub login | Warn and keep running. No bot-token fallback. |
| Contention for environments without limits | Box VM defaults for cold boots and reported boot size for running or saved VMs |
| Box overcommit | `allow` by default; `warn` and `refuse` are per-box options |
| Git identity and dotfiles | User defaults with per-repo overrides |
| Incus isolation | Deferred until boxes are actually shared. Superseded on 2026-11-16 by environment VMs. |
| GHCR (private images) | Machine-user classic PAT as a first-class registry credential, validated on save, expiry tracked, with a runbook |
| Environment isolation (2026-11-16) | A Cloud Hypervisor VM per environment, shared Docker and its compose policy removed with no fallback, Mac boxes dropped until [#180](https://github.com/ntodd/foreman/issues/180). See [design/vm-environments.md](design/vm-environments.md). |

## Spikes

These are facts to confirm during build steps 1–2, not decisions.

1. **Overlay:**
   - Does `--override-config` work with an appended `dockerComposeFile` entry that uses an absolute path?
   - Does `ports: !reset []` behave in the merged overlay?
2. **Restart flow:** does `devcontainer up` on a stopped container run `postStartCommand` without recreating it?
3. **Feature entrypoint:** does it run again after `docker restart` under compose?
4. **Tailscale SSH:**
   - Can you log in as the devcontainer's `remoteUser`?
   - Does it work under the userspace-networking fallback?
5. **Scoped token lifetime:** expected to be at most the parent token's 8 hours.
6. **Feature pull credentials:** does the devcontainer CLI's registry client read the Docker config, or does it need its own credential source?

## Build order

1. **Spike, no UI or agent:** a Mix task that clones a sample repo, writes the overlay and override config, adds the Foreman feature and runs `devcontainer up`. Done when two copies run side by side on the tailnet. This answers spikes 1–4.
2. Run the same spike on a repo coming off Codespaces to surface Codespaces-specific behaviour and answer spike 6.
3. Control plane and local agent over a Channel, with a LiveView environment list, start/stop and log streaming.
4. Secrets: scopes, Cloak, file delivery, restart now or later.
5. GitHub App: login, repo browsing, scoped tokens, credential helper.
6. Capacity reporting, limits and box policy.
7. Remote agents: enrollment, signed self-update.
8. Team rollout:
   - registry credentials and the GHCR runbook
   - per-developer Tailscale tags
   - migrating the team's repos off Codespaces
9. Incus isolation, only once shared boxes happen. (Superseded: environments run in VMs of their own; [design/vm-environments.md](design/vm-environments.md) has that build's order.)

## Prior art

| Project | State (Oct 2026) | Why not just use it |
|---|---|---|
| Coder (Community) | Active. Its agent dials out, and it runs devcontainers through `@devcontainers/cli` | Running on boxes you already own needs Premium (or an SSH-Docker template workaround). No owner or repo secrets; user secrets are a 2.34 beta, and encryption at rest is Premium. Templates are Terraform. |
| DevPod | Upstream stalled since 2025. The community fork points to Devsy | No control plane or secrets model |
| Gitpod / Ona | Self-hosted is dead. Being acquired by OpenAI | Gone |
| Daytona | Pivoted to AI sandboxes; source closed | Gone |

## Implementation notes

Written after building v1 on 2026-10-13. Where the build differs from
the plan above, the build wins.

### Spike results

| Spike | Result |
|---|---|
| 1. Overlay through `--override-config` | Works: absolute `dockerComposeFile` paths plus the overlay, and `ports: !reset []` strips published ports. The repo-opt-in fallback isn't needed. Local features resolve against the repo's `.devcontainer`, hence the copy described under "Foreman feature". |
| 2. `up` on a stopped container | Reuses the container, starts the whole project and runs `postStartCommand`. Start is `devcontainer up`. |
| 3. Feature entrypoint after `docker restart` | Runs again. |
| 4. Tailscale SSH | Not tested: no tailnet in the build environment. The feature installs and starts Tailscale; joining needs a real OAuth client. |
| 5. Scoped token lifetime | Not tested against GitHub (no app in the build environment). Tokens are re-scoped every four hours regardless. |
| 6. Feature pull credentials | The agent sets `DOCKER_CONFIG` for the CLI process, which both Docker and the CLI's OCI client read. Not tested against a private package. |

### Differences

- **Database:** SQLite by default, Postgres optional, chosen at compile
  time (`FOREMAN_DB`), because Ecto fixes a repo's adapter when it
  compiles. Migrations use only the portable DSL; the suite passes on
  both.
- **Dispatch:** the operations table is the queue. A per-environment
  process (started on demand) sends one operation at a time; a
  minute-by-minute sweep catches anything queued from elsewhere.
  In-flight operations are resent with the same op_id on reconnect, with
  a fresh secrets write ahead of any start (a reboot clears the tmpfs).
  - Queued secrets writes go before anything else in an environment's
    queue. The last click wins: queuing Stop cancels a queued Start and
    the other way round, and Destroy cancels everything queued.
  - An operation's result and its effect on the environment are written
    in one transaction. A failed or cancelled stop or destroy puts the
    environment back where it was, with the error shown.
  - Reconcile on join only steps aside for start, stop and create-type
    operations, so a queued secrets write or log fetch can't leave an
    environment down after a reboot.
  - Housekeeping gives up on an operation after three hours (box
    commands after ten minutes, a `box.gc` after two hours) and sends `op.cancel` to the box; it
    skips offline boxes, whose work is resent on reconnect. A real result
    arriving later still wins.
  - Destroying an environment on a revoked box marks it destroyed without
    the agent, and audit-logs it.
  - Logs of operations finished more than 30 days ago are cleared; the
    rows stay.
  - On SQLite, transactions start `IMMEDIATE`, so one that reads and then
    writes waits for other writers instead of failing with "database is
    locked".
- **Secrets on the box:** 0600 files in a 0700 tmpfs directory, owned by
  the agent user. On Linux the agent maps the container's remote
  user to its own uid, so the environment can read them. Since
  environment VMs, that's the guest agent's user and the VM's tmpfs; the
  box keeps its own copy, which no environment sees.
- **Redaction:** secret values are scrubbed from operation logs and
  errors by both the agent and the control plane (the CLI logs the
  merged compose config with interpolated values).
- **Compose policy (removed 2026-11-16):** the agent checked the merged
  compose config, `devcontainer.json` and the features the CLI resolves
  (with `devcontainer read-configuration --include-merged-configuration`)
  on every start, and refused privileged containers, host namespaces,
  host binds, host files, the Docker socket and devices unless the box
  opted out. Agents reported their policy on join. Environment VMs made
  it pointless; see [Docker inside an environment](#docker-inside-an-environment).
- **`initializeCommand`** was dropped, because it would have run on the
  box. Since environment VMs it runs, in the VM.
- **Restart affected:** recreates the non-devcontainer services that
  interpolate a changed variable, then stops and re-`up`s the
  devcontainer service (entrypoint and `postStartCommand` run again). If
  the devcontainer service itself interpolates a changed variable, the
  CLI recreates it.
- **Destroy:** a git status check runs inside the container first; with
  uncommitted or unpushed work, the UI asks for the environment's name.
- **Control plane self-update:** the control plane checks GitHub's
  releases every five minutes. An admin's click writes the version to a
  directory shared with the host, where `foreman-update` (a root script
  run by a systemd path unit) pulls it, backs up the data volume,
  recreates the container and rolls back if `/healthz` never answers.
  The container has no Docker socket; a newer version number is all it
  can ask for. See [security.md](security.md#the-control-plane-and-its-host)
  and `e2e/updater/run.sh`.
- **Not built yet:** idle auto-stop, per-service limits for sidecars,
  webhooks (repos are polled). From the VM design: prebuilds that refresh
  themselves, new environments from a memory snapshot, resizing a VM, environment VMs on arm64, Flatcar on metal
  tested ([#179](https://github.com/ntodd/foreman/issues/179)), and Mac
  boxes on Apple's hypervisor ([#180](https://github.com/ntodd/foreman/issues/180)).
