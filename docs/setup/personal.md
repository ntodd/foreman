# Personal deployment

One Linux desktop runs both the control plane and the agent. SQLite is
the database. Everything is reachable only on your tailnet.

## What the desktop needs

- Docker Engine with the Compose plugin, v2.24 or newer
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

## 1. Run the control plane

Build the image (or use one CI built), and keep its settings in a file
only root can read:

```sh
docker build -f docker/control-plane.Dockerfile -t foreman .

sudo install -d -m 0700 /etc/foreman
printf '%s\n' \
  "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')" \
  "FOREMAN_ENCRYPTION_KEY=$(openssl rand -base64 32)" \
  "PHX_HOST=desktop.tail1234.ts.net" \
  "FOREMAN_LISTEN_IP=0.0.0.0" \
  "FOREMAN_ADMINS=your-github-login" \
  "FOREMAN_AGENT_RELEASE_DIR=/var/lib/foreman/releases" | sudo tee /etc/foreman/foreman.env >/dev/null
sudo chmod 0600 /etc/foreman/foreman.env

docker run -d --name foreman --restart unless-stopped \
  --env-file /etc/foreman/foreman.env \
  -p 127.0.0.1:4000:4000 \
  -v foreman-data:/var/lib/foreman \
  foreman
```

`PHX_HOST` is the desktop's MagicDNS name (`tailscale status --json |
jq -r .Self.DNSName`, without the trailing dot). Keeping published agent
releases in the data volume means they survive a container recreate. The port is published on
loopback only; Tailscale serves it to the tailnet over HTTPS:

```sh
sudo tailscale serve --bg --https=443 http://127.0.0.1:4000
```

If your tailnet policy isn't the default allow-all, your laptops won't
see the desktop until a rule lets them reach it. Tag the desktop
`tag:foreman` and grant your machines port 443 on it; see
[tailscale.md](tailscale.md#the-control-plane-host). Firefox reporting
"Server Not Found" for the `.ts.net` name usually means exactly this.

**Back up `FOREMAN_ENCRYPTION_KEY`.** Every secret, token and key in the
database is encrypted with it; without it they're gone.

## 2. Connect GitHub

Open `https://desktop.tail1234.ts.net/setup`. It asks for a one-time
setup token, which is in the log:

```sh
docker logs foreman 2>&1 | grep -A1 "setup token"
```

Then create the GitHub App on your account (one click on GitHub) and
install it on the repos Foreman should see. See
[github-app.md](github-app.md). Sign in with GitHub afterwards; with
`FOREMAN_ADMINS` set to your login, you're the admin.

## 3. Connect Tailscale

Create an OAuth client and set `FOREMAN_TAILSCALE_CLIENT_ID` and
`FOREMAN_TAILSCALE_CLIENT_SECRET` in `/etc/foreman/foreman.env`, then
recreate the container. See [tailscale.md](tailscale.md). Without it,
environments still work, but you reach them with `docker exec` on the
box instead of over the tailnet.

## 4. Publish an agent release

Boxes install and update the agent from releases the control plane
serves. CI builds and signs them (the signing key never touches the
control plane). By hand:

```sh
cd apps/foreman_agent
mix foreman_agent.sign --keygen   # once; keep the private key out of the repo

docker build -f docker/box.Dockerfile --target agent-tarball \
  --build-arg FOREMAN_AGENT_VERSION=0.1.0 \
  --build-arg FOREMAN_RELEASE_PUBLIC_KEY=<public key> \
  -o out .
FOREMAN_RELEASE_PRIVATE_KEY=<private key> \
  mix foreman_agent.sign 0.1.0 linux-amd64 out/foreman_agent.tar.gz   # prints the signature
```

Add `FOREMAN_AGENT_RELEASE_PUBLIC_KEY=<public key>` to the control
plane's settings, then register the tarball:

```sh
docker cp out/foreman_agent.tar.gz foreman:/tmp/agent.tar.gz
docker exec foreman env -u PHX_SERVER /app/bin/foreman eval \
  'Foreman.Release.publish_agent("0.1.0", "linux-amd64", "/tmp/agent.tar.gz", "<signature>")'
```

Build on the box's architecture (`linux-arm64` on ARM). To roll a newer
version out later, publish it and set each box's desired agent version
on its page.

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

## 6. Make an environment

**New environment**: pick a repo and the box. The first build pulls
images and takes a few minutes. After that, `ssh vscode@storefront-1` (or
whatever the devcontainer's remote user is) from any machine on the
tailnet, or open it in VS Code from the environment's page.

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
| `FOREMAN_TAILSCALE_TAGS` | `tag:foreman-env` | Tags every environment gets |
| `FOREMAN_GITHUB_APP_ID`, `_CLIENT_ID`, `_CLIENT_SECRET`, `_PRIVATE_KEY` (or `_PRIVATE_KEY_FILE`) | | Instead of the manifest flow |
| `FOREMAN_AGENT_RELEASE_PUBLIC_KEY` | | Verifies agent releases you publish |
| `FOREMAN_AGENT_RELEASE_DIR` | system temp dir | Where published releases are kept; set it to a persistent path |
| `FOREMAN_BASE_URL` | `https://PHX_HOST` | The URL agents and GitHub are given |
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
