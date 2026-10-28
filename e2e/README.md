# End-to-end runs

Two runs, both against real Docker and the real devcontainer CLI, using
the fixture repo in `apps/foreman_agent/test/fixtures/repos/hello` (an
app service and a sidecar that reads `${SIDECAR_TOKEN}`).

## Through the UI (macOS or Linux, Docker Desktop is fine)

A dev control plane and a local agent, driven by a headless Chromium
browser over the DevTools protocol (`cdp.mjs`, no npm dependencies).

```sh
# Serve the fixture repo over git's dumb HTTP protocol
e2e/make-git-fixture.sh tmp/e2e/git
(cd tmp/e2e/git && python3 -m http.server 8899 --bind 127.0.0.1) &

# Control plane, with clone URLs pointed at the fixture server
cd apps/foreman
rm -f foreman_dev.db* && mix ecto.setup
mix run ../../e2e/seed.exs            # prints E2E_JOIN_TOKEN=fj_...
PORT=4100 FOREMAN_GIT_BASE_URL=http://127.0.0.1:8899 mix phx.server &

# Agent, enrolled with the printed token, driving Docker Desktop
cd ../foreman_agent
R=$(cd ../.. && pwd)
FOREMAN_URL=http://localhost:4100 FOREMAN_JOIN_TOKEN=fj_... \
  FOREMAN_AGENT_DATA_DIR=$R/tmp/e2e/agent FOREMAN_ENVS_ROOT=$R/tmp/e2e/envs \
  FOREMAN_SECRETS_ROOT=$R/tmp/e2e/run FOREMAN_RELEASE_ROOT=$R/tmp/e2e/opt \
  FOREMAN_DEVCONTAINER_CLI=$R/.tools/node_modules/.bin/devcontainer \
  FOREMAN_ALLOWED_GIT_HOSTS=127.0.0.1 FOREMAN_INSECURE_GIT_HOSTS=127.0.0.1 \
  mix run --no-halt &

# The run: sign in, create an environment, wait for it, add a secret,
# Restart affected, container logs, every page, dark mode, destroy.
cd ../.. && node e2e/local.mjs          # screenshots in tmp/e2e/shots
ONLY=pages node e2e/local.mjs           # just the page tour
```

`BROWSER` picks the browser binary (default: Microsoft Edge on macOS);
any Chromium works.

## On an emulated Linux box

The control plane release image, and a box image with what the install
script expects of a box (systemd, Docker Engine, git, Node) and nothing
of Foreman's. The box container runs privileged to boot systemd and host
its own Docker daemon, the way a real box's Docker runs on its host; the
environments inside it don't. `run.sh` builds both, publishes agents with
`scripts/publish-agent-release.sh` (`bin/gh` stands in for the GitHub
release), and installs the agent with the install script the control
plane serves. It checks enrollment, single-use join tokens, a re-run of
the install script, create, what's inside an environment (identity,
feature, read-only secrets, no published ports, uid mapping, 0600
secrets other users can't read), secrets delivery, a box reboot (tmpfs
secrets restored and the environment restarted), a signed agent
self-update, destroy, `--reenroll` after a revoke, and the systemd unit
rolling back an update that crash-loops. CI runs it on every push.

```sh
e2e/linux/run.sh                 # SKIP_BUILD=1 to reuse images
e2e/linux/run.sh --logs          # the stack's logs and the box's journal
e2e/linux/run.sh --down          # remove the stack and its volumes
```

It needs `openssl`, and Elixir for `mix foreman_agent.sign` (through
`mise` if it's installed). `E2E_PROJECT` names the compose project and
images, so runs can share a Docker daemon.

`agent-smoke.sh` starts an agent release on Ubuntu 22.04 and 24.04 and
Debian 12 and 13, in this machine's architecture. CI runs it for amd64,
and the release workflow for both architectures before signing:

```sh
docker build -f docker/box.Dockerfile --target agent-tarball -o tmp/agent .
e2e/agent-smoke.sh tmp/agent/foreman_agent.tar.gz
```

## On a real tailnet

The other runs don't have a tailnet, so they can't check Tailscale SSH.
`tailnet.sh` runs a dev control plane with your Tailscale OAuth client
and a local agent, creates an environment from the fixture repo, and
checks it from this machine over the tailnet: no `NET_ADMIN` or TUN
device in the devcontainer, Tailscale SSH into it as `vscode`, its ports
by name and address, compose DNS untouched, and the device gone after
destroy. Your dev database is moved aside and put back afterwards.

```sh
FOREMAN_TAILSCALE_CLIENT_ID=... FOREMAN_TAILSCALE_CLIENT_SECRET=... e2e/tailnet.sh
```

It needs Tailscale running on this machine, on the same tailnet; an
OAuth client with the `auth_keys` and `devices` scopes that owns
`tag:foreman-env`; and a tailnet policy that lets you SSH to
`tag:foreman-env` as `vscode` (see [docs/setup/tailscale.md](../docs/setup/tailscale.md)).
If VS Code is installed, it pauses before destroying the environment so you can try it.

## README screenshots

`demo.exs` starts a dev control plane on its own database
(`tmp/demo`) with made-up boxes, repos and environments. Stand-in agent
processes keep the boxes online; nothing touches Docker, GitHub or a
tailnet. `screenshots.mjs` captures five pages in light and dark at 2x
and frames each in a browser window, writing `docs/images/`.

```sh
cd apps/foreman
PORT=4100 mix run --no-start ../../e2e/demo.exs &
cd ../.. && node e2e/screenshots.mjs
```

`DEMO=personal` seeds one person on one box instead, in `tmp/demo-personal`,
for the simpler views a personal instance gets.
