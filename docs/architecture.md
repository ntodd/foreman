# Foreman architecture

Status: implemented (v1), 2026-10-13. See "Implementation notes" at the end for where the build differs from the plan below.

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
- It runs child processes under MuonTrap. Cancelling an operation, or a command running past its timeout, kills the command's whole process tree (found through `/proc`), and the environment's next operation waits until it's gone. Every command has a timeout: three hours for `devcontainer up`, 30 minutes for the rest.
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
| `env.git_status` | Dirty tree / unpushed commits check before destroy; the clone's HEAD and merge base, which the environment page compares with the branch on GitHub |
| `box.inventory` | Report environments found via Docker labels |
| `box.stats` | Report CPU, memory and disk, per environment and in total |
| `box.gc` | Prune unused images, build cache and orphaned volumes |
| `agent.update` | Install a new agent release |

Every command carries an `op_id`. The agent records in-flight `op_id`s, so a command retried after a reconnect is not run twice. Long operations keep running if the socket drops. The agent sends their progress and result once it reconnects.

The agent sends its version and protocol version when it joins. The control plane accepts protocol N and N-1, and only sends a protocol-N field to agents that reported N, so upgrade the control plane before the agents (an older control plane refuses newer agents). Protocol 2 added `keep` to `env.secrets.write`. Protocol 3 added `features` (a user's own devcontainer features) to `env.create` and `env.rebuild`; an environment on an older agent builds without them. Once boxes run protocol-2 agents, the control plane can't be rolled back past the release that introduced it: an older control plane refuses them at join.

### Reconciliation

When an agent joins, it reports what's on the box. The control plane compares that with the desired state of each environment (`running`, `stopped` or `destroyed`) and sends the commands needed to match.

The overlay sets `restart: "no"` on every service, so the agent controls start order after a host reboot. That matters because secrets live on tmpfs, which a reboot clears:

1. The box boots and the agent starts and connects.
2. The control plane resolves secrets and sends `env.secrets.write`.
3. The control plane sends `env.start` for every environment whose desired state is `running`.

As a result, environments don't come back after a reboot until the control plane is reachable. The personal control plane runs on the same box, so this only affects team deployments.

## Environment lifecycle

### Naming

- **Slug:** `<repo>-<n>` on the personal deployment, `<repo>-<login>-<n>` on a team deployment. For example `storefront-2` or `storefront-alice-1`.
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
     --additional-features '{"./.foreman/feature": {"tailscale": true}, <user's own features>}' \
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

A devcontainer feature that ships inside the agent release, so a box always runs the feature version its agent was built with. The agent copies it into the clone at `<config dir>/.foreman/feature` (excluded through `.git/info/exclude`) and adds it with `--additional-features`, so repos don't declare it. (Spike 1 showed the CLI resolves local features against the repo's devcontainer folder, not the override config's.)

- **Tailscale:**
  - Installs `tailscale` and `tailscaled` from the static tarball, with a checksum check.
  - Its `entrypoint` starts tailscaled and runs `tailscale up --ssh --auth-key=file:/run/foreman/ts-authkey --hostname=$TS_HOSTNAME …`.
  - tailscaled always uses userspace networking, so the devcontainer gets no TUN device and no `NET_ADMIN`, and tailscaled never touches its routes, firewall or DNS. Connections into the environment (Tailscale SSH, its ports, `tailscale serve`) work as usual; connections out to other tailnet machines go through a SOCKS5 and HTTP proxy on `127.0.0.2:1055` (not 127.0.0.1, which tailscaled forwards tailnet connections to). In this mode tailscaled hands connections from the tailnet to `127.0.0.1:<port>`, so servers bound only to localhost are reachable from the tailnet too, and see every tailnet peer as 127.0.0.1.
  - Because it is an entrypoint, it runs on every container start, including `docker restart`. A `postStartCommand` only runs when the devcontainer CLI starts the container.
- **Secrets hook:** installs `/etc/profile.d/foreman.sh`, which sources `/run/foreman/secrets.env`. A zsh equivalent goes in `/etc/zsh/zprofile`. The hook also prints `/run/foreman/notices` when it isn't empty.
- **Container environment over SSH:** Tailscale SSH (and VS Code over SSH) starts a clean login shell, without the container's environment: compose `environment:`, `containerEnv`, or a `PATH` the image set. The entrypoint saves that environment to `/etc/foreman/container.env` on every start, and the hook loads it before the secrets, so an SSH shell sees what `docker exec` would.
- **Git:**
  - Installs an `/etc/gitconfig` that includes `/run/foreman/gitconfig`.
  - Installs a git credential helper that reads `/run/foreman/github-token`.
  - Points `gh` at the same token file.
- **Ownership:** Tailscale bootstrap now belongs to the feature. Repo-level copies (`install-tailscale.sh`, `tailscale-up.sh`, the shared `devcontainer-authkey` mount) go away.

### Stop, rebuild, destroy

- **Stop:** `docker compose stop`. Sidecars get a graceful shutdown; for example, a Neon Local sidecar deletes its branch on stop.
- **Rebuild:** `devcontainer up --remove-existing-container`. Named volumes, the clone and the Tailscale identity survive.
- **Destroy:**
  1. The agent runs `env.git_status`. The UI warns about a dirty tree or unpushed commits.
  2. The agent runs `docker compose down -v` and deletes the clone and the secrets directory.
  3. The control plane deletes the Tailscale device through the API.

## Networking

### Tailscale per environment

- **Auth keys:** the control plane holds a Tailscale OAuth client with the `auth_keys` scope. It mints one key per environment (`?ephemeral=false&preauthorized=true`) tagged `tag:foreman-env`, plus any tags configured on the repo (for example `tag:staging-access`).
  - Tagged devices have key expiry disabled.
  - The auth key is only needed the first time. State persists in the `tailscale-state` volume, so rebuilds keep the same node.
- **Hostname:** the slug, so you reach environments at `storefront-2`, `storefront-2:4000`, and so on.
- **HTTPS:** a plain-HTTP tailnet hostname is not a secure context, which breaks secure cookies, WebAuthn, clipboard access and service workers. Repos that need those run `tailscale serve` to get `https://<slug>.<tailnet>.ts.net`.
  - Hostnames land in public certificate transparency logs, so keep them bland.
  - Let's Encrypt rate limits are another reason to keep state persistent.
- **SSH:** Tailscale SSH.
  - The feature runs `tailscale up --ssh`, so `ssh vscode@storefront-2` works on port 22 with no keys and no sshd.
  - Tailnet ACLs decide who can log in as which local user.
  - SSH rules use `action: accept`, not `check`, so editors and other SSH tools aren't sent to re-authenticate.
- **DNS:** untouched. In userspace mode tailscaled doesn't change `resolv.conf`, so Docker's resolver keeps answering compose service names. MagicDNS names resolve for connections made through the proxy.
- **Cleanup:** an Oban job removes tailnet devices that no longer match a live environment. It only ever touches devices tagged `tag:foreman-env` (always applied to environments; `FOREMAN_TAILSCALE_TAGS` adds to it), and a destroyed environment's cleanup skips its slug if a new environment has taken it.

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
| Compose interpolation (`${VAR}` in compose files) | sidecars such as Neon Local | After the affected services are recreated |
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
  - **Repos:** the environment's repo plus any extra repos configured on it.
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

### Your own devcontainer features

Each user can keep a list of devcontainer features that go on every environment they create, in any repo, without putting them in a shared `devcontainer.json`. Settings takes them in the shape of devcontainer.json's `features` object: an OCI ref and its options.

- **Private:** only that user's environments get them, and only they see them in their settings. Admins see everyone's on the People page, since a feature runs code in the environment.
- **Per repo:** each repo's page has a box per feature; unticking one leaves it out of the user's environments of that repo. The opt-out is by ref without a version, so moving from `:1` to `:2` keeps it off.
- **Delivery:** the command carries them as `features`. The agent adds them to the `--additional-features` it passes for the Foreman feature, so `read-configuration` resolves them and the policy checks them like the repo's. A refusal names them as "your feature … (from your Foreman settings)".
- **Conflicts:** a feature the repo's devcontainer.json already declares, at any version, is skipped (the operation log says so) and the repo's copy installs. Nothing can use the Foreman feature's id.
- **Refs:** OCI refs only. A local path would resolve against the repo's devcontainer folder, and a tarball URL skips the registry. Tags are accepted and aren't locked: a user feature has no lock file, so each rebuild gets what the tag points to then.
- **Registries:** a build's registry credentials are the repo owner's. A private user feature only pulls if those credentials can read it.
- **When it applies:** on the next rebuild, like dotfiles.
- **Audit:** `user.features` records the refs added, removed and changed, never their options.

## Capacity and resource limits

Foreman never assumes a box has room for everything provisioned on it. By default it reports contention and lets you decide.

### Limits

- **Default:** no limits. Every container takes what it can get, which is how the desktop works today.
- **Optional limits:** CPU and memory limits can be set per repo as a default, and per environment as an override. When set, the overlay applies `cpus` and `mem_limit` to the devcontainer service. Per-service limits for sidecars can come later if needed.
- **`hostRequirements`:** never treated as a limit. A repo that asks for 8 CPUs and 8 GB gets a warning when it's placed on a box that has less. It's also the estimate used for contention when an environment has no limits.

### Reporting

Each box reports total cores, memory and disk, plus live usage per environment (aggregated from `docker stats`) every 30 seconds (`box.stats`). Every 5 seconds it also sends host-wide CPU, memory, swap, load and disk (`box.metrics`), read from `/proc` and `df` without going through Docker.

The control plane stores both (`box_metrics`, `env_metrics`, with Unix-second timestamps so bucketing is integer math on SQLite and Postgres) and keeps 7 days; an hourly Oban job (`PruneMetrics`) deletes older rows. Environment samples keep the slug and no foreign key, so a destroyed environment stays on its box's charts until it ages out. Reads are bucketed to about 240 points whatever the range (15 minutes to 7 days). The box page charts CPU and memory as the box total over each environment's share, plus disk and load against the core count, and updates live; the box list shows half-hour CPU and memory trends. Agents older than the metrics event keep working and their charts stay empty.

The UI shows:

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

### No docker-in-docker

Environments run unprivileged. The agent refuses privileged containers by default, and that includes the `docker-in-docker` feature, which runs the devcontainer privileged. A privileged container is root on the box: it can mount the host's disks, load kernel modules, and read every environment's secrets and the agent's key.

**Instead of Docker inside an environment:**
- **Services** (databases, caches, search, browsers for tests) go in the compose file as sidecars, which is what most docker-in-docker setups were really for.
- **Image builds** go to a remote builder or CI. `fly deploy`, for example, builds remotely unless told otherwise.
- **Pulling, retagging and pushing images** works without a daemon, using `crane` or `skopeo`.

**When a repo really needs Docker inside:** its box opts in with `FOREMAN_POLICY=privileged=allow`, and the control plane shows that box with a red alert. The blast radius is that box, so it should be a box with nothing else on it: its own VM, or later a per-developer Incus container.

**Deferred until boxes are actually shared:** run one Incus system container per developer per box, with `security.nesting=true` and its own dockerd, and a Foreman agent inside it.
- The control plane sees each of these as a separate box, so no app code changes.
- The isolation boundary then matches the trust boundary, which is the developer.
- A privileged environment inside it is root only in that developer's container.
- This needs a spike.

**Ruled out as ways to make privileged Docker safe:**

| Option | Why |
|---|---|
| Sysbox | Incompatible with `--privileged` and therefore with the official `docker-in-docker` feature; open nested-buildx breakage on Docker 28.5+ ([nestybox/sysbox#973](https://github.com/nestybox/sysbox/issues/973)) |
| Podman | devcontainer CLI + compose + features is still broken ([devcontainers/cli#863](https://github.com/devcontainers/cli/issues/863)) |
| Kata / Firecracker | No network namespace sharing, so `network_mode: service:x` fails; Docker 28 broke Kata networking |
| Rootless Docker | Nested privileged dind is unverified, and Ubuntu 24.04's user namespace restrictions get in the way |

### Secrets exposure on a box

Anyone with Docker access on a box can read every secret of every environment on it. On a team, that is a reason to keep boxes single-owner and to treat any access grant to another developer as a trust decision.

## Agent self-update

1. CI builds the agent release for each target architecture on a tag. It signs it with an ed25519 key that lives only in CI (`mix foreman_agent.sign`; the signature covers the version, target and SHA-256), builds the control plane images with the signed tarballs inside, and attaches the tarballs and signatures to a GitHub release. A control plane registers the agents its image carries at boot, checking each signature, and keeps the ones it already had. `scripts/publish-agent-release.sh` registers a GitHub release's agents by hand; the control plane never talks to GitHub for releases.
2. A box follows the newest agent its control plane's image carries (for an image that carries none, the newest registered), unless an admin pins it to a version registered for its architecture. New boxes install the same version. A box whose agent runs another version receives `agent.update`.
3. The agent downloads the release from the control plane and verifies the signature against the public key compiled into it.
4. It unpacks to `/opt/foreman-agent/releases/<version>`, switches the `current` symlink (keeping the old target as `previous`) and writes an `update-pending` marker. It exits once nothing else is running and every result has been acknowledged (waiting up to an hour), and systemd restarts it on the new version. An update to the version already installed does nothing, and only one update runs at a time.
5. When the new version joins the control plane it clears the marker and `previous`. If it crash-loops, a systemd `OnFailure` unit switches the symlink back; if it runs but hasn't joined within five minutes, the agent rolls itself back and exits.
6. The control plane sends no new update while one is in flight or while the box's environments have operations running. An update counts as done only when the box rejoins on the new version, and as failed ten minutes after it was sent with no answer, or 70 minutes after the agent said it would restart (it can wait an hour for idle). After two failures in a row of the same version on a box, that version isn't sent to it again until an admin retries it from the box's page or picks another version.

Containers keep running throughout, because the Docker daemon owns them. Erlang hot code upgrades are not used.

## Repo conventions

What a repo needs to work well under Foreman:

- **Required:**
  - A compose-based devcontainer.
  - No bind mounts to host paths outside the repo. They break on other boxes and collide between copies.
  - No privileged containers, including the `docker-in-docker` feature, unless the box opts in. See [No docker-in-docker](#no-docker-in-docker).
- **Remove:**
  - The `docker-in-docker` feature. Services move to compose sidecars; image builds move to a remote builder or CI.
  - Repo-level Tailscale setup: install scripts, `tailscale-up.sh`, `TS_*` settings, the authkey mount, and `cap_add`/`devices` added only for Tailscale. The Foreman feature replaces all of it.
  - `env_file` entries pointing at gitignored files. Those values become Foreman secrets.
  - Dotfiles, git identity and SSH `authorized_keys` setup in `postCreateCommand`. Foreman covers them.
  - The `sshd` feature and any published SSH port. Tailscale SSH replaces them.
- **Only if spike 1 falls back to opt-in:** list a gitignored `foreman.compose.yml` in `dockerComposeFile`.
- **Optional:** `ports:` can stay. The overlay strips them anyway.

## Data model (sketch)

- `users`: GitHub id and login, encrypted user and refresh tokens, role, default git identity and dotfiles, and their own devcontainer features (ref => options).
- `user_repo_settings`: user, repo, and optional git name, git email, dotfiles repo and dotfiles install command. Unset fields fall back to the user's defaults. Also the user's features turned off for the repo, by ref without a version.
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
| GHCR (private images) | Machine-user classic PAT as a first-class registry credential, validated on save, expiry tracked, with a runbook |

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
9. Incus isolation, only once shared boxes happen.

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
  the agent user. On Linux the devcontainer CLI maps the container's
  user to the agent's uid, so the environment can read them.
- **Redaction:** secret values are scrubbed from operation logs and
  errors by both the agent and the control plane (the CLI logs the
  merged compose config with interpolated values).
- **Compose policy:** the agent checks the merged compose config,
  `devcontainer.json` and the features the CLI resolves (with
  `devcontainer read-configuration --include-merged-configuration`)
  on every start, and refuses privileged containers, host namespaces,
  host binds, host files, the Docker socket and devices unless the box
  opts out. Agents report their policy on join; see
  [security.md](security.md).
- **`initializeCommand`** is dropped: it would run on the box.
- **Restart affected:** recreates the non-devcontainer services that
  interpolate a changed variable, then stops and re-`up`s the
  devcontainer service (entrypoint and `postStartCommand` run again). If
  the devcontainer service itself interpolates a changed variable, the
  CLI recreates it.
- **Destroy:** a git status check runs inside the container first; with
  uncommitted or unpushed work, the UI asks for the environment's name.
- **Not built yet:** idle auto-stop, per-service limits for sidecars,
  Incus isolation, webhooks (repos are polled).
