# Security model

What Foreman protects, where the trust boundaries are, what defends each
one, and what it knowingly doesn't. Written to be red-teamed: the "Known
gaps" section is the place to start.

## What's worth stealing

| Asset | Where it lives |
|---|---|
| Environment secrets (owner, repo, user, environment) | Control plane DB, encrypted (AES-256-GCM, Cloak); on boxes in `/run/foreman/envs/<id>/` (tmpfs, 0600, agent user), and the same path in the environment's VM |
| GitHub user access and refresh tokens | Control plane DB, encrypted |
| Scoped GitHub tokens | With the secrets, as `github-token` |
| GitHub App private key and client secret | Control plane DB (encrypted) or its environment |
| Tailscale OAuth client secret | Control plane environment |
| Registry (GHCR) tokens | Control plane DB, encrypted; in an environment's VM only during a build |
| `FOREMAN_ENCRYPTION_KEY`, `SECRET_KEY_BASE` | Control plane environment |
| Agent private keys | Each box, `/var/lib/foreman-agent/identity.json` (0600, agent user) |
| Environments' work (the clone, Docker volumes, Tailscale state) | Each VM's data disk, `/srv/foreman/vms/<id>/data.raw` on the box (agent user) |
| The boxes themselves | The agent runs unprivileged; its root actions are the VM helper's fixed vocabulary and the reboot unit |

## Trust boundaries

### People and the control plane

- The control plane listens on loopback (or a tailnet address) and is
  served to the tailnet by `tailscale serve`. It isn't meant to be on
  the internet.
- Sign-in is GitHub only, through the app's OAuth flow with PKCE and a
  `state` check. Who may sign in: `FOREMAN_ADMINS`,
  `FOREMAN_ALLOWED_USERS`, active members of `FOREMAN_ALLOWED_ORG`.
  That holds for admins too: an admin dropped from all three is
  refused, whatever role their record has. The one exception is a
  deployment with neither `FOREMAN_ADMINS` nor an org set, where admins
  are managed in the UI and an existing admin may sign in. Who may sign
  in is checked again at every GitHub token refresh and every six hours
  for anyone with a live session; a definite "no" ends their sessions
  and drops their GitHub tokens (their environments keep running without
  one), while a GitHub error changes nothing. GitHub answers "not a
  member" with a 404, which it also gives for an org it can't find, so a
  404 only counts once the org itself resolves. Someone whose GitHub
  login has expired can't be checked against the org, so they're signed
  out and checked when they sign in again. Accounts are matched by GitHub id; a
  login only matches a record that has no GitHub id yet, so someone who
  takes a renamed user's old login doesn't get their account.
  Sign-in attempts are rate limited per client. Behind a loopback proxy
  (`tailscale serve`) the client is the last `X-Forwarded-For` entry;
  that header is ignored from any other peer, except those in
  `FOREMAN_TRUSTED_PROXIES`. The image trusts its default gateway, which
  is where connections to the port Docker publishes on the host's
  loopback come from; without that, every client behind the proxy
  shared one limit.
- Sessions: a random 32-byte token in an encrypted, signed, `HttpOnly`,
  `SameSite=Lax` cookie (`Secure` in production); only its SHA-256 is
  stored, so a database leak doesn't leak sessions. Sessions last 30
  days and die when a user is disabled. Disabling a user or changing
  their role also drops their open pages, so a LiveView can't keep old
  powers. The session is renewed at sign-in.
- Every page sends a CSP with no inline scripts or style attributes
  (`script-src 'self'; style-src 'self'`; Oban Web's pages need inline
  styles and get that one exception), `frame-ancestors 'none'`,
  `X-Frame-Options: DENY` and, over HTTPS, HSTS. Forms may post only to
  the app and to github.com (the GitHub App manifest).
- Authorization is by scope: members see and act on their own
  environments, boxes they own or that are shared with them, and their
  own secrets. Owner and repo secrets, repo settings, boxes, people and
  deployment settings are admin only. Admin pages 404 for members.
- Secrets are write-only: the UI and every context function return
  secrets without values. The audit log records names, never values.
- First run: until a GitHub App exists, `/setup` needs a one-time
  token printed in the boot log.

### Agents and the control plane

- Agents dial out; boxes need no inbound ports.
- Enrollment spends a single-use join token (random 32 bytes, stored
  hashed, valid for an hour, created by an admin). The agent generates
  its own ed25519 keypair; only the public key leaves the box.
- Every socket connect is signed: agent id, a timestamp and a random
  nonce, signed with the agent's key, in `x-foreman-agent-*` headers.
  The control plane refuses unknown or revoked agents, bad signatures,
  clocks more than 60 seconds off, and nonces it has seen in the last
  two minutes. Refused connects are rate limited per client (600 a
  minute), so junk from one address can't lock out signed agents.
  Revoking a box deletes its key and drops its socket.
- No distributed Erlang anywhere (`RELEASE_DISTRIBUTION=none`): a
  connected Erlang node can run arbitrary code on its peers.
- A fixed command vocabulary, no generic exec. Every command and event
  is validated by `ForemanProtocol` on both sides, with types as narrow
  as their use: slugs are DNS labels, env ids UUIDs, branch names can't
  start with `-`, clone URLs can't carry credentials, secret file names
  come from an allowlist, compose variables can't override `PATH`,
  `DOCKER_HOST` and the like, or set anything that loads code into the
  agent's own tools: any `LD_` variable, `GCONV_PATH`, `NODE_PATH`, git
  config through the environment (`GIT_CONFIG_*`) and git's helper
  commands and trace files.
- An agent may only report on its own box's operations and
  environments; anything else is refused and logged.
- Agent self-update: the release signature (ed25519 over version, target
  and SHA-256) is checked against the public key compiled into the
  running agent, before downloading; the digest after. Tarball paths
  that escape the release directory are refused. The signing key lives
  only in CI, so a compromised control plane can't push agent code. A
  failing new release is rolled back by a systemd `OnFailure` unit.
  The release carries the devcontainer CLI and the Node it runs on
  (Node's official build, pinned by digest; the CLI from a lockfile) and
  Cloud Hypervisor (its static build, pinned by digest), so the
  signature covers them too, and a box runs no Node of its own. An amd64
  release is built with the guest image's URL and SHA-256, so the
  signature covers which image its VMs boot: the agent checks the
  download against that digest, and unpacks only the three plain files
  the image is made of. `FOREMAN_GUEST_URL` and `FOREMAN_GUEST_SHA256`
  in the agent's settings (root's file) override both.
- Rebooting a box (`box.restart`, an admin's button): the agent can't
  reboot anything itself. It writes `/run/foreman/restart`, which a root
  path unit the install script set up watches, and that unit reboots
  the box. The file is in the agent's runtime directory on the box, and
  environments run in VMs that see none of the box's files, so nothing
  in an environment can write it. The command names the boot it's for, so a stale or replayed
  one doesn't reboot the box again. A compromised control plane can
  reboot boxes, which it could already disrupt in plenty of ways.

### The box and its environment VMs

Every environment runs in a Cloud Hypervisor VM of its own
([architecture.md](architecture.md#environment-vms)), and the guest is
hostile: anything running in an environment can take its VM over, root
included. Nothing the guest says is trusted, and its limits are set on
the box.

- The agent on the box runs as the unprivileged `foreman` user, outside
  the `docker` group. What needs root goes through `foreman-vmctl`, a
  root helper the install script puts in `/etc/foreman-agent/vmctl`
  (root's, so the agent can't change it), on a socket only the `foreman`
  group can use. It reads one request line of at most 200 characters
  (lowercase letters, digits, spaces, dots and dashes) and knows five
  requests: `version`, `start`, `restore`, `stop` and `release`. Each
  takes an environment id (a UUID) and sizes or versions checked against
  fixed patterns, never a path or a command line. Every path is a fixed
  place under `/srv/foreman` or the agent's install, a disk or kernel
  that isn't a plain file is refused, and it builds Cloud Hypervisor's
  command line itself.
- Each VM runs in a systemd unit of its own, `foreman-vm-<env_id>` in
  `foreman.slice`, as the agent's user with the `kvm` group: no
  capabilities, `NoNewPrivileges`, a read-only system apart from the VM's
  directory, `/dev/kvm` and `/dev/net/tun` as its only devices, and
  limits on CPU, memory (the guest's plus 512 MB, no swap) and tasks.
  Cloud Hypervisor puts a seccomp filter on every thread, and Landlock
  keeps it to the VM's directory, the guest image, the agent disk and
  its tap. A box whose kernel can't apply Landlock (Linux 6.2 or later,
  with `landlock` in its LSM list) runs no VMs: the helper refuses them
  and the box reports why. A guest reaches the box only through
  the devices Cloud Hypervisor emulates (disks, network, vsock, balloon,
  serial console): there's no shared filesystem and no device
  passthrough.
- The channel to the guest agent is Cloud Hypervisor's hybrid vsock, and
  only the box connects: nothing on the box listens for a guest. Frames
  over 4 MiB close the connection. Anything that isn't a valid hello,
  event or reply is dropped, an event only reaches the operation it
  names, and inventory and ports replies only count for the VM's own
  environment, under the slug the box knows it by. The box's agent
  scrubs a command's secret values from the logs and errors the guest
  sends back, as it does for its own commands. Every guest has the same
  vsock CID and no path to another.
- The guest agent holds nothing its environment doesn't already have:
  its secrets, its clone and its containers. It runs as its own user in
  the VM, in Docker's group, with `CAP_SYS_TIME` (the box sets the
  guest's clock) and nothing else, and refuses the box's own commands
  (updates, reboots).
- Each VM has its own copy of the guest's root disk and its own data
  disk. The agent disk (the box's agent release) is shared and
  read-only.
- A guest reaches the internet and, unless the box was installed with
  `--block-lan`, the box's LAN, and nothing else: not the box, not
  another guest, not the tailnet as the box. See
  [Environments and the tailnet](#environments-and-the-tailnet).

### Flatcar boxes

A Flatcar box ([flatcar.md](setup/flatcar.md)) sets itself up from a
first-boot config the control plane makes for a join token:

- The config holds the join token and the box's Tailscale key: a
  single-use, pre-authorized key, tagged `tag:foreman-box`, minted once
  per token and stored encrypted with it, and expiring with the token
  (the box has to boot before the token expires anyway). Enrolling
  clears it from the token. The box deletes the token, the key and the
  config once it has enrolled, and the launcher deletes its copy. Downloads of the config are no-store, and its endpoint takes
  the join token like enrollment does: a bad one counts against the
  client's enroll attempts.
- The config's extensions (Compose, Tailscale) are checked against
  digests pinned in Foreman. Their updates come from Flatcar's sysext
  bakery over HTTPS, checked only against the bakery's own SHA256SUMS:
  trusting the bakery is trusting Flatcar's builds, as the OS itself
  does.
- The launcher, `vm.sh`, pins what it downloads: Flatcar's image and
  kernel against the digests in its signed release files.
- As a VM, a box is a second boundary: code that escapes an
  environment's VM lands in the box's VM, not on the machine running it.
  QEMU runs as the `foreman-box` user under systemd's sandboxing (no
  capabilities, a read-only system, `/dev/kvm` and the box's directory
  and nothing else) with QEMU's seccomp sandbox, and user-mode
  networking without IPv6. Environment VMs run nested inside it.
- The VM's gateway is the machine it runs on, and under QEMU's user-mode
  network the gateway's address reaches that machine's loopback, where
  services expect only local clients. On a Flatcar box that is a VM, the
  install script adds a table to the box's firewall that rejects
  environments' traffic (and image builds' on the box's own Docker) to
  the gateway, DNS aside.
  A box on another Linux in a VM doesn't get it: its environments may
  use something on the gateway. The box itself still
  reaches it, which a control plane on the same machine relies on, so
  code that gets root in the box can too.
- The box's own tailnet node is governed by the tailnet policy like any
  machine's; give `tag:foreman-box` the control plane and nothing else.

### The control plane and its host

The control plane runs as an unprivileged user in its container, with
no Docker socket. Updating it from the Deployment page goes through
`foreman-update` on the host, which runs as root
([upgrading.md](setup/upgrading.md#from-the-deployment-page)):

- The container writes to one directory, `/var/lib/foreman-update/request`,
  and reads the updater's status from another, mounted read-only. It
  can't touch the backups, the updater or its config.
- The updater reads at most a line from `request/version`, never through
  a symlink, and never repeats what it read. It acts only on an `X.Y.Z`
  newer than the running version, pulled from the repository the running
  image came from. So a compromised control plane can ask for a newer
  release, or nothing: not another image, not a downgrade, not a command.
- The updater replaces itself with the copy in the new image, read from
  the pulled image and not the running container, which the control
  plane could have changed. The copy in the image is root's.
- Images aren't signed. The updater trusts the registry as `docker
  compose pull` does; anyone who can push a release image to it can run
  code as the control plane, the same as for an upgrade by hand.

### Repo content and the box

The repo, and anything running in an environment, is treated as hostile
to the box it runs on (up to the limits in "Known gaps"). The wall
between them is the environment's VM ([above](#the-box-and-its-environment-vms));
inside it, the environment can do as it likes.

- Commands are run with an argv, never a shell string, and with a clean
  environment, so nothing from the agent's own environment (like its
  join token) reaches a child.
- Clone hosts are allowlisted per box (`github.com` by default); plain
  HTTP needs an explicit opt-in per host. The box passes its list to the
  guest agent, which clones. The GitHub token reaches git through a
  credential helper reading a file, never the URL or `.git/config`.
- The workspace is writable from inside the environment, so the guest
  agent never follows a symlink out of it (`ForemanAgent.SafeFS`): reads
  resolve symlinks only inside the clone, writes replace rather than
  write through a symlink, and directories it creates refuse symlinked
  parents. The box's agent never reads the workspace.
- Privileged containers, docker-in-docker, host namespaces, devices,
  binds of the VM's paths and seccomp turned off are all allowed:
  they're the environment's own VM's, which holds that environment and
  nothing else. `initializeCommand` runs too, in the VM.
- Until environments moved into VMs (2026-11-16), they ran on the box's
  shared Docker, where a privileged container was root on the box. The
  agent then checked every compose file, `devcontainer.json` and feature
  on every start and refused privileged containers, host namespaces,
  the Docker socket, host binds and files, devices and unreviewed
  compose keys, put every network on an `fm-` bridge the firewall knew,
  and dropped `initializeCommand`. A box could loosen a rule with
  `FOREMAN_POLICY`, shown in red in the control plane. All of that
  (`ForemanAgent.Env.Policy`, `ComposeScan`) is gone: inside a VM those
  rules protected nothing.
- The overlay still strips published ports. Nothing outside the box can
  reach a guest's ports anyway; Tailscale is how people reach an
  environment.
- git status before a destroy runs inside the container, not as the
  agent (a repo's `.git/config` can name programs to run).
- Secrets: on the box, a tmpfs directory per environment, 0700, files
  0600, owned by the agent user, which no environment sees. The agent
  writes them into the environment's VM after every boot and with every
  change, to the same layout on the VM's tmpfs, bind-mounted read-only
  at `/run/foreman`. The devcontainer CLI gives the container's user the
  guest agent's uid, so the environment reads them. Inside the
  environment, the container's own environment (which can include
  compose-interpolated secrets) is saved to `/etc/foreman/container.env`,
  mode 0644, so SSH shells get it; any user in that container can read
  it.
- Secret values are kept out of logs twice: the agent scrubs every value
  a command carried from its output and errors (and drops the CLI's
  compose-config dumps; a crash is reported only by its exception type),
  on the box as well as in the VM; the control plane scrubs the environment's
  resolved secrets from every log chunk and error before storing or
  showing it, which covers container logs the agent had no values for.
- Registry credentials go to a throwaway `DOCKER_CONFIG` in the VM for
  one build, never argv, and are deleted afterwards.
- Connect hooks ([connect-hooks.md](setup/connect-hooks.md)) are code
  from the environment, so the agent runs them inside the devcontainer
  as its remote user, with a timeout inside the container as well as on
  `docker exec` (stopping `docker exec` doesn't stop what it started). It takes only a hook name and an
  action id that are short lowercase names, and holds what they print
  to a few short single-line fields (`ForemanProtocol.Connect`), checked
  again by the control plane. A hook's result is usually a credential
  for the environment (a pairing code). The agent keeps everything an action prints
  out of the operation's log and its error, except a short
  `{"error": ...}` the hook writes for that purpose. The
  control plane takes it out of the result before recording the
  operation and broadcasts it only to the page that asked. Only the
  environment's owner can run an action, not an admin, and the audit
  log records the hook and action, never the result.

### Environments and the tailnet

Each environment is a tailnet node tagged `tag:foreman-env` (plus repo
tags, and `tag:foreman-<login>` on team deployments). The suggested ACL
in [setup/tailscale.md](setup/tailscale.md) grants people access to
environments and grants environments nothing, so an environment's node
can't reach laptops or other environments. Tailscale SSH replaces sshd;
no ports are published.

That node isn't the only way out. A VM's ordinary traffic is routed
through the box, and a box on the tailnet sends tailnet addresses over
its own Tailscale interface, so peers would see the box and apply the
box's grants. The box's firewall (nftables, loaded by
`foreman-firewall.service`, see
[setup/tailscale.md](setup/tailscale.md#boxes-on-the-tailnet)) has a
table for guests, `inet foreman_guests`, that works on each VM's tap
(`fm-vm<n>`):

- nothing from a guest reaches the box itself, on any of its addresses,
  apart from replies to the box's own connections
- nothing goes from one guest to another
- nothing a guest sends goes to the tailnet (`100.64.0.0/10`),
  MagicDNS included; guests get the box's upstream resolvers instead,
  never a loopback or tailnet one
- a guest sends only from its own address: anything that wouldn't be
  routed back through its tap is dropped, and IPv6 is dropped
- nothing outside the box starts a connection into a guest
- with `install.sh --block-lan`, nothing goes to RFC 1918 or link-local
  addresses (the LAN, a cloud instance's metadata endpoint), DNS aside

What's left goes out through the box's NAT. The box's other table,
`inet foreman`, also rejects anything arriving on an `fm-` interface,
or on Docker's default bridge on a box that has Docker, bound for the
tailnet, the box's own tailnet addresses or `tailscale0`. The agent
reports whether the firewall is loaded, and from the rules it ships
with, when it joins and whenever that changes; the control plane flags
a box without it. Something that flushes the box's whole ruleset
removes the firewall until its timer loads it again (within 15
seconds), and in that window nothing keeps guests in. A machine on the
LAN that an environment can reach and that connects onward (a proxy,
say) connects with its own access, tailnet included.

Tailscale runs in userspace mode, without a TUN device or `NET_ADMIN`.
In that mode it delivers tailnet connections to `127.0.0.1:<port>` in
the environment, so anything listening on localhost there (a debugger,
an admin port) is reachable by every peer the ACL lets reach the
environment. Its outbound proxy listens on 127.0.0.2 for that reason.
Grant `tag:foreman-env` only to the people whose environments they are.

## Known gaps

These are accepted for now, or need someone to try them:

1. **A compromised agent has every environment on its box.** The agent
   is no longer root in all but name: it's out of the `docker` group, and
   its root actions are the VM helper's fixed vocabulary and the reboot
   unit. It does own every VM's disks (the clones, Docker volumes and
   Tailscale state), the box's copy of every environment's secrets, and
   its key, which can ask the control plane for the secrets of every
   environment placed on the box. Every VM runs as the agent's user too
   (see 17). A box belongs to one person.
2. **Container root reads 0600 files.** Root in a container has
   `CAP_DAC_OVERRIDE`, so it reads the secrets directory regardless of
   ownership. That's the environment's own secrets, by design, but also
   means "0600" isn't a boundary inside the environment.
3. **Secrets in `ps` in the VM.** The devcontainer CLI puts probed
   environment variables (which include sourced secrets) on the
   `docker exec` command line during lifecycle hooks
   (devcontainers/cli#1317). That runs in the environment's VM, so the
   box's process list doesn't show them, but anything in the VM that
   can see its processes can read them with `ps`. They're that
   environment's own secrets.
4. **Symlink races.** `SafeFS` resolves symlinks, then acts. A process
   in the environment racing the guest agent could swap a directory for
   a symlink between the check and the copy of the feature into
   `.devcontainer/.foreman`. That happens inside the environment's own
   VM, where the guest agent holds nothing the environment doesn't
   already have, and the box's agent never reads the workspace. (Before
   environment VMs, a bind source swapped between the policy check and
   `docker compose up` was a way onto the box.)
5. **A compromised control plane can run repo code on every box.** It
   can't run arbitrary commands (fixed vocabulary, clone host
   allowlist), but it can create environments from any repo the GitHub
   App sees, and their lifecycle hooks run in those environments' VMs.
   Keep the control plane tailnet-only and its admins few.
6. **The first install trusts the control plane.** `install.sh` checks
   the agent tarball against a SHA-256 the control plane sends, not the
   release signature (updates after that are signature-checked), and
   that agent names the guest image the box's VMs boot. The same goes
   for a Flatcar box's first-boot config and the launcher, which the
   control plane serves.
7. **Redaction is best effort.** Values shorter than six characters
   aren't redacted, and an encoded secret (base64, URL-encoded) isn't
   recognised. Logs are redacted a line at a time, so a value split
   across two reads is still caught. Text that has to go out before its
   line ends (a prompt, or a line over 64 KiB) holds back any tail that
   could be the start of a secret, and a tail still held when the
   operation ends is masked. Operation logs (up to 1 MB each) are stored for 30 days
   and shown to the environment's owner and admins.
8. **First sign-in claims the deployment** when no `FOREMAN_ADMINS` or
   allowlists are set. Set `FOREMAN_ADMINS`.
9. **The setup token is in the log.** Anyone who can read the log
   before setup is finished can create the GitHub App.
10. **In-memory state.** Rate limits and the connect nonce cache are per
    node and reset on restart; a captured connect header could be
    replayed within 60 seconds of a control plane restart.
11. **Keys in the environment.** `FOREMAN_ENCRYPTION_KEY` and the Tailscale
    OAuth secret are environment variables, readable in
    `/proc/<pid>/environ` by the same user and root. If the encryption key
    leaks, change it ([upgrading.md](setup/upgrading.md#changing-the-encryption-key)).
12. **Tokens in environments are usable by anything in them.** The
    scoped GitHub token can push to the environment's repo (and its
    extra repos) as the user. That's the point, but a malicious
    dependency, or a coding agent following injected instructions, gets
    the same power. Branch protection and rulesets still apply, because
    the token acts as the user.
13. **Environments reach the internet and the LAN.** (Before
    environment VMs this gap was the shared kernel: environments ran on
    the box's Docker, and a container escape landed on the box. Each
    environment now has its own kernel, and an escape lands in its own
    VM; 17 covers what's between a VM and the box.) Treat code in an
    environment (including coding agents) as able to reach anything on
    the internet and, unless the box was installed with `--block-lan`,
    on the box's LAN: there's no egress filtering, and on a cloud
    instance the metadata endpoint is reachable unless the LAN is
    blocked. Most devcontainer images give their user passwordless sudo,
    and privileged containers are allowed, so assume root in the VM. The
    box itself, other environments and the tailnet as the box are kept
    out by the firewall, and something that flushes the box's whole
    ruleset removes it until its timer loads it again (within 15
    seconds).
14. **VMs can overcommit the box.** Every VM has CPU, memory and task
    limits, so one runaway environment can't take the whole box (before
    environment VMs there were no limits by default). Their sum can
    still be more than the box has: the box's capacity setting decides
    whether placement allows that, and a box that runs out of memory has
    the kernel kill a process to make room, quite likely a VM. Data disks
    are sparse, so they can promise more than `/srv/foreman` holds. Some
    of the box's shared resources have no per-VM limit at all, the
    connection tracking table among them.
15. **Removed members keep access for up to six hours.** Membership is
    re-checked periodically, not instantly. Disable someone in Foreman to
    cut their access at once.
16. **Snapshots hold secrets.** Suspending an environment writes the
    VM's whole memory, secrets included, to the box's disk, where
    otherwise secrets only ever touch tmpfs. The snapshot is in the VM's
    own directory (0700, the agent's user), is deleted once the VM is back
    from it and on destroy, and is never copied off the box; a
    suspend the agent was stopped in the middle of is cleaned up when it
    starts again. Until then it
    is readable by root on the box, and once deleted its blocks stay on
    the disk until they're reused: a box whose disk isn't encrypted
    keeps them at rest. Stop rather than suspend an environment whose
    secrets matter more than its running processes.
17. **A hostile guest against Cloud Hypervisor.** A guest that finds a
    bug in Cloud Hypervisor's device emulation (block, network, vsock,
    balloon, serial) or in KVM gets code running on the box as the
    agent's user, still inside its VM's unit: no capabilities, a seccomp
    filter, Landlock rules to its own files, and its cgroup. Every VM
    runs as that one user, so Landlock is what keeps one VM's process
    away from another's disks, and out of the agent's files and other
    VMs' through `/proc/<pid>/root`, which the unit's mount namespace
    doesn't stop. A box whose kernel can't apply it runs no VMs; a user
    per VM isn't built. A resumed VM is the exception for now: on a
    restore, Cloud Hypervisor v54.1 starts its virtio workers, the
    threads a device bug lands in, before it applies Landlock, and they
    run without it until the VM next boots
    ([cloud-hypervisor#9118](https://github.com/cloud-hypervisor/cloud-hypervisor/issues/9118)).
    The VM's directory is inside its own rules, and Cloud Hypervisor
    opens its log, the serial console and, on a resume, the snapshot and
    the disks before Landlock confines it. So nothing a VM leaves there
    is trusted: the helper won't start or resume a VM where one of those
    is a symlink or isn't a plain file, and before a resume the agent
    checks the snapshot's saved config (Landlock on with start's rules,
    the VM's own disks, kernel, tap and sockets, no other device). The
    agent writes its own files there without following symlinks.
    Nothing here has been tested against attacks on the device
    emulation. The defence is upstream's work and keeping Cloud
    Hypervisor current (19).
18. **A guest can fill its own log.** Cloud Hypervisor writes a guest's
    serial console to `serial.log` in the VM's directory on the box, with
    no size limit and no rotation, and root in the guest can write to its
    console for as long as it likes, until `/srv/foreman` is full.
19. **The guest image and Cloud Hypervisor need keeping current.** The
    guest's kernel, Docker and the rest come from the guest image a
    release names, and Cloud Hypervisor from the version pinned in the
    release. Neither updates on its own: their fixes reach boxes with a
    Foreman release, and a VM moves to a new guest image on its next
    boot.
20. **No core scheduling on Flatcar.** Cloud Hypervisor keeps two VMs'
    vCPUs off a core's sibling hyperthreads where the kernel has core
    scheduling. Flatcar's kernel doesn't (`CONFIG_SCHED_CORE` is unset),
    so on a Flatcar box two environments' vCPUs can share a core, which
    is what side channels between hyperthreads need. Keep a Flatcar box
    to environments whose owners trust each other.
21. **A prebuild's disk is shared.** Every environment of a repo made
    from a prebuild starts from the same disk: whatever the prebuild's
    lifecycle hooks wrote there, every later user of the repo gets. The
    prebuild has no one's secrets and clones with an installation token
    that reads the repo for an hour; registry credentials are on the
    guest's tmpfs during builds, never the disk. A hook that copies that
    token into a file leaves it for the repo's other users, who can read
    the repo anyway. Treat what hooks write as you would a commit. An
    environment starts from a prebuild only once its user's own GitHub
    token has read the repo and its extra repos; without a GitHub App
    configured, nothing checks.

## Things worth trying

- Make an agent act on another box's environment or operation (forged
  ids in events, a replayed connect, a revoked box reconnecting).
- Get a secret value back out: the UI, LiveView events, the audit log,
  operation logs, error messages, `inspect` output in logs.
- From inside an environment, as root in its VM (that's the starting
  point): reach the box, another VM or the tailnet over the network (a
  spoofed source address, IPv6, DNS to the box or MagicDNS, the LAN on a
  box with `--block-lan`, a published port); get the box's agent to act
  on something the guest sent (oversized or malformed frames, events
  for another operation, inventory or ports for another environment, a
  hello that never comes); get out through Cloud Hypervisor's devices
  or the vsock socket; fill the box's disk or memory past the VM's
  limits.
- Ask `foreman-vmctl` for something outside its vocabulary: a path, an
  id that isn't a UUID, a size past its bounds, a symlinked disk.
- Make the guest agent read or write outside the workspace (symlinks in
  `.devcontainer`, `.git/info`, compose file paths).
- Inject into git config through identity fields, branch names, repo
  names or dotfiles settings.
- Get past the Foreman feature with a user's own devcontainer features:
  a ref that isn't an OCI ref, one with the Foreman feature's id,
  options the agent passes on, or getting them into another user's
  environments.
- Cross-user access as a member: another user's environments, secrets,
  boxes, or admin pages and Oban Web.
- Sign-in: the OAuth state and PKCE, open redirects in `return_to`, the
  dev sign-in route in a production build (it shouldn't be compiled in).
- A Flatcar box's first-boot config: get one, or a Tailscale key,
  without a valid join token; get the key minted more than once; get
  something into the config through a box name or SSH key; reach the
  host from inside a box's VM.
- Reboot a box that isn't yours, or one that's already rebooting again,
  through `box.restart`.
