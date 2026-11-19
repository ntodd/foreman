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

`initializeCommand` runs where the devcontainer CLI runs it, outside the
containers, which is the environment's own VM.

## What an environment can do

Each environment runs in a VM of its own, with its own kernel and its
own Docker, and nothing checks what the repo's config asks for. A repo
can use whatever Docker allows: privileged containers, the docker-in-docker feature,
capabilities, host namespaces, devices, `seccomp=unconfined` (the
official Go and Rust features ask for it, for debuggers), the Docker
socket, and bind mounts of any path. The "host" in all of these is the
environment's VM, which holds that environment and nothing else, so none
of it reaches the box or other environments.

What still applies:

- Published ports are stripped. Reach the environment over the tailnet
  instead; nothing outside the box could reach a VM's ports anyway.
- Foreman chooses CPU and memory independently. Each uses the environment
  override, then the repo default, then the box default (normally 4 vCPUs
  and 8 GiB). To resize an existing VM, open **Resources → Edit** on its
  environment page. For example, enter `8` for CPUs and `8` for memory in
  GiB. Clearing either field restores inheritance for that resource.
  Save, then **Stop** and **Start** to boot with the new size. A suspended
  VM resumes with its saved size. The data disk defaults to 64 GB.
- A Compose devcontainer can also have its own CPU or memory limit inside
  the VM. Foreman writes its limits into the app service's Compose overlay
  on creation or rebuild. If the app still has an older, tighter limit
  after resizing the VM, **Rebuild** refreshes that overlay.
- The network: the internet, and the box's LAN unless the box blocks it.
  Not the box itself, not other environments, and not the tailnet except
  through the environment's own node.
- Bind mounts of host paths outside the workspace bind the VM's paths,
  which hold none of your files.

Boxes before environment VMs refused most of the list above, with a
compose policy a box could loosen with `FOREMAN_POLICY`. That's gone.

## Docker inside an environment

The docker-in-docker feature works, and so does a `docker:dind`
sidecar with `privileged: true`. Either runs a daemon of its own inside
the environment's VM, with its images on the environment's data disk.

Often a daemon isn't needed, and leaving it out saves the second
daemon's memory and disk:

| What dind was for | Without it |
|---|---|
| Databases, caches, search, Selenium and other services | Add them to the compose file as sidecars. They get their own volumes per copy, and pick up secrets through `${NAME}`. |
| Building and deploying images | A remote builder or CI. `fly deploy` builds remotely by default; with plain Docker, point `docker buildx` at a remote builder or build in a workflow. |
| Pulling, retagging or pushing images | `crane` or `skopeo`, which need no daemon. |

## GPUs

Environments can't use a box's GPUs. A VM gets none of the box's
devices, Foreman doesn't pass GPUs through, and the devcontainer CLI
runs with `--gpu-availability none`. A compose service that reserves a
GPU fails to start. Before environment VMs, a box could let
environments share its NVIDIA GPUs (`FOREMAN_POLICY=gpu=allow`); that
went with shared Docker.

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

Every environment builds with the Docker in its own VM, so nothing is
shared between environments: a second copy of a repo pulls its images
and builds from scratch, as the first did. Within an environment, a
rebuild reuses that environment's cache and rebuilds from the first
layer whose files changed. It recreates the containers but doesn't
refetch a base image tag that has moved, so pin base images rather than
relying on `:latest`.

The cache lives on the environment's data disk and grows until it's
pruned. **Prune** on the box's page prunes Docker in every running
environment's VM (build cache unused for a week, dangling images and
unused anonymous volumes) and removes guest images and agent disks no VM uses any
more. Stopped environments aren't pruned. Nothing runs it on a
schedule.

## Prebuilds

A prebuild saves the cold start. An admin builds one from the repo's
page, per box: the box makes an environment of the repo's default branch
in a VM of its own, keeps its disk (the clone, the pulled images, the
build cache), and throws the VM away. A new environment of that branch
on that box then starts from a copy of the disk (a reflink on XFS, so
instant) and its `devcontainer up` builds from the cache instead of
pulling and building from nothing. Environments of other branches, and
on other boxes, build as before.

What runs where:

- The prebuild runs `initializeCommand`, `onCreateCommand`,
  `updateContentCommand` and `postCreateCommand`, so whatever they
  install or download is on the disk. The environment made from it gets
  containers of its own, and the CLI runs those hooks again in them,
  then `postStartCommand`; hooks that skip work already done are fast.
- Named volumes and containers aren't kept: the environment's are its
  own, under its own name. A database a hook seeded is seeded again.
- The clone is brought up to the branch's tip when the environment is
  made, with that user's own token, so a prebuild a few days old gives
  today's code (and rebuilds whatever layers changed). Files the hooks
  made in the tree, like `node_modules`, stay.
- The prebuild clones with a GitHub token that reads the repo (and its
  extra repos) and nothing else, and has no one's secrets: no user,
  repo or environment secrets, no Tailscale key. A hook that needs a
  secret fails in the prebuild, so keep those in `postStartCommand` or
  make them skip without it.
- Everyone whose GitHub token reads the repo and its extra repos gets
  what's on the disk; anyone else's environment builds from nothing.
  Don't have a hook write anything there you wouldn't commit.

Build again after the devcontainer or its base images change: a
prebuild isn't refreshed on its own, and an environment from a stale one
still works, rebuilding the layers that changed. A new build replaces
the old one once it's ready; **Delete** frees its disk. The page shows
the prebuild new environments start from and, when it's another, the
latest attempt; one built for a default branch or devcontainer config the
repo no longer uses says it won't be used. **Prune** on the box's page
also deletes any prebuild disk the control plane no longer knows about.

## What to remove

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
- **Bind mounts to host paths** outside the repo: the host is the
  environment's VM, which has none of your files.
- **`ports:`** can stay; the overlay strips them.

## What trips a port up

Each of these broke a real repo moving onto Foreman. None of them shows
up as an error from Foreman.

- **The remote user doesn't run as the uid you set.** The devcontainer CLI
  changes the remote user's uid and gid to the host user's that runs it,
  which is the guest agent's own user in the VM (`foreman`, UID and GID
  1000 on new disks). Disks initialized by 0.6.0 or 0.6.1 keep their
  original 997:993 ownership so existing workspaces and volumes remain
  accessible. If a container system account occupies UID 997 and the
  initial build failed on one of those disks, create a fresh environment
  with the updated guest image. A Dockerfile's `useradd -u 1000` or common-utils'
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
- **Dotfiles are cloned to `~/dotfiles`.** If they expect another path
  (`~/.dotfiles`, say), set "Clone to" next to them in Settings.
- **With HOME in a named volume, dotfiles install once.** The CLI skips
  them while `~/.devcontainer/.dotfilesMarker` exists, and the volume
  keeps it across rebuilds. To reinstall, delete it and rebuild.

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
