# End-to-end runs

The runs here use the real pieces wherever they can (Docker, Cloud
Hypervisor, the devcontainer CLI) and the fixture repo in
`apps/foreman_agent/test/fixtures/repos/hello` (an app service and a
sidecar that reads `${SIDECAR_TOKEN}`).

## Through the UI (macOS or Linux)

A dev control plane and a local agent, driven by a headless Chromium
browser over the DevTools protocol (`cdp.mjs`, no npm dependencies).

An agent run with `mix` can't run environment VMs: they need the agent
release, the root helper the install script sets up, a guest image and
KVM. Its box says it can't run environments, and the control plane
won't place one there, so only the page tour (`ONLY=pages`) works this
way now. `vm/run.sh`, below, runs environments for real.

```sh
# Serve the fixture repo over git's dumb HTTP protocol
e2e/make-git-fixture.sh tmp/e2e/git
(cd tmp/e2e/git && python3 -m http.server 8899 --bind 127.0.0.1) &

# Control plane, with clone URLs pointed at the fixture server
cd apps/foreman
rm -f foreman_dev.db* && mix ecto.setup
mix run ../../e2e/seed.exs            # prints E2E_JOIN_TOKEN=fj_...
PORT=4100 FOREMAN_GIT_BASE_URL=http://127.0.0.1:8899 mix phx.server &

# Agent, enrolled with the printed token (it can't run environments)
cd ../foreman_agent
R=$(cd ../.. && pwd)
FOREMAN_URL=http://localhost:4100 FOREMAN_JOIN_TOKEN=fj_... \
  FOREMAN_AGENT_DATA_DIR=$R/tmp/e2e/agent FOREMAN_ENVS_ROOT=$R/tmp/e2e/envs \
  FOREMAN_SECRETS_ROOT=$R/tmp/e2e/run FOREMAN_RELEASE_ROOT=$R/tmp/e2e/opt \
  FOREMAN_DEVCONTAINER_CLI=$R/.tools/node_modules/.bin/devcontainer \
  FOREMAN_ALLOWED_GIT_HOSTS=127.0.0.1 FOREMAN_INSECURE_GIT_HOSTS=127.0.0.1 \
  mix run --no-halt &

# The page tour: sign in, every page, dark mode
cd ../.. && ONLY=pages node e2e/local.mjs   # screenshots in tmp/e2e/shots
```

Without `ONLY=pages`, `local.mjs` also creates an environment, waits for
it, adds a secret, runs Restart affected, reads container logs and
destroys it, which needs a box that can run environments.

`BROWSER` picks the browser binary (default: Microsoft Edge on macOS);
any Chromium works.

## On an emulated Linux box

The control plane release image, and a box image with what the install
script expects of a box (systemd, nftables, iproute2, e2fsprogs) and
nothing of Foreman's; it has Docker too, like a box that also runs the
control plane. The box container runs privileged to boot systemd. CI's
Crew VMs have no KVM, so the box can't run environment VMs; this run
checks that it says so instead (`e2e/vm/run.sh` runs environments for
real). `run.sh` builds both images, publishes agents with
`scripts/publish-agent-release.sh` (`bin/gh` stands in for the GitHub
release), and installs the agent with the install script the control
plane serves. It checks enrollment, single-use join tokens, a re-run of
the install script, the box's VM report and an environment refused for
it, the VM helper being root's, a box reboot, a signed agent
self-update, `--reenroll` after a revoke, and the systemd unit rolling
back an update that crash-loops. CI runs it on every push.

```sh
e2e/linux/run.sh                 # SKIP_BUILD=1 to reuse images
e2e/linux/run.sh --logs          # the stack's logs and the box's journal
e2e/linux/run.sh --down          # remove the stack and its volumes
```

It needs `openssl`, and Elixir for `mix foreman_agent.sign` (through
`mise` if it's installed). `E2E_PROJECT` names the compose project and
images, so runs can share a Docker daemon.

`agent-smoke.sh` starts an agent release on Ubuntu 22.04 and 24.04 and
Debian 12 and 13, in this machine's architecture. CI runs it on whichever
arch its Crew VM has, and the release workflow on both before signing:

```sh
docker build -f docker/box.Dockerfile --target agent-tarball -o tmp/agent .
e2e/agent-smoke.sh tmp/agent/foreman_agent.tar.gz
```

## The guest image

`e2e/guest/run.sh` boots the guest system image (`guest/build.sh`) under the
Cloud Hypervisor the agent release carries, with the release on the VM's
agent disk and no network, and has the agent on this machine drive the
agent in the VM over hybrid vsock: hello, the inventory and ports
queries, `box.gc` run in the guest, and `box.restart` refused there. It
then boots the VM again on the same data disk, which mustn't be
formatted twice. CI runs it on a GitHub-hosted runner, since Crew's VMs
have no KVM. It needs `/dev/kvm`, `zstd` and `mkfs.ext4`, and no root.

```sh
guest/build.sh tmp/guest
docker build -f docker/box.Dockerfile --target agent-tarball -o tmp/agent .
e2e/guest/run.sh tmp/guest/foreman-guest-linux-amd64.tar tmp/agent/foreman_agent.tar.gz
```

## Environment VMs, for real

`vm/run.sh` runs environments in Cloud Hypervisor VMs on the machine it
runs on: the control plane release image in Docker, the agent installed
with the served install script, and a git server for the fixture repo on
a stand-in for the box's LAN (a network namespace). Each environment's
`postStartCommand` probes what it can reach and prints the result into
its operation's log. It checks the box's VM report, the VM helper being
root's, a VM's unit (its user, limits, no capabilities, seccomp), that an
environment reaches the internet and the LAN but not the box or another
environment, a privileged docker-in-docker sidecar running, a secret
reaching the guest after a stop and a start, an agent restart leaving
the VMs running, and destroy leaving nothing behind.

It installs the agent and changes the machine's network, so it refuses
to run without `E2E_VM_THROWAWAY=1`; CI runs it on a GitHub-hosted runner,
which has KVM and is thrown away after. It needs KVM, Docker, sudo,
python3, zstd and Elixir (for `mix foreman_agent.sign`).

```sh
E2E_VM_THROWAWAY=1 e2e/vm/run.sh
```

`vmctl/test.sh` checks the root helper for environment VMs
(`priv/vm/vmctl`) with stand-ins for `ip`, `systemctl` and `systemd-run`:
what it refuses, the addresses it hands out, and the command line it
builds. It needs no root.

## A Flatcar box, for real

`flatcar/run.sh` makes a box the way a person would, with `vm.sh` (QEMU
and KVM, with sudo). It runs on Linux only: Mac boxes, and `mac.sh`, are
gone until [#180](https://github.com/ntodd/foreman/issues/180). The
control plane is the release image, published on this machine for the
VM to reach. It checks that a bad token leaves nothing behind; the box's
first boot, Ignition and enrollment; what's on the box (Flatcar, Compose
and Tailscale from the bakery, the VM helper being root's, both firewall
tables and the reload check, the reboot unit, no Node, no failed units,
the join token gone); the box reporting it can run environment VMs,
nested; the Reboot button (clicked through the LiveView with
`lv-click.mjs`), which brings the box back on a new boot; the VM's
process dying; the launcher run again; an agent update; and the
launcher's stop, start and uninstall. It doesn't make an environment:
`vm/run.sh` covers those.

```sh
e2e/flatcar/run.sh                   # SKIP_BUILD=1 to reuse the images and agents
E2E_OS_UPDATE=1 e2e/flatcar/run.sh   # also a Flatcar update (moves the box to beta)
e2e/flatcar/run.sh --logs            # the control plane's logs and the box's console
e2e/flatcar/run.sh --down            # remove the stack and the box
```

It runs the box under its own systemd unit (`E2E_PROJECT`, default
`foreman-flatcar`), so it doesn't touch a real box on the same machine.
The machine needs nested virtualization for the box to report it can
run environment VMs. With `FOREMAN_TAILSCALE_CLIENT_ID` and
`FOREMAN_TAILSCALE_CLIENT_SECRET`, the box also joins the tailnet with a
key the control plane mints.

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

It predates environment VMs: it still runs its agent with `mix` against
this machine's Docker, and such an agent can't run environments now (see
[Through the UI](#through-the-ui-macos-or-linux)), so it fails at the
create until it's moved onto a box that can.

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

## Layout checks

`layout.mjs` opens every page of the demo control plane at 390, 768, 1024
and 1440px and fails if a page scrolls sideways or leaves no room for text
it shows, like a table whose fixed columns squeeze the name column to
nothing on a phone. Run it after a UI change, against a running demo:

```sh
node e2e/layout.mjs
```
