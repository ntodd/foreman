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
  need it, so remove a repo's own Tailscale setup), `device_cgroup_rules`,
  and device reservations that aren't NVIDIA GPUs
- NVIDIA GPU reservations, under a rule of their own so a box can allow
  them without allowing host devices; see [GPUs](#gpus)
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
- builds with `privileged`, `network: host` or `entitlements`
- compose keys Foreman hasn't reviewed, such as `runtime`,
  `cgroup_parent`, `external_links`, `models` or
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

## GPUs

A box with NVIDIA GPUs can let environments use them with
`FOREMAN_POLICY=gpu=allow` (or `gpu=warn`). That doesn't let them map
other host devices; those stay under the `devices` rule. Reserve the GPU
in the compose file, with the driver and the driver capabilities the
service uses:

```yaml
deploy:
  resources:
    reservations:
      devices:
        - driver: nvidia
          count: all              # or a number, or device_ids: ["0"]
          capabilities: [gpu, compute, video, utility]
```

`compute` is CUDA, `video` is NVENC and NVDEC, `utility` is
`nvidia-smi` and NVML, and `compat32` is the 32-bit libraries. Listing
`video` and `utility` without `compute` replaces NVIDIA's default set,
so CUDA (Whisper, say) needs `compute` listed too. The `gpus:` key works
the same way, as a list with `driver: nvidia` and `capabilities`.

These stay under the `devices` rule, so `gpu=allow` doesn't cover them:

- `graphics` and `display`, which bring in OpenGL and Vulkan and the
  display's modeset device
- a reservation that names no driver capabilities, `gpus: all` among
  them. Docker then leaves the capabilities to the image, which can ask
  for all of them.
- another driver (`cdi` can name any device), `options`, and device IDs
  that aren't a GPU index or a `GPU-`/`MIG-` UUID
- `runtime: nvidia`, which hands GPUs to whatever the image's
  environment asks for

`hostRequirements.gpu` in `devcontainer.json` is ignored: the agent runs
the devcontainer CLI with `--gpu-availability none`, so only the
reservations in the compose file reach a container. Agents before this
let the CLI add a GPU for `hostRequirements.gpu`, and a container made
that way keeps it across starts and restarts, so rebuild environments
on a GPU box after upgrading its agent.

Environments on a box share its GPUs. Foreman doesn't limit their GPU
memory or keep one environment's work off another's GPU, so one that
fills the memory starves the rest. Give a GPU box to environments that
can share it.

The box needs the NVIDIA driver and the
[NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html).
Configure Docker with `nvidia-ctk runtime configure --runtime=docker`,
without `--set-as-default`: with nvidia as Docker's default runtime, any
image that sets `NVIDIA_VISIBLE_DEVICES` (CUDA images do) gets the GPUs
without a reservation, so the agent refuses to start environments on
that box unless it allows `devices`. If nvidia is already the default,
running `nvidia-ctk` again doesn't change that: remove `default-runtime`
from `/etc/docker/daemon.json` (or set it to `runc`) and restart Docker.
The agent goes by the runtime's binary, not its name, and refuses a
default runtime whose binary Docker doesn't report. If the toolkit is
missing, starting an environment that reserves a GPU fails with an error
that says so.

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

## What trips a port up

Each of these broke a real repo moving onto Foreman. None of them is an
error you'd see from the box's checks.

- **The remote user doesn't run as the uid you set.** The devcontainer CLI
  changes the remote user's uid and gid to the host user's that runs it,
  which is the agent's own user (`foreman`, a system account `install.sh`
  creates, so its uid is below 1000 and varies by box; `id foreman` shows
  it). A Dockerfile's `useradd -u 1000` or common-utils'
  `userUid` doesn't survive that. HOME is fine (the CLI re-owns it), but
  anything else the image chowns to the user, `/usr/local/bundle` or a
  browser cache like `/ms-playwright`, isn't writable at runtime. Make
  those directories writable by any uid (`chmod -R a+rwX`) instead of
  chowning them.
- **A named volume for HOME keeps stale state.** Mounting a volume at the
  user's home keeps sign-ins (`~/.claude`, `~/.codex`, gh) through a
  rebuild, which is worth having. It also keeps lock files, sockets and
  pid files that the old container's processes left, and a new container
  can take those for a runtime that's still running. Clear them at start
  when nothing is running, as the Orca feature's `orca-serve` does.
- **A committed `devcontainer-lock.json` pins features.** The agent uses it
  when the repo has one, so a feature's new version never installs until
  the lockfile moves: run `devcontainer upgrade --workspace-folder .` and
  commit it. Without a lockfile the agent passes `--no-lockfile`.
- **Only the devcontainer service is on the tailnet.** Bind dev servers to
  `0.0.0.0`. A sidecar a laptop needs to reach (a database console, a CDN
  stand-in, Selenium's VNC) needs a relay from the devcontainer, such as
  `setsid nohup socat TCP-LISTEN:<port>,fork,reuseaddr TCP:<service>:<port>
  >/dev/null 2>&1 </dev/null &` in `postStartCommand`. URLs a laptop opens
  should default to the environment's name, which is also
  `COMPOSE_PROJECT_NAME`: `${APP_DEV_HOST:-${COMPOSE_PROJECT_NAME:-localhost}}`
  in compose, plus whatever the framework needs to accept that host (Rails'
  `config.hosts`, say).
- **Reaching the tailnet from inside goes through a proxy.** The feature's
  Tailscale runs in userspace, so the container's own outbound traffic
  doesn't go over the tailnet. Tailnet hosts are reachable through its
  SOCKS proxy: `curl --proxy socks5h://127.0.0.2:1055 http://<host>:<port>/`.
- **Lifecycle commands in object form run in parallel, and their output is
  held until each finishes.** Two entries that write the same file (two
  `bundle config` calls, an `npm install` next to a `mix assets.setup` that
  runs `npm ci`) race. A slow entry shows nothing in the environment's log
  until it ends, so it looks like a hang. Put anything that downloads under
  a `timeout`, let it print, and don't install `@latest` of tools whose
  dependencies you've baked into the image at a fixed version.
- **The login shell is whatever `/etc/passwd` says.** Tailscale SSH and
  `docker exec` use it, not VS Code's terminal setting. With common-utils,
  `installZsh` isn't enough: set `configureZshAsDefaultShell` too.
- **Prepend to PATH, don't replace it.** `"remoteEnv": { "PATH":
  "/home/<user>/.local/bin:${containerEnv:PATH}" }`. Replacing it drops
  directories features added (nvm's, say).
- **The dotfiles install command takes no arguments.** The CLI runs it as a
  file, so `script/setup --force` fails with exit 126. Point it at a script
  in the dotfiles repo that runs the real one with its flags.

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
