# Security model

What Foreman protects, where the trust boundaries are, what defends each
one, and what it knowingly doesn't. Written to be red-teamed: the "Known
gaps" section is the place to start.

## What's worth stealing

| Asset | Where it lives |
|---|---|
| Environment secrets (owner, repo, user, environment) | Control plane DB, encrypted (AES-256-GCM, Cloak); on boxes in `/run/foreman/envs/<id>/` (tmpfs, 0600) |
| GitHub user access and refresh tokens | Control plane DB, encrypted |
| Scoped GitHub tokens | Boxes, `/run/foreman/envs/<id>/github-token` |
| GitHub App private key and client secret | Control plane DB (encrypted) or its environment |
| Tailscale OAuth client secret | Control plane environment |
| Registry (GHCR) tokens | Control plane DB, encrypted; on a box only during a build |
| `FOREMAN_ENCRYPTION_KEY`, `SECRET_KEY_BASE` | Control plane environment |
| Agent private keys | Each box, `/var/lib/foreman-agent/identity.json` (0600, agent user) |
| The boxes themselves | The agent user is in the `docker` group, which is root |

## Trust boundaries

### People and the control plane

- The control plane listens on loopback (or a tailnet address) and is
  served to the tailnet by `tailscale serve`. It isn't meant to be on
  the internet.
- Sign-in is GitHub only, through the app's OAuth flow with PKCE and a
  `state` check. Who may sign in: `FOREMAN_ADMINS`,
  `FOREMAN_ALLOWED_USERS`, active members of `FOREMAN_ALLOWED_ORG`.
  That holds for admins too: an admin dropped from all three is
  refused, whatever role their record has. The one exception is a
  deployment with neither `FOREMAN_ADMINS` nor an org set, where admins
  are managed in the UI and an existing admin may sign in. Who may sign
  in is checked again at every GitHub token refresh and every six hours
  for anyone with a live session; a definite "no" ends their sessions
  and drops their GitHub tokens (their environments keep running without
  one), while a GitHub error changes nothing. GitHub answers "not a
  member" with a 404, which it also gives for an org it can't find, so a
  404 only counts once the org itself resolves. Someone whose GitHub
  login has expired can't be checked against the org, so they're signed
  out and checked when they sign in again. Accounts are matched by GitHub id; a
  login only matches a record that has no GitHub id yet, so someone who
  takes a renamed user's old login doesn't get their account.
  Sign-in attempts are rate limited per client. Behind a loopback proxy
  (`tailscale serve`) the client is the last `X-Forwarded-For` entry;
  that header is ignored from any other peer.
- Sessions: a random 32-byte token in an encrypted, signed, `HttpOnly`,
  `SameSite=Lax` cookie (`Secure` in production); only its SHA-256 is
  stored, so a database leak doesn't leak sessions. Sessions last 30
  days and die when a user is disabled. Disabling a user or changing
  their role also drops their open pages, so a LiveView can't keep old
  powers. The session is renewed at sign-in.
- Every page sends a CSP with no inline scripts or style attributes
  (`script-src 'self'; style-src 'self'`; Oban Web's pages need inline
  styles and get that one exception), `frame-ancestors 'none'`,
  `X-Frame-Options: DENY` and, over HTTPS, HSTS. Forms may post only to
  the app and to github.com (the GitHub App manifest).
- Authorization is by scope: members see and act on their own
  environments, boxes they own or that are shared with them, and their
  own secrets. Owner and repo secrets, repo settings, boxes, people and
  deployment settings are admin only. Admin pages 404 for members.
- Secrets are write-only: the UI and every context function return
  secrets without values. The audit log records names, never values.
- First run: until a GitHub App exists, `/setup` needs a one-time
  token printed in the boot log.

### Agents and the control plane

- Agents dial out; boxes need no inbound ports.
- Enrollment spends a single-use join token (random 32 bytes, stored
  hashed, valid for an hour, created by an admin). The agent generates
  its own ed25519 keypair; only the public key leaves the box.
- Every socket connect is signed: agent id, a timestamp and a random
  nonce, signed with the agent's key, in `x-foreman-agent-*` headers.
  The control plane refuses unknown or revoked agents, bad signatures,
  clocks more than 60 seconds off, and nonces it has seen in the last
  two minutes. Refused connects are rate limited per client (600 a
  minute), so junk from one address can't lock out signed agents.
  Revoking a box deletes its key and drops its socket.
- No distributed Erlang anywhere (`RELEASE_DISTRIBUTION=none`): a
  connected Erlang node can run arbitrary code on its peers.
- A fixed command vocabulary, no generic exec. Every command and event
  is validated by `ForemanProtocol` on both sides, with types as narrow
  as their use: slugs are DNS labels, env ids UUIDs, branch names can't
  start with `-`, clone URLs can't carry credentials, secret file names
  come from an allowlist, compose variables can't override `PATH`,
  `DOCKER_HOST`, `LD_PRELOAD` and the like.
- An agent may only report on its own box's operations and
  environments; anything else is refused and logged.
- Agent self-update: the release signature (ed25519 over version, target
  and SHA-256) is checked against the public key compiled into the
  running agent, before downloading; the digest after. Tarball paths
  that escape the release directory are refused. The signing key lives
  only in CI, so a compromised control plane can't push agent code. A
  failing new release is rolled back by a systemd `OnFailure` unit.

### The control plane and its host

The control plane runs as an unprivileged user in its container, with
no Docker socket. Updating it from the Deployment page goes through
`foreman-update` on the host, which runs as root
([upgrading.md](setup/upgrading.md#from-the-deployment-page)):

- The container writes to one directory, `/var/lib/foreman-update/request`,
  and reads the updater's status from another, mounted read-only. It
  can't touch the backups, the updater or its config.
- The updater reads at most a line from `request/version`, never through
  a symlink, and never repeats what it read. It acts only on an `X.Y.Z`
  newer than the running version, pulled from the repository the running
  image came from. So a compromised control plane can ask for a newer
  release, or nothing: not another image, not a downgrade, not a command.
- The updater replaces itself with the copy in the new image, read from
  the pulled image and not the running container, which the control
  plane could have changed. The copy in the image is root's.
- Images aren't signed. The updater trusts the registry as `docker
  compose pull` does; anyone who can push a release image to it can run
  code as the control plane, the same as for an upgrade by hand.

### Repo content and the box

The repo, and anything running in an environment, is treated as hostile
to the box it runs on (up to the limits in "Known gaps").

- Commands are run with an argv, never a shell string, and with a clean
  environment, so nothing from the agent's own environment (like its
  join token) reaches a child.
- Clone hosts are allowlisted per box (`github.com` by default); plain
  HTTP needs an explicit opt-in per host. The GitHub token reaches git
  through a credential helper reading a file, never the URL or
  `.git/config`.
- The workspace is writable from inside the environment, so the agent
  never follows a symlink out of it (`ForemanAgent.SafeFS`): reads
  resolve symlinks only inside the clone, writes replace rather than
  write through a symlink, and directories it creates refuse symlinked
  parents.
- `initializeCommand` is dropped from the config the devcontainer CLI
  sees (it would run on the box).
- Environments run unprivileged. On every start (anything inside can
  rewrite its own config) the agent checks the compose config with every
  profile enabled (`docker compose --profile '*' config`),
  `devcontainer.json`, and what the devcontainer CLI resolves from
  features (the repo's and the user's own) and image metadata, before
  anything runs. Compose reads some files while it parses (env files,
  label files, the files a compose file includes or extends, and an
  include's env files), folds them in where the path no longer shows,
  and quotes any it can't parse in its error. So before compose runs,
  the agent reads the repo's compose files itself (with a vendored
  js-yaml, run by the box's Node: Erlang's yamerl resolves aliases to
  lists and maps wrongly), follows includes and extends inside the
  clone, and checks every file compose would read.
  Merge keys are kept rather than merged, so every value a merge could
  produce is checked. A path built from variables, a remote include, an
  unknown YAML tag, or files that expand past a size budget are refused,
  and so are `runServices` entries that aren't in the checked compose
  files. By default it refuses all of these:
  - privileged containers: `privileged: true`, the docker-in-docker
    feature, any feature whose metadata asks for privileged, and
    capabilities that amount to root on the box (`SYS_ADMIN`,
    `SYS_MODULE`, `SYS_RAWIO`, `DAC_READ_SEARCH`, `BPF`, `PERFMON`,
    `MAC_ADMIN`, `ALL`), whether the repo, a feature or the merged
    configuration asks for them
  - turning seccomp off (`seccomp=unconfined`, which the official Go and
    Rust features ask for): its own `seccomp` rule, so a box can allow it
    without allowing privileged containers
  - any other `security_opt` / `securityOpt` than `no-new-privileges`
    (under the privileged rule)
  - the host's network, PID, IPC, UTS or cgroup namespace,
    `userns_mode: host`, and joining another container's namespaces or
    volumes (`container:…`, `volumes_from`); `service:` within the
    project is fine
  - the Docker socket, including through a feature's mounts or a bind of
    a directory that contains it
  - host binds outside the workspace, and host files read through
    `env_file`, `secrets`, `configs`, build contexts, Dockerfiles or
    build `ssh` keys. Paths in the workspace are resolved, so a symlink
    pointing out of it counts as the host path it points to.
  - named volumes that are really host paths (`driver_opts` with
    `o: bind` or a `device`), and volumes from outside the project
    (`external`, or a `name:` belonging to another project)
  - host devices, `/dev/net/tun` included, also through
    `device_cgroup_rules`, device reservations that aren't NVIDIA GPUs,
    `runtime: nvidia`, and a box whose Docker runs nvidia as its default
    runtime (any image could then take the GPUs through its environment)
  - NVIDIA GPU reservations (`deploy.resources.reservations.devices`,
    `gpus`), under their own `gpu` rule. Only `driver: nvidia` with the
    driver capabilities listed, from `compute`, `compat32`, `utility` and
    `video`, counts as a GPU; anything else, `graphics` and `display`
    included, is a host device. The devcontainer CLI runs with
    `--gpu-availability none`, so `hostRequirements.gpu` can't add a
    reservation after the check. GPUs and their memory are shared by the
    box's environments.
  - builds that run privileged, on the host network, or with BuildKit
    entitlements (`security.insecure` is privileged)
  - networks from outside the project (`external`, or a fixed `name:`):
    another environment's network reaches its sidecars. So are network
    drivers other than `bridge` (macvlan and ipvlan put containers on the
    box's own network), Docker's default bridge (`network_mode: bridge`)
    and a network named directly in `network_mode`
  - `devcontainer.json` or feature mounts of an `external` volume that
    isn't this environment's
  - `use_api_socket` (the Docker socket, under its rule)
  - any compose key the agent hasn't reviewed (`compose_keys`), at the
    top level, in a service or in a build: whatever Compose adds next is
    refused until someone has looked at it. `x-` extension keys are fine.

  `provider` services are refused whatever the box allows: Compose runs a
  provider's `type` as a program on the box.

  The overlay puts every network an environment uses on a bridge named
  `fm-` and a hash of the environment and network, replacing any bridge
  name the repo set. A network that ends up on any other bridge is
  refused whatever the box allows: that name is how the box tells
  environment traffic from other containers'.

  Binds and host files that expose the agent's state, other environments
  or secrets directories are refused whatever the box allows. A failed
  `compose config` returns a generic error; its output goes to the
  redacted operation log, never into the error, and the agent's own key
  is redacted from everything it sends. A box can loosen a
  rule with `FOREMAN_POLICY` on its agent (for example
  `privileged=allow`). The agent reports its policy when it connects,
  and the control plane shows any box that has loosened one with a red
  alert on its page and its cards.
- git status before a destroy runs inside the container, not on the
  box (a repo's `.git/config` can name programs to run).
- Secrets on a box: a tmpfs directory per environment, 0700, files
  0600, owned by the agent user, bind-mounted read-only at
  `/run/foreman`. Inside the environment, the container's own
  environment (which can include compose-interpolated secrets) is saved
  to `/etc/foreman/container.env`, mode 0644, so SSH shells get it; any
  user in that container can read it. On Linux the devcontainer CLI gives the container's
  user the agent's uid, so the environment reads them and other users
  on the box can't.
- Secret values are kept out of logs twice: the agent scrubs every value
  a command carried from its output and errors (and drops the CLI's
  compose-config dumps; a crash is reported only by its exception type); the control plane scrubs the environment's
  resolved secrets from every log chunk and error before storing or
  showing it, which covers container logs the agent had no values for.
- Registry credentials go to a throwaway `DOCKER_CONFIG` for one build,
  never argv, and are deleted afterwards.
- Connect hooks ([connect-hooks.md](setup/connect-hooks.md)) are code
  from the environment, so the agent runs them inside the devcontainer
  as its remote user, with a timeout inside the container as well as on
  `docker exec` (stopping `docker exec` doesn't stop what it started). It takes only a hook name and an
  action id that are short lowercase names, and holds what they print
  to a few short single-line fields (`ForemanProtocol.Connect`), checked
  again by the control plane. A hook's result is usually a credential
  for the environment (a pairing code). The agent keeps everything an action prints
  out of the operation's log and its error, except a short
  `{"error": ...}` the hook writes for that purpose. The
  control plane takes it out of the result before recording the
  operation and broadcasts it only to the page that asked. Only the
  environment's owner can run an action, not an admin, and the audit
  log records the hook and action, never the result.

### Environments and the tailnet

Each environment is a tailnet node tagged `tag:foreman-env` (plus repo
tags, and `tag:foreman-<login>` on team deployments). The suggested ACL
in [setup/tailscale.md](setup/tailscale.md) grants people access to
environments and grants environments nothing, so an environment's node
can't reach laptops or other environments. Tailscale SSH replaces sshd;
no ports are published.

That node isn't the only way out. A container's ordinary traffic is
forwarded through the box, and a box on the tailnet sends tailnet
addresses over its own Tailscale interface, so peers would see the box
and apply the box's grants. The box's firewall (an nftables table loaded
by `foreman-firewall.service`, see
[setup/tailscale.md](setup/tailscale.md#boxes-on-the-tailnet)) rejects
anything from an environment's bridges, or from Docker's default bridge
where image builds run, bound for the tailnet, the box's own tailnet
addresses (published ports included, by the destination before Docker
rewrote it) or `tailscale0`, except DNS to MagicDNS. Environment bridges
are all named `fm-...`, which the overlay and the policy guarantee
(below). The agent reports whether the firewall is loaded, and from the
rules it ships with, when it joins and whenever that changes; the
control plane flags a box without it. A process on the box that an environment can reach and that
connects onward (a proxy, say) still connects as the box.

Tailscale runs in userspace mode, without a TUN device or `NET_ADMIN`.
In that mode it delivers tailnet connections to `127.0.0.1:<port>` in
the environment, so anything listening on localhost there (a debugger,
an admin port) is reachable by every peer the ACL lets reach the
environment. Its outbound proxy listens on 127.0.0.2 for that reason.
Grant `tag:foreman-env` only to the people whose environments they are.

## Known gaps

These are accepted for now, or need someone to try them:

1. **The agent is root on its box.** The agent user is in the `docker`
   group, which is root in all but name. Environments don't get that by
   default, since privileged containers are refused, but a box that sets
   `privileged=allow` gives code in its environments root on the box:
   every other environment's secrets, the agent's key, and the host.
   The policy check makes a rewritten compose file harder to abuse, not
   impossible. A box belongs to one person, and shared boxes should
   wait for per-developer Incus containers or VMs.
2. **Container root reads 0600 files.** Root in a container has
   `CAP_DAC_OVERRIDE`, so it reads the secrets directory regardless of
   ownership. That's the environment's own secrets, by design, but also
   means "0600" isn't a boundary inside the environment.
3. **Secrets in `ps` on the box.** The devcontainer CLI puts probed
   environment variables (which include sourced secrets) on the
   `docker exec` command line during lifecycle hooks
   (devcontainers/cli#1317). Any user on the box can read them with
   `ps`. Mount `/proc` with `hidepid=2` on shared boxes.
4. **Symlink races.** `SafeFS` and the policy check resolve symlinks,
   then act. A process in the environment racing the agent could swap a
   directory for a symlink between the check and the copy of the feature
   into `.devcontainer/.foreman`, or between the policy check and
   `docker compose up` resolving a bind source. The feature copy is a
   directory of known files somewhere the agent user can write; a
   swapped bind source is a real escape, but needs a process already
   running in the environment to win the race during a start.
5. **A compromised control plane can run repo code on every box.** It
   can't run arbitrary commands (fixed vocabulary, clone host
   allowlist), but it can create environments from any repo the GitHub
   App sees, and their lifecycle hooks run in those environments (as
   root on the box, on a box that allows privileged). Keep the control
   plane tailnet-only and its admins few.
6. **The first install trusts the control plane.** `install.sh` checks
   the agent tarball against a SHA-256 the control plane sends, not the
   release signature (updates after that are signature-checked).
7. **Redaction is best effort.** Values shorter than six characters
   aren't redacted, and an encoded secret (base64, URL-encoded) isn't
   recognised. Logs are redacted a line at a time, so a value split
   across two reads is still caught. Text that has to go out before its
   line ends (a prompt, or a line over 64 KiB) holds back any tail that
   could be the start of a secret, and a tail still held when the
   operation ends is masked. Operation logs (up to 1 MB each) are stored for 30 days
   and shown to the environment's owner and admins.
8. **First sign-in claims the deployment** when no `FOREMAN_ADMINS` or
   allowlists are set. Set `FOREMAN_ADMINS`.
9. **The setup token is in the log.** Anyone who can read the log
   before setup is finished can create the GitHub App.
10. **In-memory state.** Rate limits and the connect nonce cache are per
    node and reset on restart; a captured connect header could be
    replayed within 60 seconds of a control plane restart.
11. **Keys in the environment.** `FOREMAN_ENCRYPTION_KEY` and the Tailscale
    OAuth secret are environment variables, readable in
    `/proc/<pid>/environ` by the same user and root. If the encryption key
    leaks, change it ([upgrading.md](setup/upgrading.md#changing-the-encryption-key)).
12. **Tokens in environments are usable by anything in them.** The
    scoped GitHub token can push to the environment's repo (and its
    extra repos) as the user. That's the point, but a malicious
    dependency, or a coding agent following injected instructions, gets
    the same power. Branch protection and rulesets still apply, because
    the token acts as the user.
13. **Environments share the box's kernel.** The policy keeps
    environments unprivileged, but a container escape (a kernel or runc
    bug) lands on the box: every environment's secrets there and the
    agent's key, which can ask the control plane for the secrets of
    every environment placed on that box. Tailscale runs in userspace
    mode, so Foreman adds no capabilities to the devcontainer, but most
    devcontainer images give their user passwordless sudo, and a repo
    can still add ordinary capabilities like `NET_ADMIN` itself. Keep
    boxes patched, keep them single-owner, and treat code
    in an environment (including coding agents) as able to reach
    anything the box can: there's no egress filtering, and on cloud
    instances the metadata endpoint is reachable unless blocked. The
    tailnet is the exception: the box's firewall keeps environments off
    it as the box. Something that flushes the box's whole ruleset
    removes the firewall until its timer loads it again (within 15
    seconds), and a box installed with
    `--default-bridge-reaches-tailnet` lets image builds reach the
    tailnet as the box. Even with the firewall, Docker's builder fetches
    a Dockerfile's `ADD <url>` (and a git build context) itself, from
    the box, so a Dockerfile can read from the tailnet as the box; its
    RUN steps can't. Filtering the daemon would also stop the box
    pulling images from a registry on the tailnet.
14. **No default resource limits.** Without CPU, memory or pids limits
    on the repo or environment, one runaway process can starve every
    environment on its box.
15. **Removed members keep access for up to six hours.** Membership is
    re-checked periodically, not instantly. Disable someone in Foreman to
    cut their access at once.

## Things worth trying

- Make an agent act on another box's environment or operation (forged
  ids in events, a replayed connect, a revoked box reconnecting).
- Get a secret value back out: the UI, LiveView events, the audit log,
  operation logs, error messages, `inspect` output in logs.
- From inside an environment: escape to the box without privileged
  mode; get privileges past the policy (a feature's metadata,
  `devcontainer.json` capabilities, a capability not on the list); make
  the agent read or write outside the workspace (symlinks in
  `.devcontainer`, `.git/info`, compose file paths); get a rewritten
  compose file past the policy (YAML anchors, `extends`, `include`,
  interpolation into bind sources, long-syntax binds).
- Inject into git config through identity fields, branch names, repo
  names or dotfiles settings.
- Get past the policy or the Foreman feature with a user's own
  devcontainer features: a ref that isn't an OCI ref, one with the
  Foreman feature's id, options the agent passes on, or getting them
  into another user's environments.
- Cross-user access as a member: another user's environments, secrets,
  boxes, or admin pages and Oban Web.
- Sign-in: the OAuth state and PKCE, open redirects in `return_to`, the
  dev sign-in route in a production build (it shouldn't be compiled in).
