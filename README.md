# Foreman

Foreman is a self-hosted stand-in for GitHub Codespaces. You point it at a
repo with a compose-based devcontainer and one of your own machines. It
clones the repo there, builds the devcontainer, hands it its secrets and
puts it on your tailnet. Run as many copies of the same repo side by side
as you like. None of them publish a port.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/environments-dark.png">
  <img alt="The Environments page: three boxes with CPU and memory bars, a state filter and a box filter, and nine environments in a table, the signed-in user's under My environments and the rest under Others, each with its owner's avatar, box and state" src="docs/images/environments-light.png">
</picture>

## How it works

The control plane (`apps/foreman`) is a Phoenix app you reach only over
your tailnet. It's what you use in the browser, and it keeps track of
users, repos, boxes, environments, secrets and the audit log. It runs on
SQLite for one person or Postgres for a team.

A machine that hosts environments is a box, and it runs the agent
(`apps/foreman_agent`), an Elixir release. A box can be a Linux machine
running the install script, or Flatcar Container Linux: in a VM on a Mac
or a Linux machine, or on bare metal, set up on its first boot from a
config the control plane makes, and updating its OS itself. The agent dials out to the
control plane over a WebSocket, so boxes need no open ports, and every
message is signed with ed25519. When the control plane asks for an
environment, the agent brings it up with `git`, `docker compose` and the
devcontainer CLI. It updates itself when a new release comes out.

On top of each repo's own config, Foreman adds a devcontainer feature
(`features/src/foreman`). It installs Tailscale with Tailscale SSH, the
shell hook that loads secrets, your git identity and a credential helper
for GitHub. Your laptop reaches an environment over the tailnet, by name,
with ssh, an editor or a browser.

The commands and events the two sides exchange live in
`apps/foreman_protocol`, so both ends validate messages with the same code.

[docs/architecture.md](docs/architecture.md) explains the design and why
it's built that way. [docs/security.md](docs/security.md) covers the
security model.

## What you get

Any repo the GitHub App can see that has a compose-based devcontainer can
become an environment. Environments are named `<repo>-<n>` on a personal
setup or `<repo>-<login>-<n>` on a team one. That one name is the compose
project, the Tailscale hostname and what you type after `ssh <user>@`.

Secrets come at four levels: owner, repo, user and environment. They're
encrypted at rest and can't be read back in the UI. On the box they land
on a tmpfs, and login shells load them from there. When one changes, new
shells see it right away and Foreman asks whether to restart the affected
services, restart everything, or leave it for later.

Each environment gets its own GitHub token, scoped to its repo, and
Foreman refreshes it every few hours. A repo can opt to use the person's
own token instead. Git identity and dotfiles are set per person, with
per-repo overrides.

Environments run unprivileged. Foreman refuses privileged containers
(docker-in-docker included), host namespaces, the Docker socket and host
mounts, and it checks devcontainer features as well as the repo's own
files. A box can allow one of these as an exception, and the control
plane flags that box in red. Anything that needs its own daemon belongs
in the compose file as a sidecar;
[docs/setup/repos.md](docs/setup/repos.md#docker-inside-an-environment)
shows how.

A devcontainer feature can ship a connect hook (Orca's does). The
environment page then shows the owner a pairing code or QR code, once.
See [docs/setup/connect-hooks.md](docs/setup/connect-hooks.md).

Boxes report used and provisioned CPU and memory and warn about
contention. They allow overcommit by default and can be set to warn or
refuse instead. A box joins with a one-time token. After a reboot the
control plane puts its secrets back and restarts its environments. Boxes
update their agents from signed releases, and a release is a single tag:
it builds the control plane images on GHCR with the matching agents
inside, and the boxes follow.

## A look around

An environment just after one of its secrets changed. New shells already
have the new value. Running services keep the old one until you pick a
restart.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/environment-dark.png">
  <img alt="An environment page: Stop and an Actions menu in the header, a Secrets changed callout with Restart affected, Restart all and Later, the Tailscale SSH command, and Open in VS Code and Open in Zed buttons" src="docs/images/environment-light.png">
</picture>

The Boxes page puts live CPU and memory trends next to what's provisioned.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/boxes-dark.png">
  <img alt="The Boxes page: three online boxes, each with a live CPU and memory trend line and provisioned CPU and memory bars" src="docs/images/boxes-light.png">
</picture>

A box over the last day. CPU and memory stack each environment's share
under the box total. Disk sits next to them, and load is drawn against the
core count. Ranges go from 15 minutes to 7 days, and the charts update
every 5 seconds.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/box-dark.png">
  <img alt="A box page: a range picker set to 1d, and four charts. CPU and Memory stack three environments under a box total line; Disk is a flat line at 590 of 1800 GiB; Load peaks under the 16-core line" src="docs/images/box-light.png">
</picture>

Your own secrets. Values are encrypted and can't be read back.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/secrets-dark.png">
  <img alt="The Secrets page: two secrets with Replace and delete, and a form to add one, optionally limited to some repos" src="docs/images/secrets-light.png">
</picture>

The screenshots use made-up data. `e2e/demo.exs` and `e2e/screenshots.mjs`
regenerate them; see [e2e/README.md](e2e/README.md).

## Running it

| Setup | Guide |
|---|---|
| Personal (a Linux desktop, SQLite) | [docs/setup/personal.md](docs/setup/personal.md) |
| Team (EC2 + Postgres/Neon, a box per developer) | [docs/setup/team.md](docs/setup/team.md) |
| A Mac as a box (a Flatcar VM, started at login) | [docs/setup/mac.md](docs/setup/mac.md) |
| Flatcar boxes (a VM on Linux, or bare metal) | [docs/setup/flatcar.md](docs/setup/flatcar.md) |
| Upgrading, backups and rolling back | [docs/setup/upgrading.md](docs/setup/upgrading.md) |
| The GitHub App | [docs/setup/github-app.md](docs/setup/github-app.md) |
| Tailscale | [docs/setup/tailscale.md](docs/setup/tailscale.md) |
| Private registry (GHCR) credentials | [docs/setup/ghcr-machine-user.md](docs/setup/ghcr-machine-user.md) |
| Moving a repo off Codespaces | [docs/setup/repos.md](docs/setup/repos.md) |
