# Personal deployment

One Linux desktop runs both the control plane and the agent. SQLite is
the database. Everything is reachable only on your tailnet.

## What the desktop needs

- Docker Engine with the Compose plugin, v2.30 or newer (boxes need
  v2.24; the control plane's compose file needs 2.30)
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

## The installer

Once a release exists (section 1), its installer does sections 2 to 5 on
the desktop. Releases after 0.3.0 have it attached, with that release's
version and public key baked in. The repo is private, so fetch it with
`gh` (logged in as you) and run it as root. Without a tag, `gh` takes
the latest release:

```sh
gh release download -R ntodd/foreman -p install-control-plane.sh -O - | sudo bash
```

For a particular release, put its tag after `download`
(`gh release download vX.Y.Z -R ntodd/foreman ...`).

0.3.0 has no installer attached (`gh` says no assets match, and pipes
nothing to bash). For it, run the copy in a checkout of `main`. That
copy has no version or key baked in: give it the version, and the agent
release public key (the repo's `FOREMAN_RELEASE_PUBLIC_KEY` variable)
unless `/etc/foreman/foreman.env` already has
`FOREMAN_AGENT_RELEASE_PUBLIC_KEY`. Without the key it asks on the
terminal, and fails when unattended.

```sh
gh repo clone ntodd/foreman && cd foreman
sudo bash scripts/install-control-plane.sh --version 0.3.0 \
  --public-key "$(gh variable get FOREMAN_RELEASE_PUBLIC_KEY -R ntodd/foreman)"
```

`gh` runs as you, before `sudo`. Running the checkout's copy again
without `--version` keeps the image it pinned.

While the repo is private, a plain `curl` of the release asset gets a
404; `curl -fsSL <asset url> | sudo bash` only works once it's public.
The prompts read from the terminal, so piping it into bash is fine
whatever your login shell is.

It explains each step as it goes:

- Checks for systemd, Docker and Compose 2.30+, and installs curl, jq,
  git and Node 22 (from NodeSource, so it's on the system `PATH` the
  agent's unit sees) with apt if they're missing. It stops on a
  Postgres deployment; those are set up by hand ([team.md](team.md)).
- Publishes the control plane on a free loopback port: 4000, or the
  next free one if something else has it or `tailscale serve` forwards
  to it (a service that's down still owns its serve entry, Funnel
  included).
- Serves it with `tailscale serve` on 443 if nothing else is served
  there and nothing on the host listens on it, otherwise 8443, 10000,
  8444 and so on. A serve entry only counts as Foreman's when it
  forwards to Foreman's pinned loopback port, or, with none pinned, sits
  on the port in `FOREMAN_BASE_URL`, has Funnel off and forwards to a
  loopback port nothing on the host listens on. It never changes a port
  that serves something else and never turns on Funnel. If Funnel is on
  for Foreman's own port it says so and turns it off, and it checks
  afterwards that the port is tailnet only; if Funnel stayed on, it
  takes Foreman off that port and stops. On a port other than 443 it
  sets `FOREMAN_BASE_URL` and `FOREMAN_EXTRA_ORIGINS` to match. When
  the port changes and the old port still forwards to Foreman, it's left
  serving Foreman for boxes enrolled with the old URL, and the installer
  prints how to move them and turn the old port off. If the old port
  now serves something else (or nothing), it says the old URL no longer
  reaches Foreman, that boxes enrolled with it need `FOREMAN_URL`
  updated now, and drops the old URL from `FOREMAN_EXTRA_ORIGINS`; it
  never suggests turning off a port that serves another service.
- Writes `/etc/foreman/foreman.env` (root, 0600), generating
  `SECRET_KEY_BASE` and `FOREMAN_ENCRYPTION_KEY` the first time and
  never again, and sets `FOREMAN_ADMINS`, the release key and the
  release directory. If the file lacks a secret the running `foreman`
  container has, it takes the container's. It won't make a new
  encryption key next to an existing `foreman-data` volume unless you
  say so (`FOREMAN_NEW_SECRETS=yes`), and stops if the file's key
  differs from the one the container runs with.
- Logs root's Docker in to GHCR if the image can't be pulled (see
  [the GHCR login](#2-run-the-control-plane) for the token). The login
  goes in `/root/.docker/config.json` even under `sudo -E`, so a later
  `sudo docker compose pull` finds it. It pulls before writing anything.
- Writes `/opt/foreman/compose.yml` and a `.env` that pins the image and
  port, starts the control plane and waits for `/healthz`.
- Asks for the Tailscale OAuth client, after printing the policy it
  needs, and checks it can list devices and make `tag:foreman-env`
  keys. That check leaves an unused key that expires in five minutes.
- Connects GitHub: either prints the setup page's URL and the current
  setup token for the one-click app, or prints the settings for an app
  you create by hand, installs its key and asks GitHub whether it
  accepts the App ID and key (the client secret is only checked when
  you sign in).
- Once you've signed in, makes a join token for the desktop and runs
  the box install script (section 5).

Running it again is safe. Finished steps are skipped, the secrets are
kept, and the container is only recreated when its settings changed.
Running a newer release's installer upgrades to that release. It asks
first (unattended, it needs `FOREMAN_UPGRADE=yes`), then stops the
control plane and backs up the `foreman-data` volume, the settings file
as it was before the run, and the GitHub App's key if there is one, to
`/var/backups/foreman` (all root only; `FOREMAN_BACKUP=no` skips that).
If the backup fails, it puts the settings file back and starts the
control plane again as it was. It refuses to move below the version the
`foreman` container runs or `/opt/foreman/.env` pins, whichever is
higher, unless `FOREMAN_DOWNGRADE=yes`, since migrations don't run
backwards.

On a host set up by hand with `/etc/foreman/foreman.env`, it keeps the
settings file, the port the container publishes and its serve port.
With no `/opt/foreman/.env`, the image the `foreman` container runs
counts as the pinned one, so a different image is asked about (and an
older one refused) the same way. It copies a compose file it didn't
write to `compose.yml.before-installer.*` before replacing it, and if
the container was started from somewhere else (`docker/` in a
checkout), it says so: rename that `compose.yml` and `.env`, or a
`docker compose up` there brings the old setup back.

For an unattended run, give the answers as environment variables (or
flags) and pass `--non-interactive`; `--help` lists them all. Secrets
are only read from the environment or the terminal, never flags. Keep
them out of your shell history with a file only you can read:

```sh
# answers.env (chmod 600):
#   FOREMAN_ADMINS=octocat
#   FOREMAN_GHCR_USER=octocat
#   FOREMAN_GHCR_TOKEN=<classic PAT, read:packages>
#   FOREMAN_GITHUB_APP=manifest
#   FOREMAN_TAILSCALE=skip
#   FOREMAN_UPGRADE=yes        # lets a newer release's copy change the image
sudo bash -c 'set -a && . ./answers.env && set +a && bash install-control-plane.sh --non-interactive'
```

The sections below are what it does, step by step, for doing it by hand
or seeing what it changed.

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
`:latest-pg` to them if the version is at or above every published
GitHub release (a tag whose release failed doesn't count); the GitHub
release is marked Latest on the same terms. The agents are also attached
to the GitHub release.

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
once, with a classic personal access token that has only
`read:packages` (fine-grained tokens can't read packages; see
[ghcr-machine-user.md](ghcr-machine-user.md)). Compose runs as root, so
log in as root; a `docker login` as your own user goes in your
`~/.docker/config.json`, which root's Docker doesn't read, and the pull
fails with `unauthorized`:

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

If another container already publishes port 4000, change the
`127.0.0.1:4000:4000` line in `compose.yml` to a free port (say
`127.0.0.1:4100:4000`) and use that port below.

The port is published on loopback only; Tailscale serves it to the
tailnet over HTTPS. Check what the desktop already serves first:

```sh
sudo tailscale serve status
```

`tailscale serve --https=443` replaces whatever already serves 443, and
turns its Funnel off, without asking. If 443 is free:

```sh
sudo tailscale serve --bg --https=443 http://127.0.0.1:4000
```

If it isn't, serve Foreman on another port (8443 here) and give the
control plane the URL with that port in `/etc/foreman/foreman.env`.
`FOREMAN_BASE_URL` is what GitHub and agents are given, and
`FOREMAN_EXTRA_ORIGINS` lets LiveView's websocket connect from it
(otherwise only `https://PHX_HOST`, on 443, is allowed):

```sh
sudo tailscale serve --bg --https=8443 http://127.0.0.1:4000
# in /etc/foreman/foreman.env, then recreate the container
FOREMAN_BASE_URL=https://desktop.tail1234.ts.net:8443
FOREMAN_EXTRA_ORIGINS=https://desktop.tail1234.ts.net:8443
```

Never use `tailscale funnel` for Foreman's port. `sudo tailscale serve
status` should list it as "(tailnet only)".

If your tailnet policy isn't the default allow-all, your laptops won't
see the desktop until a rule lets them reach it. Tag the desktop
`tag:foreman` and grant your machines the serve port (443, or the one
you picked) on it; see
[tailscale.md](tailscale.md#the-control-plane-host). Firefox reporting
"Server Not Found" for the `.ts.net` name usually means exactly this.

**Back up `FOREMAN_ENCRYPTION_KEY`.** Every secret, token and key in the
database is encrypted with it; without it they're gone. The file is
root's, so read it with `sudo cat /etc/foreman/foreman.env`. What else to
keep, and how to upgrade, is in [upgrading.md](upgrading.md).

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

Open `https://desktop.tail1234.ts.net/setup` (with the port, if it
isn't 443). It asks for a one-time setup token, which is in the log. A
new one is issued every time the container starts, so take the last:

```sh
sudo docker logs foreman 2>&1 | grep -A1 "setup token" | tail -n 1
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
settings.

Re-running the script on a box that's already enrolled upgrades the
agent and its units and keeps the box's identity; it doesn't need a
token. It rewrites `/etc/foreman-agent/agent.env`, though, so pass
`--policy` again if the box had one, and add back anything you added by
hand. To enroll the box again (after revoking it, say), pass
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

## Settings

| Variable | Default | |
|---|---|---|
| `SECRET_KEY_BASE` | required | Signs sessions |
| `FOREMAN_ENCRYPTION_KEY` | required | 32 bytes, base64. Encrypts secrets at rest |
| `PHX_HOST` | required | The tailnet host name |
| `FOREMAN_LISTEN_IP` | `127.0.0.1` | `0.0.0.0` inside a container |
| `PORT` | `4000` | |
| `DATABASE_PATH` | `/var/lib/foreman/foreman.db` | SQLite file |
| `FOREMAN_ADMINS` | | Comma-separated GitHub logins that are admins |
| `FOREMAN_ALLOWED_USERS` | | Other logins that may sign in |
| `FOREMAN_ALLOWED_ORG` | | Active members of this org may sign in |
| `FOREMAN_SLUG_STYLE` | `personal` | `team` puts the login in environment names |
| `FOREMAN_TAILSCALE_CLIENT_ID`, `_CLIENT_SECRET` | | Tailscale OAuth client |
| `FOREMAN_TAILSCALE_TAGS` | (none) | Extra tags every environment gets. `tag:foreman-env` is always applied, and it's the only tag cleanup looks at |
| `FOREMAN_GITHUB_APP_ID`, `_CLIENT_ID`, `_CLIENT_SECRET`, `_PRIVATE_KEY_FILE` | | Instead of the manifest flow; the key file has to be mounted in ([github-app.md](github-app.md)) |
| `FOREMAN_AGENT_RELEASE_PUBLIC_KEY` | | Verifies the agent releases the control plane serves, including the ones its image carries |
| `FOREMAN_AGENT_RELEASE_DIR` | system temp dir | Where published releases are kept; set it to a persistent path |
| `FOREMAN_BASE_URL` | `https://PHX_HOST` | The URL agents and GitHub are given. Include the port when `tailscale serve` isn't on 443 |
| `FOREMAN_EXTRA_ORIGINS` | | Comma-separated origins allowed besides `https://PHX_HOST`, such as `https://PHX_HOST:8443` when serving on 8443 (no trailing slash) |
| `FOREMAN_FORCE_SSL`, `FOREMAN_SECURE_COOKIES` | `true` | Leave on behind `tailscale serve` |

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
