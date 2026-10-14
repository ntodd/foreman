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

The agent checks the merged compose config every time it starts an
environment, because anything running inside it can edit the compose
files in its workspace. By default a box refuses:

- bind mounts of host paths outside the environment's workspace
  (`../..` from `.devcontainer`, the usual `/workspaces` mount, is fine)
- the Docker socket
- `env_file`, `secrets`, `configs` or build contexts outside the
  workspace
- host devices other than `/dev/net/tun`

and always refuses binds that expose the agent's own state, other
environments or secrets. Privileged services, the docker-in-docker
feature and host namespaces are allowed with a warning on the
environment's page. An admin can change these per box with
`FOREMAN_POLICY` (for example `host_bind=warn,privileged=refuse`).

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
- **Bind mounts to host paths** outside the repo: they break on other
  boxes and collide between copies (and the box refuses them).
- **`ports:`** can stay; the overlay strips them.

## Secrets: which kind

| Where the value is read | How it reaches it | After a change |
|---|---|---|
| A login shell, a dev server you start | `/run/foreman/secrets.env` | New shells immediately; **Restart all** for running processes |
| A compose file (`${NEON_API_KEY}`) | Compose interpolation at start | **Restart affected** recreates the services that use it |
| git and `gh` | `/run/foreman/github-token` | Nothing; read on every use |

## storefront, storefront-assets, webapp, toolbox

- Remove the tool socket mounts.
- Remove the IDE runtime mount, `ide-serve.sh` and `IDE_SERVE_PORT`;
  the IDE connects over Tailscale SSH.
- Remove the Tailscale scripts and settings (toolbox has none).
- Remove the hand-kept port registry comments.
- Move `.storefront.env` and `.env` values into Foreman secrets.
- storefront: add `tag:staging-access` to the repo's Tailscale tags in
  Foreman so its environments can reach a staging database.

## monolith

- `workspaceFolder: /workspaces/${localWorkspaceFolderBasename}` with
  the `..:/workspaces` mount: outside Codespaces the repo root is mounted
  at `/workspaces`, so that folder doesn't exist. Use
  `"workspaceFolder": "/workspaces"`, or mount `../..:/workspaces`.
- Move the Codespaces secrets into Foreman. Repo secrets: `HEX_API_KEY`,
  `OBAN_LICENSE_KEY`, `NEON_*` and the rest of the shared ones. User
  secrets (each developer's): `DEV_USER_EMAIL`, `DEV_USER_OID`,
  `LEGACY_DATABASE_URL`.
- Add the GHCR registry credential for the private base feature:
  [ghcr-machine-user.md](ghcr-machine-user.md).
- `customizations.codespaces` can go. The `secrets` declarations in
  `devcontainer.json` are worth keeping as documentation.
- Neon Local's sidecars get their settings through compose
  interpolation, and delete their branch on a graceful stop, which is
  what **Stop** does.
