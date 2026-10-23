# Personal deployment

One Linux desktop runs both the control plane and the agent. SQLite is
the database. Everything is reachable only on your tailnet.

## What the desktop needs

- Docker Engine with the Compose plugin, v2.30 or newer (boxes need
  v2.24; the control plane's compose file needs 2.30)
- nftables (for the box's firewall; `apt install nftables`)
- git, and Node 20+ (for the devcontainer CLI)
- systemd
- Tailscale, logged in to your tailnet

On a fresh Ubuntu machine, install Docker from
[Docker's apt repository](https://docs.docker.com/engine/install/ubuntu/),
Node from [NodeSource](https://github.com/nodesource/distributions), and
Tailscale with `curl -fsSL https://tailscale.com/install.sh | sh`.

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
`:latest-pg` to them. The agents are also attached to a GitHub release.

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

See [tailscale.md](tailscale.md). Without it, environments still work,
but you reach them with `docker exec` on the box instead of over the
tailnet.

## 5. Add the desktop as a box

**Boxes → Add a box** gives a one-line install command with a
single-use join token. Run it on the desktop:

```sh
curl -fsSL https://desktop.tail1234.ts.net/agent/install.sh | sudo sh -s -- --token fj_...
```

The script checks the prerequisites, creates a `foreman` user in the
`docker` group, installs the devcontainer CLI and the agent, writes a
systemd unit (with a rollback unit for failed updates), and waits for
the agent to enroll. It then deletes the spent token from the agent's
settings. It also installs the box's firewall, `foreman-firewall.service`,
which keeps environments and image builds from reaching the tailnet as
the box (see [tailscale.md](tailscale.md#boxes-on-the-tailnet), which
also covers `--default-bridge-reaches-tailnet`). It refuses a box that
sends its traffic through a Tailscale exit node, since the firewall
would cut environments off from the internet there.

Re-running the script on a box that's already enrolled upgrades the
agent and its units and keeps the box's identity; it doesn't need a
token. It rewrites `/etc/foreman-agent/agent.env`, though, so pass
`--policy` (and `--default-bridge-reaches-tailnet`) again if the box had
one, and add back anything you added by hand. To enroll the box again (after revoking it, say), pass
`--reenroll` with a new token: the old identity is moved aside.

Boxes don't need the script for agent updates; see below.

## 6. Make an environment

**New environment**: pick a repo and the box. The first build pulls
images and takes a few minutes. After that, `ssh vscode@storefront-1` (or
whatever the devcontainer's remote user is) from any machine on the
tailnet, or open it in VS Code from the environment's page.

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

| Variable | Default | |
|---|---|---|
| `SECRET_KEY_BASE` | required | Signs sessions |
| `FOREMAN_ENCRYPTION_KEY` | required | 32 bytes, base64. Encrypts secrets at rest |
| `FOREMAN_ENCRYPTION_KEYS_RETIRED` | | Old encryption keys, comma-separated, still read while changing it ([upgrading.md](upgrading.md#changing-the-encryption-key)) |
| `PHX_HOST` | required | The tailnet host name |
| `FOREMAN_LISTEN_IP` | `127.0.0.1` | `0.0.0.0` inside a container |
| `PORT` | `4000` | |
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
and nobody else can sign in.

Agent settings (in `/etc/foreman-agent/agent.env`, written by the
install script) are documented in
`apps/foreman_agent/config/runtime.exs`. `FOREMAN_POLICY` opens up
what a box accepts from a repo, such as privileged containers for the
docker-in-docker feature. Everything is refused by default, and a box
that opens something up gets a red alert in the control plane. Read
[repos.md](repos.md#docker-inside-an-environment) before you reach for
it; there's usually a way that doesn't need it.

## Agent releases by hand

An image you built yourself from a checkout carries no agents, and a
control plane older than 0.3.0 doesn't register the ones its image
carries. Either
can register a release from a GitHub release, on the control plane's
host with `gh` logged in:

```sh
scripts/publish-agent-release.sh 0.3.0
```

Without CI, build and sign the agent on any machine with Docker and
Elixir:

```sh
docker build -f docker/box.Dockerfile --target agent-tarball \
  --build-arg FOREMAN_AGENT_VERSION=0.3.0 \
  --build-arg FOREMAN_RELEASE_PUBLIC_KEY=<public key> \
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
