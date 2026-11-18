# Personal deployment

One Linux desktop runs both the control plane and the agent. SQLite is
the database. Everything is reachable only on your tailnet. Each
environment runs in a VM of its own on the desktop.

## What the desktop needs

- amd64 (x86-64) with KVM: virtualization on in the firmware, so that
  `/dev/kvm` exists. Environments run in VMs, and arm64 boxes can't run
  them yet.
- Docker Engine with the Compose plugin, v2.30 or newer, for the control
  plane. The box itself doesn't use Docker.
- nftables, iproute2, e2fsprogs and util-linux (`apt install nftables
  iproute2 e2fsprogs util-linux`; most are there already)
- systemd
- Tailscale, logged in to your tailnet
- Room in `/srv/foreman` for environments' disks: each one's data disk
  can grow to 64 GB, and a suspended one keeps its memory there too. ext4
  is fine; see [Disks for environments](#disks-for-environments).

On a fresh Ubuntu machine, install Docker from
[Docker's apt repository](https://docs.docker.com/engine/install/ubuntu/)
and Tailscale with `curl -fsSL https://tailscale.com/install.sh | sh`.
The agent brings its own Node for the devcontainer CLI, and Cloud
Hypervisor for the VMs; the VMs have their own Docker and git.

If you have more than one Tailscale account, check the box joined the
tailnet your laptops are on before going further:

```sh
tailscale switch --list    # the starred tailnet is the current one
tailscale status           # the peers it can see
```

## 1. Make the release keys and the first release

Every release is one tag. CI builds the agent for `linux-amd64` and
`linux-arm64`, signs it, and builds control plane images with those
agents inside, so a control plane always serves the agents that match
it. The signing key never touches the control plane. Make the keypair
once (`mix` here needs the Elixir from `mise.toml`):

```sh
cd apps/foreman_agent
mix foreman_agent.sign --keygen
# FOREMAN_RELEASE_PRIVATE_KEY=<private key>
# FOREMAN_RELEASE_PUBLIC_KEY=<public key>
```

Wherever these steps say `<private key>` or `<public key>`, use what
comes after the `=`, not the whole line. The public key is compiled into
every agent, which checks updates against it, so a lost private key
means reinstalling every box. Keep a copy somewhere safe, give it to
CI, and keep it out of the repo:

```sh
gh secret set FOREMAN_RELEASE_PRIVATE_KEY      # paste the private key
gh variable set FOREMAN_RELEASE_PUBLIC_KEY --body '<public key>'
```

Then push a tag. The `Release` workflow runs CI on it first, and
publishes nothing from a commit that fails:

```sh
git tag v0.3.0 && git push origin v0.3.0
```

It pushes `ghcr.io/<owner>/foreman:0.3.0` (SQLite) and `:0.3.0-pg`
(Postgres), each for amd64 and arm64, and moves `:latest` and
`:latest-pg` to them. The agents are also attached to a GitHub release,
with the guest image environment VMs boot,
`foreman-guest-<version>-linux-amd64.tar`. The amd64 agent is built with
that file's URL and SHA-256, and downloads it from the release the first
time a box needs it. If the repo is private, boxes can't download it
from there without credentials: put a copy where they can, and set
`FOREMAN_GUEST_URL` (an `https://` or `file://` URL) in each box's
`/etc/foreman-agent/agent.env`.

The agent is built on Ubuntu 22.04 and runs on Ubuntu 22.04+ and
Debian 12+. It bundles the Erlang runtime, which needs the build
system's glibc and OpenSSL or newer, so a box older than that won't
start it.

## 2. Run the control plane

Keep the control plane's settings in a file only root can read:

```sh
sudo install -d -m 0700 /etc/foreman
printf '%s\n' \
  "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')" \
  "FOREMAN_ENCRYPTION_KEY=$(openssl rand -base64 32)" \
  "PHX_HOST=desktop.tail1234.ts.net" \
  "FOREMAN_LISTEN_IP=0.0.0.0" \
  "FOREMAN_ADMINS=your-github-login" \
  "FOREMAN_AGENT_RELEASE_PUBLIC_KEY=<public key>" \
  "FOREMAN_AGENT_RELEASE_DIR=/var/lib/foreman/releases" | sudo tee /etc/foreman/foreman.env >/dev/null
sudo chmod 0600 /etc/foreman/foreman.env
```

`PHX_HOST` is the desktop's MagicDNS name (`tailscale status --json |
jq -r .Self.DNSName`, without the trailing dot). The release key lets
the control plane check the agents its image carries before it serves
them. Keeping releases in the data volume means boxes can still get
older ones after an upgrade.

The images are private when the repo is, so log the host in to GHCR
once, with a token that has `read:packages`:

```sh
sudo docker login ghcr.io -u <github-login>
```

Then run it with [`docker/compose.yml`](../../docker/compose.yml) (from
a checkout, or copy the file to the host). Pin the version in a `.env`
file beside it, so every later `docker compose` command uses the same
image, and run compose as root, since it reads the settings file:

```sh
echo "FOREMAN_IMAGE=ghcr.io/<owner>/foreman:0.3.0" > docker/.env
sudo docker compose -f docker/compose.yml up -d
```

The port is published on loopback only; Tailscale serves it to the
tailnet over HTTPS:

```sh
sudo tailscale serve --bg --https=443 http://127.0.0.1:4000
```

If your tailnet policy isn't the default allow-all, your laptops won't
see the desktop until a rule lets them reach it. Tag the desktop
`tag:foreman` and grant your machines port 443 on it; see
[tailscale.md](tailscale.md#the-control-plane-host). Firefox reporting
"Server Not Found" for the `.ts.net` name usually means exactly this.

**Back up `FOREMAN_ENCRYPTION_KEY`.** Every secret, token and key in the
database is encrypted with it; without it they're gone, and the control
plane won't start with a different one. What else to keep, how to
upgrade and how to change the key are in [upgrading.md](upgrading.md).

### Building the image yourself

Without CI, build from a checkout and point compose at it:

```sh
docker build -f docker/control-plane.Dockerfile -t foreman .
echo "FOREMAN_IMAGE=foreman" > docker/.env
sudo docker compose -f docker/compose.yml up -d
```

An image built this way carries whatever is in `docker/agents/`, which
is empty in a checkout. Build and register agents by hand (see
[Agent releases by hand](#agent-releases-by-hand)); boxes that aren't
pinned follow the newest one you register.

## 3. Connect GitHub

Open `https://desktop.tail1234.ts.net/setup`. It asks for a one-time
setup token, which is in the log:

```sh
sudo docker logs foreman 2>&1 | grep -A1 "setup token"
```

Then create the GitHub App on your account (one click on GitHub) and
install it on the repos Foreman should see. See
[github-app.md](github-app.md). Sign in with GitHub afterwards; with
`FOREMAN_ADMINS` set to your login, you're the admin.

## 4. Connect Tailscale

Create an OAuth client and set `FOREMAN_TAILSCALE_CLIENT_ID` and
`FOREMAN_TAILSCALE_CLIENT_SECRET` in `/etc/foreman/foreman.env`, then
recreate the container so it reads them (`docker restart` keeps the old
environment):

```sh
sudo docker compose -f docker/compose.yml up -d --force-recreate
```

See [tailscale.md](tailscale.md). Without it, environments still build
and run, but nothing can reach them: they're in VMs with no way in but
the tailnet.

## 5. Add the desktop as a box

**Boxes → Add a box** gives a one-line install command with a
single-use join token. Run it on the desktop:

```sh
curl -fsSL https://desktop.tail1234.ts.net/agent/install.sh | sudo sh -s -- --token fj_...
```

The script checks the prerequisites, creates an unprivileged `foreman`
user (not in the `docker` group), installs the agent (which carries the
devcontainer CLI, the Node it runs on and Cloud Hypervisor), writes a
systemd unit (with a rollback unit for failed updates), and waits for
the agent to enroll. It then deletes the spent token from the agent's
settings. It also installs:

- `foreman-vmctl`, the small root helper that gives each environment's
  VM its network tap, address and systemd unit
  ([architecture.md](../architecture.md#environment-vms));
- the box's firewall, `foreman-firewall.service`, which keeps
  environments off the box itself, off each other and off the tailnet
  as the box (see [tailscale.md](tailscale.md#boxes-on-the-tailnet));
- `/etc/sysctl.d/90-foreman.conf`, which turns on IPv4 forwarding from
  boot, since the box routes its VMs' traffic. If forwarding wasn't on
  already (Docker turns it on), the kernel turns LRO off on the
  desktop's network cards when it comes on, and some drivers (atlantic,
  for one) reset the link to do that: the desktop may drop off the
  network for a moment during the install. After that it's on from
  boot, before the network is up.

At the end it says whether `/srv/foreman` can reflink. The script
refuses a box that sends its traffic through a Tailscale exit node,
since the firewall would cut environments off from the internet there.

| Option | |
|---|---|
| `--token fj_...` | the join token, for a box that isn't enrolled yet |
| `--block-lan` | blocks guest access to RFC 1918 networks. Both settings block IPv4 link-local services, including cloud metadata, with a DNS exception for configured resolvers. The box page shows the reported LAN policy. |
| `--vm-subnet A.B` | gives VMs their addresses from `A.B.0.0/16` instead of `10.250.0.0/16`, for a LAN that already uses it. It has to be a private range. |
| `--default-bridge-reaches-tailnet` | on a box with Docker, leaves Docker's default bridge out of the firewall ([tailscale.md](tailscale.md#boxes-on-the-tailnet)) |
| `--reenroll` | enrolls the box again with a new `--token` (after revoking it, say); the old identity is moved aside |
| `--url` | the control plane's address, when the box reaches it some other way than the one in the command |

Re-running the script refreshes the installed agent version, its root helpers
and systemd units. It keeps the box identity, pending rollback and local
settings in `/etc/foreman-agent/agent.env`. Installer-managed values, including
the control plane URL and enrollment token, live in `install.env` and take
precedence. An enrolled box needs no token. The installer remembers
`--block-lan` and `--vm-subnet`. Pass `--default-bridge-reaches-tailnet`
again if you use it. A box migrating from shared Docker installs the fleet VM
release so it can reconnect. Change the desired agent version in Foreman.

### Disks for environments

Every environment has three disks, in `/srv/foreman/vms/<env_id>/`: a
copy of the guest system's disk, made again whenever the guest image
changes; its own data disk (Docker's data, the clone), a sparse file
that grows to at most 64 GB; and the agent release, shared and
read-only. On a filesystem with reflinks, XFS or btrfs, the copy is a
reflink: made at once, with no extra space. On ext4 it's a full copy,
which takes its full size. The install script says which you have, and
the box's page shows "full-copy disks" when it can't reflink.

ext4 is fine, and on the production box it was the better choice. A full
copy of a 1.5 GB prebuild took under half a second on fast NVMe, and the
whole path from a prebuild to a running environment was quicker than
with reflinks, because a reflinked disk pays on its first write to every
block it shares: random writes there ran at a few thousand IOPS before
the blocks were rewritten, against hundreds of thousands on a copy.
Those numbers came from XFS on a loop device, which exaggerates the cost,
so measure on a real volume before choosing XFS for its space savings.

The script doesn't make filesystems. To put `/srv/foreman` on XFS, give
it a spare disk or partition, before the box has environments (on a
box moving to environment VMs, before you make its environments
again; see [upgrading.md](upgrading.md#moving-to-environment-vms)).
Whatever is already in `/srv/foreman` is hidden under the new mount,
old environments' clones included, so copy out anything you still
need first. This erases `/dev/nvme1n1`:

```sh
sudo mkfs.xfs /dev/nvme1n1            # reflinks are on by default in current xfsprogs
echo "UUID=$(sudo blkid -s UUID -o value /dev/nvme1n1) /srv/foreman xfs defaults,noatime 0 0" |
  sudo tee -a /etc/fstab
sudo mkdir -p /srv/foreman && sudo mount /srv/foreman
```

Then run (or re-run) the install script, which makes the directories it
needs there.

## 6. Make an environment

**New environment**: pick a repo and the box. The box downloads the
guest image the first time, and every environment's first build pulls
its images into its own VM, so a first build takes a few minutes. After
that, `ssh vscode@storefront-1` (or
whatever the devcontainer's remote user is) from any machine on the
tailnet, or open it in VS Code from the environment's page.

Tools that pair a client with a server in the environment, like Orca,
can show their pairing code on the environment's page; see
[connect-hooks.md](connect-hooks.md).

## Updates

Upgrading the control plane is a pull and a restart, and each box then
updates its agent to the one the new image carries; see
[upgrading.md](upgrading.md) for the steps, backups and rolling back.

To update from the Deployment page instead, install the updater on the
desktop once ([upgrading.md](upgrading.md#from-the-deployment-page)):

```sh
img=$(sudo docker inspect -f '{{.Config.Image}}' foreman)
sudo docker run --rm --entrypoint cat "$img" /app/updater/foreman-update |
  sudo sh -s -- install docker/compose.yml
```

## Settings

An empty value counts as unset. On/off settings take `true` or `false`
(or `1`/`0`, `yes`/`no`, `on`/`off`); anything else stops the control
plane from starting, so a typo can't quietly turn one off.

| Variable | Default | |
|---|---|---|
| `SECRET_KEY_BASE` | required | Signs sessions |
| `FOREMAN_ENCRYPTION_KEY` | required | 32 bytes, base64. Encrypts secrets at rest |
| `FOREMAN_ENCRYPTION_KEYS_RETIRED` | | Old encryption keys, comma-separated, still read while changing it ([upgrading.md](upgrading.md#changing-the-encryption-key)) |
| `PHX_HOST` | required | The tailnet host name |
| `FOREMAN_LISTEN_IP` | `127.0.0.1` | `0.0.0.0` inside a container |
| `PORT` | `4000` | |
| `FOREMAN_TRUSTED_PROXIES` | (none); `gateway` in the image | Peers besides loopback whose `X-Forwarded-For` is believed, for per-client rate limits: addresses, CIDR ranges, or `gateway` (the container's default gateway, where Docker's published ports connect from) |
| `DATABASE_PATH` | `/var/lib/foreman/foreman.db` | SQLite file |
| `FOREMAN_ADMINS` | | Comma-separated GitHub logins that are admins |
| `FOREMAN_ALLOWED_USERS` | | Other logins that may sign in |
| `FOREMAN_ALLOWED_ORG` | | Active members of this org may sign in |
| `FOREMAN_SLUG_STYLE` | `personal` | `team` puts the login in environment names |
| `FOREMAN_TAILSCALE_CLIENT_ID`, `_CLIENT_SECRET` | | Tailscale OAuth client |
| `FOREMAN_TAILSCALE_TAGS` | (none) | Extra tags every environment gets. `tag:foreman-env` is always applied, and cleanup only deletes devices that have it |
| `FOREMAN_TAILSCALE_DEPLOYMENT_TAG` | (none) | A tag only this deployment uses. Every environment gets it, and cleanup also removes this deployment's devices it has no record of ([tailscale.md](tailscale.md#a-tag-per-deployment)) |
| `FOREMAN_GITHUB_APP_ID`, `_CLIENT_ID`, `_CLIENT_SECRET`, `_PRIVATE_KEY_FILE` | | Instead of the manifest flow; the key file has to be mounted in ([github-app.md](github-app.md)) |
| `FOREMAN_AGENT_RELEASE_PUBLIC_KEY` | | Verifies the agent releases the control plane serves, including the ones its image carries |
| `FOREMAN_AGENT_RELEASE_DIR` | system temp dir | Where published releases are kept; set it to a persistent path |
| `FOREMAN_BASE_URL` | `https://PHX_HOST` | The URL agents and GitHub are given |
| `FOREMAN_FORCE_SSL`, `FOREMAN_SECURE_COOKIES` | `true` | Leave on behind `tailscale serve` |
| `FOREMAN_UPDATE_CHECK` | `true` | `false` stops checking GitHub for new releases |
| `FOREMAN_UPDATE_REPO` | `ntodd/foreman` | Where to look for them |
| `FOREMAN_UPDATE_DIR` | `/var/lib/foreman-update` | Shared with the host's updater; compose.yml mounts it |

With none of `FOREMAN_ADMINS`, `FOREMAN_ALLOWED_USERS` and
`FOREMAN_ALLOWED_ORG` set, the first person to sign in becomes the admin
and nobody else can sign in. With a user or organization allowlist, new users
join as members. Set `FOREMAN_ADMINS` to the GitHub login of the intended
administrator. On existing installations, review previously assigned admin roles.

Agent settings (in `/etc/foreman-agent/agent.env`, written by the
install script) are documented in
`apps/foreman_agent/config/runtime.exs`. The ones for environment VMs:

| Variable | Default | |
|---|---|---|
| `FOREMAN_VM_CPUS` | `4` | A VM's CPUs when neither the environment nor its repo has a CPU limit |
| `FOREMAN_VM_MEMORY_MB` | `8192` | A VM's memory when neither has a memory limit |
| `FOREMAN_VM_DISK_GB` | `64` | The size of a new environment's data disk |
| `FOREMAN_VM_RECLAIM_BELOW` | `20` | When less than this percent of the box's memory is available, quiet VMs are asked to give back their page cache; `0` turns it off |
| `FOREMAN_VM_RECLAIM_KEEP_MB` | `2048` | The page cache a VM keeps when it's asked |
| `FOREMAN_VM_RECLAIM_IDLE_MINUTES` | unset | When set, a VM quiet this long is asked once, however much memory the box has free |
| `FOREMAN_GUEST_URL`, `FOREMAN_GUEST_SHA256` | what the agent was built with | Where the guest image comes from (`https://` or `file://`), and the SHA-256 it has to match; each overrides its own half |

A VM never gets more CPUs or memory than the box has. A VM holds on to
the box memory its page cache filled until it's asked to give it back;
see [architecture.md](../architecture.md) for when. `FOREMAN_POLICY`
is gone: environments run in VMs, so there's nothing left for it to
open up (see [repos.md](repos.md#docker-inside-an-environment)).

## Agent releases by hand

An image you built yourself from a checkout carries no agents, and a
control plane older than 0.3.0 doesn't register the ones its image
carries. Either
can register a release from a GitHub release, on the control plane's
host with `gh` logged in:

```sh
scripts/publish-agent-release.sh 0.3.0
```

Without CI, build the guest image, and build and sign the agent, on any
machine with Docker and Elixir. The agent needs the guest image's URL
and SHA-256 to run environments, so put the image somewhere boxes can
download it over HTTPS first (`guest/build.sh` writes its SHA-256 beside
it):

```sh
guest/build.sh out                        # out/foreman-guest-linux-amd64.tar and .sha256
docker build -f docker/box.Dockerfile --target agent-tarball \
  --build-arg FOREMAN_AGENT_VERSION=0.3.0 \
  --build-arg FOREMAN_RELEASE_PUBLIC_KEY=<public key> \
  --build-arg FOREMAN_GUEST_URL=https://<where you put it>/foreman-guest-linux-amd64.tar \
  --build-arg FOREMAN_GUEST_SHA256=<its sha256> \
  -o out .
cd apps/foreman_agent
FOREMAN_RELEASE_PRIVATE_KEY=<private key> \
  mix foreman_agent.sign 0.3.0 linux-amd64 ../../out/foreman_agent.tar.gz   # prints the signature
```

Leave `FOREMAN_RELEASE_PUBLIC_KEY` unset when signing. The agent reads
it at compile time, and mix refuses to run when it differs at run time.
Build on the box's architecture (`linux-arm64` on ARM). Then register
it; the copy is owned by root, so remove it as root:

```sh
sudo docker cp out/foreman_agent.tar.gz foreman:/tmp/agent.tar.gz
sudo docker exec foreman env -u PHX_SERVER /app/bin/foreman eval \
  'Foreman.Release.publish_agent("0.3.0", "linux-amd64", "/tmp/agent.tar.gz", "<signature>")'
sudo docker exec -u 0 foreman rm /tmp/agent.tar.gz
```

On an image that carries no agents, boxes that aren't pinned follow the
newest release registered. On one that does, they follow what it
carries, and new boxes install that too, so a release registered by
hand on top (a hotfix, say) only reaches the boxes you pin to it.

To bake your own agents into an image instead, put each tarball in
`docker/agents/` as `foreman_agent-<version>-<target>.tar.gz`, with its
signature beside it as `.sig`, and build the image. Empty the directory
again afterwards, or the next image you build carries them too.
