# Foreman architecture

Status: draft, 2026-10-13

Foreman is a self-hosted replacement for GitHub Codespaces. A Phoenix control plane manages devcontainer environments on Linux boxes you own. A small agent on each box does the work. Every environment joins a Tailscale tailnet, and that's how you reach it. Nothing publishes ports.

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
- Multi-tenancy. Each deployment serves one team. The personal and work setups are separate deployments.
- A browser editor. You connect with your own editor or tools over SSH on the tailnet.
- Remote IDE integration. Remote IDEs reach environments over SSH on the tailnet, which Foreman already provides.
- Non-compose devcontainers (`image` / `dockerFile` configs) in v1. Every target repo uses compose.

## Deployments

| | Personal | Work |
|---|---|---|
| Control plane | Linux desktop | Small EC2 instance |
| Database | Postgres on the desktop | RDS, or Postgres on the same instance |
| Boxes | The desktop (local agent) | One or more Linux boxes per developer |
| Users | 1 | 4 |
| GitHub App installed on | `ntodd` | `acme` |
| Tailnet | Personal | Work (Standard plan) |

Both deployments run the same code with different config. Company secrets never live on the personal deployment.

## Components

```
Browser ──LiveView──► Control plane (Phoenix + Postgres, tailnet-only)
                         ▲  WSS (agent dials out)
          ┌──────────────┼───────────────┐
     agent (desktop)  agent (box-a)  agent (box-b)
          │  Docker Engine API + @devcontainers/cli
     environment containers ── tailscaled ──► tailnet ◄── laptops
```

### Control plane

A Phoenix app that owns all durable state: users, repos, secrets, boxes, environments, desired state and the audit log.

- **UI:** LiveView. Environment status, build logs and box usage stream live.
- **Agent link:** Phoenix Channels, with Presence tracking which agents are online.
- **One GenServer per environment:** a state machine that sends commands to the agent and records the results.
- **Oban:** durable jobs such as GitHub token refresh, Tailscale device cleanup, idle auto-stop and agent update rollouts.
- **Encryption:** Cloak.Ecto for secrets and stored GitHub tokens.

It is reachable only on the tailnet; see [Networking](#networking).

### Agent

An Elixir release running under systemd on each box, as a dedicated `foreman` user in the `docker` group.

- It connects out to the control plane over WSS with Slipstream.
- It uses the Docker Engine API (unix socket) for inventory, start/stop, logs and stats.
- It shells out to `@devcontainers/cli` only for `up` and builds.
- It runs child processes under MuonTrap, so cancelling an operation kills the whole process tree.
- It holds no durable state of its own. The control plane owns desired state, and Docker labels on the box record what exists (`foreman.env_id`, `foreman.repo`, `foreman.owner`).

The local agent on the personal desktop is the same binary, pointed at `localhost`. There is no separate local runner.

**Host prerequisites:**
- Linux
- Docker Engine with Compose v2.24+ (needed for the `!reset` tag)
- git
- Node with a pinned `@devcontainers/cli`
- Tailscale on the host, because the control plane is tailnet-only

### Environment

One devcontainer compose project, plus a Foreman overlay and the Foreman devcontainer feature. An environment belongs to one user, one repo and one box.

## Agent protocol

### Enrollment and auth

1. An admin creates a one-time join token in the UI.
2. The install script runs on the box: `curl …/install.sh | sh -s -- --token …`.
3. The agent generates an ed25519 keypair and registers its public key using the join token. The token is then consumed.
4. On every connect, the agent sends `agent_id`, a timestamp and a signature over both, in a header. The control plane checks the signature against the stored public key and rejects clocks more than 60s off.
5. Revoking an agent deletes its public key. Its socket is disconnected immediately.

Distributed Erlang is not used between the control plane and agents. It is a full-trust mesh, so any connected node could run code on any other.

### Messages

Each agent joins topic `agent:<agent_id>`. Commands are a fixed vocabulary; there is no generic `exec`.

| Command | Purpose |
|---|---|
| `env.create` | Clone, write overlay and secrets, `devcontainer up` |
| `env.start` / `env.stop` / `env.restart` | Lifecycle |
| `env.rebuild` | Recreate containers, keeping volumes and the clone |
| `env.destroy` | Remove containers, volumes and the clone |
| `env.secrets.write` | Rewrite the environment's tmpfs secrets directory |
| `env.logs` | Stream container or build logs |
| `env.git_status` | Dirty tree / unpushed commits check before destroy |
| `box.inventory` | Report environments found via Docker labels |
| `box.stats` | Report CPU, memory and disk, per environment and in total |
| `box.gc` | Prune unused images, build cache and orphaned volumes |
| `agent.update` | Install a new agent release |

Every command carries an `op_id`. The agent records in-flight `op_id`s, so a command retried after a reconnect is not run twice. Long operations keep running if the socket drops. The agent sends their progress and result once it reconnects.

The agent sends its version and protocol version when it joins. The control plane must accept protocol N and N-1 during rollouts.

### Reconciliation

When an agent joins, it reports what's on the box. The control plane compares that with the desired state of each environment (`running`, `stopped` or `destroyed`) and sends the commands needed to match.

The overlay sets `restart: "no"` on every service, so the agent controls start order after a host reboot. That matters because secrets live on tmpfs, which a reboot clears:

1. The box boots and the agent starts and connects.
2. The control plane resolves secrets and sends `env.secrets.write`.
3. The control plane sends `env.start` for every environment whose desired state is `running`.

As a result, environments don't come back after a reboot until the control plane is reachable. The personal control plane runs on the same box, so this only affects the work deployment.

## Environment lifecycle

### Naming

- **Slug:** `<repo>-<n>` on the personal deployment, `<repo>-<login>-<n>` on work. For example `storefront-2` or `monolith-ntodd-1`.
- **The slug is used as:**
  - the compose project name (`COMPOSE_PROJECT_NAME`), which makes every named volume unique per copy
  - the Tailscale hostname
  - the clone directory: `/srv/foreman/envs/<env_id>/<repo>`
- **Secrets directory:** `/run/foreman/envs/<env_id>/` on the host (tmpfs).

### Create flow

1. The control plane picks the box, then resolves the slug, secrets, GitHub token and Tailscale auth key.
2. The agent writes the secrets directory.
3. The agent clones the repo. It uses a credential helper that reads the token file, so the token never appears in the URL or `.git/config`.
4. The agent reads `.devcontainer/devcontainer.json` (JSONC) and writes two files to its own directory:
   - an override config that appends the overlay to `dockerComposeFile`, using absolute paths
   - the overlay itself

   If `--override-config` can't add the overlay (spike 1), repos opt in instead: each lists a gitignored `foreman.compose.yml` in `dockerComposeFile`, and the agent writes that file into the clone.
5. The agent runs, with `COMPOSE_PROJECT_NAME` set and compose-interpolated secrets in the process environment:

   ```
   devcontainer up \
     --workspace-folder <clone> \
     --override-config <override> \
     --id-label foreman.env_id=<id> \
     --additional-features '{"ghcr.io/ntodd/foreman-features/foreman:1": {}}' \
     [--dotfiles-repository <user's dotfiles repo>]
   ```

   Build output streams back to the UI.
6. The agent reports the result. The control plane records the Tailscale device ID once the node shows up.

### Generated overlay

```yaml
services:
  app:                      # the devcontainer's "service"
    ports: !reset []
    restart: "no"
    volumes:
      - /run/foreman/envs/<env_id>:/run/foreman:ro
      - tailscale-state:/var/lib/tailscale
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      FOREMAN_ENV: <slug>
      TS_HOSTNAME: <slug>
    # cpus / mem_limit only when limits are set (see Capacity)
  db:                       # every other service gets the same reset
    ports: !reset []
    restart: "no"

volumes:
  tailscale-state:
```

### Foreman feature

A public devcontainer feature (`ghcr.io/ntodd/foreman-features/foreman`). The agent adds it with `--additional-features`, so repos don't declare it.

- **Tailscale:**
  - Installs `tailscale` and `tailscaled` from the static tarball, with a checksum check.
  - Requests the `NET_ADMIN` and `NET_RAW` capabilities.
  - Its `entrypoint` starts tailscaled and runs `tailscale up --ssh --auth-key=file:/run/foreman/ts-authkey --hostname=$TS_HOSTNAME …`.
  - It falls back to userspace networking when there is no TUN device. This is a port of the current `tailscale-up.sh`.
  - Because it is an entrypoint, it runs on every container start, including `docker restart`. A `postStartCommand` only runs when the devcontainer CLI starts the container.
- **Secrets hook:** installs `/etc/profile.d/foreman.sh`, which sources `/run/foreman/secrets.env`. A zsh equivalent goes in `/etc/zsh/zprofile`. The hook also prints `/run/foreman/notices` when it isn't empty.
- **Git:**
  - Installs an `/etc/gitconfig` that includes `/run/foreman/gitconfig`.
  - Installs a git credential helper that reads `/run/foreman/github-token`.
  - Points `gh` at the same token file.
- **Ownership:** Tailscale bootstrap now belongs to the feature. Repo-level copies (`install-tailscale.sh`, `tailscale-up.sh`, the shared `devcontainer-authkey` mount) go away.

### Stop, rebuild, destroy

- **Stop:** `docker compose stop`. Sidecars get a graceful shutdown; for example, monolith's Neon Local deletes its branch on stop.
- **Rebuild:** `devcontainer up --remove-existing-container`. Named volumes, the clone and the Tailscale identity survive.
- **Destroy:**
  1. The agent runs `env.git_status`. The UI warns about a dirty tree or unpushed commits.
  2. The agent runs `docker compose down -v` and deletes the clone and the secrets directory.
  3. The control plane deletes the Tailscale device through the API.

## Networking

### Tailscale per environment

- **Auth keys:** the control plane holds a Tailscale OAuth client with the `auth_keys` scope. It mints one key per environment (`?ephemeral=false&preauthorized=true`) tagged `tag:foreman-env`, plus any tags configured on the repo (storefront uses `tag:staging-access`).
  - Tagged devices have key expiry disabled.
  - The auth key is only needed the first time. State persists in the `tailscale-state` volume, so rebuilds keep the same node.
- **Hostname:** the slug, so you reach environments at `storefront-2`, `storefront-2:4000`, and so on.
- **HTTPS:** a plain-HTTP tailnet hostname is not a secure context, which breaks secure cookies, WebAuthn, clipboard access and service workers. Repos that need those run `tailscale serve` to get `https://<slug>.<tailnet>.ts.net`.
  - Hostnames land in public certificate transparency logs, so keep them bland.
  - Let's Encrypt rate limits are another reason to keep state persistent.
- **SSH:** Tailscale SSH.
  - The feature runs `tailscale up --ssh`, so `ssh nate@storefront-2` works on port 22 with no keys and no sshd.
  - Tailnet ACLs decide who can log in as which local user.
  - SSH rules use `action: accept`, not `check`, so editors aren't sent to re-authenticate.
  - Remote IDEs need nothing more.
- **DNS:** `--accept-dns` points `resolv.conf` at MagicDNS, which forwards to Docker's resolver. The feature keeps the existing check that compose service names still resolve.
- **Cleanup:** an Oban job removes tailnet devices that no longer match a live environment.

### ACLs

Each environment is a full tailnet node, and anything running inside it (an npm postinstall script, for example) can use the network.

- `tag:foreman-env` may not initiate connections to user devices or to other environments.
- Repo tags grant extra access when needed.
- Work: environments also carry a per-developer tag (`tag:foreman-<login>`), owned by the OAuth client. That lets SSH and network rules limit each developer to their own environments. Whether developers can reach each other's environments is a team decision.

### Control plane exposure

The control plane listens only on the tailnet.
- The GitHub OAuth redirect happens in the browser, so a tailnet hostname works as the callback.
- GitHub webhooks would need public ingress, so v1 polls. If webhooks become necessary, expose one path with Tailscale Funnel.

### Pricing note

The Personal plan is free but non-commercial only. Work needs Standard ($8/seat/month), which includes 50 tagged devices and charges $1/month for each one after that. Environment nodes count as tagged devices, so cleaning up dead nodes saves money.

A Mac can be on only one tailnet at a time, so working on both deployments means switching between tailnets.

## Secrets

### Scopes and precedence

Secrets resolve in order of increasing priority:

1. **Owner:** the GitHub org, or the user account for personal repos.
2. **Repo**
3. **User:** applies to all of the user's environments, or to selected repos only.
4. **Environment:** applies to one environment. Useful when a second copy needs a different value.

Values are write-only in the UI: once saved, they can be replaced but not read back. Every change goes to the audit log.

- **Encryption:** Cloak.Ecto with AES-GCM. The personal key lives in the deployment's environment. The work key lives in AWS KMS or Secrets Manager.
- **Permissions:**
  - Owner and repo secrets: admins.
  - User secrets: the user.
  - Environment secrets: the environment's owner.

### Delivery

The control plane resolves secrets and sends the plaintext over WSS (TLS). The agent writes them atomically (write a temp file, then rename) into `/run/foreman/envs/<env_id>/` on tmpfs. That directory is bind-mounted read-only at `/run/foreman`. It is mounted as a directory rather than as individual files: an atomic rename replaces the inode, and a file-level bind mount would keep showing the old one.

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
| Compose interpolation (`${VAR}` in compose files) | monolith's Neon Local sidecars | After the affected services are recreated |
| GitHub token file | git, `gh` | On the next use; no restart needed |

Foreman doesn't use `--secrets-file` or `--remote-env`. The devcontainer CLI passes those values as `-e NAME=VALUE` on the host's `docker exec` command line, where any user on the box can read them with `ps` ([devcontainers/cli#1317](https://github.com/devcontainers/cli/issues/1317), open).

The same issue covers environment variables probed from login shells during lifecycle hooks, and those include sourced secrets. On shared boxes, mount `/proc` with `hidepid=2`.

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

A GitHub App, installed on `ntodd` for personal and on `acme` for work (the org install needs admin approval).

- **Login:** the app's user OAuth flow. Membership in the installed org (or a configured team) controls who can log in to the work deployment.
- **Tokens:** user access tokens last 8 hours. Refresh tokens last 6 months and are single-use. Refreshes are serialized per user with a row lock, so two concurrent refreshes can't burn the same refresh token.
- **Repo browsing:**
  - List the installation's repos.
  - Mark the ones that have `.devcontainer/devcontainer.json`, `.devcontainer.json` or `.devcontainer/*/devcontainer.json`.
  - Cache the results and refresh them by polling.

### Environment tokens

By default, each environment gets a scoped user token from `POST /applications/{client_id}/token/scoped`.

- **Scope:**
  - **Repos:** the environment's repo plus any extra repos configured on it.
  - **Permissions:** configured per repo, defaulting to `contents:write`, `pull_requests:write`, `issues:write` and `metadata:read`.
- **Identity:** the token acts as the user, so commits are pushed and PRs opened as you, not as a bot. At work that keeps "can't approve your own PR" rules meaningful.
- **Refresh:** scoped tokens come without a refresh token. An Oban job refreshes the parent token and re-scopes it every few hours, then sends the new file through `env.secrets.write`.
- **Opt-out:** a per-repo setting gives that repo's environments the user's unscoped token. Use it for repos where you regularly work across other projects.
- **When refresh fails:** this happens when the refresh token expires (6 months unused) or is revoked.
  - Environments keep running. There is no fallback to a bot token.
  - Git push and `gh` fail until the user logs back in to Foreman.
  - The UI shows a banner, and the agent writes a notice that new shells print.
  - After the user logs in again, Foreman re-scopes and sends fresh tokens to every running environment that user owns.

### Container registry (work only)

The personal deployment pulls only public images and features, including the Foreman feature. Work needs credentials for monolith's private `ghcr.io/acme/devcontainer-features/base`.

GHCR only accepts classic PATs; GitHub App tokens and fine-grained PATs can log in but can't pull. Work uses a machine user's classic PAT, and Foreman automates everything around it that it can:

- **First-class setting:** registry credentials (host, username, token) are an owner setting, separate from environment secrets.
- **Validation on save:**
  - Foreman checks that the token's `X-OAuth-Scopes` header includes `read:packages`.
  - It then test-fetches the manifest of every private feature and image referenced by the owner's repos.
- **Expiry tracking:** Foreman reads the token's `GitHub-Authentication-Token-Expiration` header and warns admins 14 days before it lapses.
- **Detection:** if a repo's devcontainer.json references a private `ghcr.io/<owner>/…` feature or image and no credential is set, the repo page links the runbook. The build doesn't run and fail.
- **Agent use:**
  - The agent supplies the credential to both Docker (image pulls) and the devcontainer CLI's own registry client (feature pulls).
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
| Dotfiles repo and install command | `--dotfiles-repository` / `--dotfiles-install-command` | On the next rebuild |

The Foreman feature installs an `/etc/gitconfig` that includes `/run/foreman/gitconfig`. The agent writes that file with `user.name`, `user.email` and the credential helper setting.

Because this is git config rather than an environment variable, every process sees it, including editors. Changes apply without a restart.

This replaces the per-repo `git config` and dotfiles steps in `postCreateCommand`.

If commits need signing, store an SSH signing key as a user secret.

## Capacity and resource limits

Foreman never assumes a box has room for everything provisioned on it. By default it reports contention and lets you decide.

### Limits

- **Default:** no limits. Every container takes what it can get, which is how the desktop works today.
- **Optional limits:** CPU and memory limits can be set per repo as a default, and per environment as an override. When set, the overlay applies `cpus` and `mem_limit` to the devcontainer service. Per-service limits for sidecars can come later if needed.
- **`hostRequirements`:** never treated as a limit. Monolith asks for 8 CPUs and 8 GB, so Foreman warns when placing it on a box that has less. It's also the estimate used for contention when an environment has no limits.

### Reporting

Each box reports total cores, memory and disk, plus live usage per environment (aggregated from `docker stats`). The UI shows:

- current usage per environment and per box
- **provisioned:** for each running environment, the first available of:
  1. its limits, if set
  2. its repo's `hostRequirements`, if declared
  3. its observed usage (a rolling average of `docker stats` over about 15 minutes)
- a contention badge when provisioned or observed usage passes a threshold of capacity

### Box policy

Set per box:

| Policy | Placing an environment beyond capacity |
|---|---|
| `allow` (default) | Shows the contention badge |
| `warn` | Asks for confirmation first |
| `refuse` | Blocks placement |

## Isolation and security model

### What the agent can do

The agent has Docker access, which means root on the box. That makes a compromised control plane a compromise of every box, so the defences sit around the control plane:
- tailnet only
- GitHub login and org membership checks
- a fixed command vocabulary on the agent
- signed agent releases, with the signing key kept off the control plane

The fixed vocabulary limits what an attacker can do, but it doesn't make `env.create` safe. Creating an environment from a repo runs that repo's Dockerfiles and lifecycle hooks.

### Privileged docker-in-docker

Every target repo uses the `docker-in-docker` feature, which runs the devcontainer privileged. Privileged means root on the box from inside the environment.

**v1 is policy-based:**
- A box belongs to one user, and only runs that user's environments unless the owner grants access to someone else.
- The blast radius is the owner's own box, the same as today.
- Repos should drop `docker-in-docker` where nothing in them uses Docker.

**Deferred until boxes are actually shared:** run one Incus system container per developer per box, with `security.nesting=true` and its own dockerd, and a Foreman agent inside it.
- The control plane sees each of these as a separate box, so no app code changes.
- The isolation boundary then matches the trust boundary, which is the developer.
- This needs a spike.

**Ruled out:**

| Option | Why |
|---|---|
| Sysbox | Incompatible with `--privileged` and therefore with the official `docker-in-docker` feature; open nested-buildx breakage on Docker 28.5+ ([nestybox/sysbox#973](https://github.com/nestybox/sysbox/issues/973)) |
| Podman | devcontainer CLI + compose + features is still broken ([devcontainers/cli#863](https://github.com/devcontainers/cli/issues/863)) |
| Kata / Firecracker | No network namespace sharing, so `network_mode: service:x` fails; Docker 28 broke Kata networking |
| Rootless Docker | Nested privileged dind is unverified, and Ubuntu 24.04's user namespace restrictions get in the way |

### Secrets exposure on a box

Anyone with Docker access on a box can read every secret of every environment on it. At work, that is a reason to keep boxes single-owner and to treat any access grant to another developer as a trust decision.

## Agent self-update

1. CI builds the agent release for each target architecture on a tag. It signs the tarball with an ed25519 (minisign) key that lives only in CI, then uploads the tarball and signature to the control plane.
2. An admin sets the desired agent version, globally or per box. An agent running a different version receives `agent.update`.
3. The agent downloads the release from the control plane and verifies the signature against the public key compiled into it.
4. It unpacks to `/opt/foreman-agent/releases/<version>`, switches the `current` symlink and exits. systemd restarts it on the new version.
5. If the new version hasn't connected within 60 seconds, a systemd `OnFailure` unit switches the symlink back.

Containers keep running throughout, because the Docker daemon owns them. Erlang hot code upgrades are not used.

## Repo conventions

What a repo needs to work well under Foreman:

- **Required:**
  - A compose-based devcontainer.
  - No bind mounts to host paths outside the repo. They break on other boxes and collide between copies.
- **Remove:**
  - Repo-level Tailscale setup: install scripts, `tailscale-up.sh`, `TS_*` settings, the authkey mount, and `cap_add`/`devices` added only for Tailscale. The Foreman feature replaces all of it.
  - `env_file` entries pointing at gitignored files. Those values become Foreman secrets.
  - Dotfiles, git identity and SSH `authorized_keys` setup in `postCreateCommand`. Foreman covers them.
  - The `sshd` feature and any published SSH port. Tailscale SSH replaces them.
- **Only if spike 1 falls back to opt-in:** list a gitignored `foreman.compose.yml` in `dockerComposeFile`.
- **Optional:** `ports:` can stay. The overlay strips them anyway.

### Migration notes

- **storefront, storefront-assets, webapp:**
  - Remove the tool socket mounts.
  - Remove the IDE runtime mount, `ide-serve.sh` and `IDE_SERVE_PORT`; the IDE connects over SSH on the tailnet.
  - Remove the Tailscale scripts and settings.
  - Remove the hand-kept port registry comments.
  - Move `.storefront.env` and `.env` values into Foreman secrets.
- **toolbox:** same, minus Tailscale.
- **monolith:**
  - Fix `workspaceFolder: /workspaces/${localWorkspaceFolderBasename}` together with the `..:/workspaces` mount. Outside Codespaces the repo root is mounted at `/workspaces`, so that folder very likely doesn't exist.
  - Move the Codespaces secrets into Foreman: the repo secrets (`HEX_API_KEY`, `OBAN_LICENSE_KEY`, `NEON_*`, and others) and the user secrets (`DEV_USER_EMAIL`, `DEV_USER_OID`, `LEGACY_DATABASE_URL`).
  - Decide GHCR access for the private base feature.
  - `customizations.codespaces` can be dropped.
  - The `secrets` declarations in `devcontainer.json` are worth keeping. Foreman can read them to prompt for missing values when an environment is created.

## Data model (sketch)

- `users`: GitHub id and login, encrypted user and refresh tokens, role, and default git identity and dotfiles.
- `user_repo_settings`: user, repo, and optional git name, git email, dotfiles repo and dotfiles install command. Unset fields fall back to the user's defaults.
- `owners`: GitHub org or user account, plus installation id.
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
docs/
```

### Testing

- `foreman_protocol` gets contract tests, so the control plane and agent agree on every message.
- The agent's Docker and devcontainer CLI calls sit behind behaviours, with fakes for unit tests.
- Integration tests against real Docker are tagged `:docker` and run on a Linux box or in CI.
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
| Contention for environments without limits | `hostRequirements` if declared, otherwise observed rolling average |
| Box overcommit | `allow` by default; `warn` and `refuse` are per-box options |
| Git identity and dotfiles | User defaults with per-repo overrides |
| Incus isolation | Deferred until boxes are actually shared |
| GHCR (work only) | Machine-user classic PAT as a first-class registry credential, validated on save, expiry tracked, with a runbook |

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

1. **Spike, no UI or agent:** a Mix task that clones storefront, writes the overlay and override config, adds the Foreman feature and runs `devcontainer up`. Done when two copies of storefront run side by side on the tailnet. This answers spikes 1–4.
2. Run the same spike on monolith to surface its Codespaces-specific behaviour and answer spike 6.
3. Control plane and local agent over a Channel, with a LiveView environment list, start/stop and log streaming.
4. Secrets: scopes, Cloak, file delivery, restart now or later.
5. GitHub App: login, repo browsing, scoped tokens, credential helper.
6. Capacity reporting, limits and box policy.
7. Remote agents: enrollment, signed self-update.
8. Work rollout:
   - registry credentials and the GHCR runbook
   - per-developer Tailscale tags
   - migrating monolith off Codespaces
9. Incus isolation, only once shared boxes happen.

## Prior art

| Project | State (Oct 2026) | Why not just use it |
|---|---|---|
| Coder (Community) | Active. Its agent dials out, and it runs devcontainers through `@devcontainers/cli` | Running on boxes you already own needs Premium (or an SSH-Docker template workaround). No owner or repo secrets; user secrets are a 2.34 beta, and encryption at rest is Premium. Templates are Terraform. |
| DevPod | Upstream stalled since 2025. The community fork points to Devsy | No control plane or secrets model |
| Gitpod / Ona | Self-hosted is dead. Being acquired by OpenAI | Gone |
| Daytona | Pivoted to AI sandboxes; source closed | Gone |
