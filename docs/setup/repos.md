# Making a repo work with Foreman

Foreman runs any repo with a **compose-based** devcontainer
(`dockerComposeFile` and `service` in `devcontainer.json`, at
`.devcontainer/devcontainer.json`, `.devcontainer.json` or
`.devcontainer/<name>/devcontainer.json`). Codespaces compatibility isn't
a goal, so repos can change to fit.

## What Foreman adds

You don't add any of this to the repo; the agent layers it on:

- a compose overlay that strips every published port, turns off restart
  policies (the agent starts environments after a reboot, once secrets
  are back), labels the services, and mounts `/run/foreman` read-only
  into the devcontainer service
- the Foreman feature (Tailscale and Tailscale SSH, the secrets hook,
  git identity, the GitHub credential helper and `gh` wrapper)
- `COMPOSE_PROJECT_NAME` set to the environment's name, so every named
  volume is per copy

`initializeCommand` is ignored: the devcontainer CLI runs it on the box
itself, not in a container.

## What a box refuses

Environments run unprivileged. Every time the agent starts one, it
checks the merged compose config, `devcontainer.json`, and what the
devcontainer CLI resolves from features, before anything runs. It does
this on every start because anything running inside an environment can
edit the files in its workspace. By default a box refuses:

- privileged containers: `privileged: true` in a compose file or
  `devcontainer.json`, the docker-in-docker feature, any feature whose
  own metadata asks for privileged, and capabilities that amount to
  root on the box (`SYS_ADMIN`, `SYS_MODULE`, `SYS_RAWIO`,
  `DAC_READ_SEARCH`, `BPF`, `PERFMON`, `MAC_ADMIN`, `ALL`)
- the host's network, PID or IPC namespace
- the Docker socket
- bind mounts of host paths outside the environment's workspace
  (`../..` from `.devcontainer`, the usual `/workspaces` mount, is fine)
- `env_file`, `secrets`, `configs` or build contexts outside the
  workspace
- host devices, including `/dev/net/tun` (Foreman's Tailscale doesn't
  need it, so remove a repo's own Tailscale setup)
- turning seccomp off (`seccomp=unconfined`). The official Go and Rust
  features ask for it, for debuggers; remove it from the repo's config,
  or let a box allow it with `FOREMAN_POLICY=seccomp=allow`. That only
  loosens seccomp, not privileged containers.
- other `security_opt` settings, joining another container's namespaces
  or volumes, and named volumes that are really host paths
- env files, label files, and included or extended compose files outside
  the workspace, or with paths built from variables (`${...}`), and
  remote includes. Use plain paths inside the repo.
- networks from outside the project (an `external` network, or one with
  a fixed `name:`), and `devcontainer.json` mounts of `external` volumes
  that aren't the environment's own
- builds with `privileged`, `network: host` or `entitlements`, and GPU
  reservations (`gpus`, `deploy.resources.reservations.devices`)
- compose keys Foreman hasn't reviewed, such as `runtime`,
  `cgroup_parent`, `external_links`, `gpus`, `models` or
  `use_api_socket`. A box can allow unreviewed keys with
  `FOREMAN_POLICY=compose_keys=allow`. `x-` extension keys are always
  fine.
- `provider` services, whatever the box allows: compose runs a
  provider's `type` as a program on the box.

The check reads compose files with Node (which the devcontainer CLI needs
anyway), so a box needs Node on its `PATH`.

Ordinary capabilities such as `NET_ADMIN` or `SYS_PTRACE` (debuggers)
are fine. Binds that expose the agent's own state, other environments
or secrets are refused whatever the box allows.

A box can open a rule up with `FOREMAN_POLICY` in its agent's
environment (for example `privileged=allow`, or `host_bind=warn` to
allow with a warning on the environment's page). That's the exception:
the box then shows a red alert in the control plane until it's
removed.

## Docker inside an environment

The docker-in-docker feature runs the devcontainer privileged, which is
root on the box, so it's refused. Usually it isn't needed:

| What dind was for | Do this instead |
|---|---|
| Databases, caches, search, Selenium and other services | Add them to the compose file as sidecars. They run unprivileged, get their own volumes per copy, and pick up secrets through `${NAME}`. |
| Building and deploying images | Use a remote builder or CI. `fly deploy` builds remotely by default; with plain Docker, point `docker buildx` at a remote builder or build in a workflow. |
| Pulling, retagging or pushing images | `crane` or `skopeo`, which need no daemon. |
| Testcontainers or tests that start containers | Point the tests at sidecars in development, and run the container-starting suite in CI. |

If a repo really needs a Docker daemon in its environments, run them on
a box that allows it (`FOREMAN_POLICY=privileged=allow`) and treat that
box as belonging to whatever runs in it. Its own VM is a good fit.

## Postgres 18 and its data volume

The `postgres:18` images keep data in a version-named directory under
`/var/lib/postgresql`, and refuse to start if something is mounted at the
old `/var/lib/postgresql/data`. A compose file written for 17 or earlier
then leaves the environment partly running, with the database exiting on
every start. Mount the volume one level up:

```yaml
services:
  db:
    image: postgres:18-alpine
    volumes:
      - postgres-data:/var/lib/postgresql   # not /var/lib/postgresql/data
```

Or pin the image to `postgres:17` until you're ready to move.

## Builds and caching

Every environment on a box builds through the box's Docker daemon, so a
second copy of a repo reuses the first one's image layers, and a
different branch rebuilds from the first layer whose files changed. The
cache is per box and grows until it's pruned: **Prune** on the box's
page drops build cache that hasn't been used for a week, along with
dangling images and unused anonymous volumes. Nothing runs it on a
schedule. Rebuild reuses the cache too: it recreates the
containers, it doesn't refetch a base image tag that has moved, so pin
base images rather than relying on `:latest`.

## What to remove

- **The docker-in-docker feature:** see
  [Docker inside an environment](#docker-inside-an-environment).
- **Repo-level Tailscale:** install scripts, `tailscale-up.sh`, `TS_*`
  settings, the auth key mount, and `cap_add` or `devices` added only for
  Tailscale. The feature does all of it.
- **`env_file` entries pointing at gitignored files:** move those values
  into Foreman secrets. Login shells load them from
  `/run/foreman/secrets.env`; compose files can still use `${NAME}`.
- **Dotfiles, git identity and SSH `authorized_keys` setup** in
  `postCreateCommand`: set dotfiles and identity in Foreman's Settings
  (overridable per repo).
- **The `sshd` feature and any published SSH port:** Tailscale SSH
  replaces them.
- **Bind mounts to host paths** outside the repo: they break on other
  boxes and collide between copies (and the box refuses them).
- **`ports:`** can stay; the overlay strips them.

## Secrets: which kind

| Where the value is read | How it reaches it | After a change |
|---|---|---|
| A login shell, a dev server you start | `/run/foreman/secrets.env` | New shells immediately; **Restart all** for running processes |
| A compose file (`${DATABASE_URL}`) | Compose interpolation at start | **Restart affected** recreates the services that use it |
| git and `gh` | `/run/foreman/github-token` | Nothing; read on every use |

## Coming from Codespaces

- **`workspaceFolder`:** `/workspaces/${localWorkspaceFolderBasename}`
  with a `..:/workspaces` mount only works in Codespaces. Elsewhere the
  repo root is mounted at `/workspaces`, so that folder doesn't exist.
  Use `"workspaceFolder": "/workspaces"`, or mount `../..:/workspaces`.
- **Codespaces secrets:** shared ones become repo secrets in Foreman;
  per-developer ones become each developer's own secrets.
- **Private images or features on GHCR:** add a registry credential, see
  [ghcr-machine-user.md](ghcr-machine-user.md).
- **`customizations.codespaces`** can go. The `secrets` declarations in
  `devcontainer.json` are worth keeping as documentation.
- **Sidecars configured through compose interpolation** pick up changed
  secrets with **Restart affected**. **Stop** stops them gracefully, so
  shutdown hooks (deleting a temporary database branch, say) still run.
