# Team deployment

For a small team: the control plane on a small EC2 instance with
Postgres (Neon or RDS), and roughly a box per developer.
Start from [personal.md](personal.md); this page covers what differs.

| | |
|---|---|
| Database | Postgres. Use the `-pg` image (`ghcr.io/<owner>/foreman:0.3.0-pg`, or a build with `--build-arg FOREMAN_DB=postgres`) and set `DATABASE_URL`; the image remembers which database it was built for, so there's no `FOREMAN_DB` to set at runtime (one that disagrees with the build stops it from starting). The database in `DATABASE_URL` must already exist: Foreman runs its migrations on boot but doesn't create it (Neon and RDS make one for you). TLS with certificate checks is on by default (`DATABASE_SSL=true`), which Neon requires. |
| Names | `FOREMAN_SLUG_STYLE=team` gives `storefront-alice-1`, so developers' environments never collide. |
| Who signs in | `FOREMAN_ALLOWED_ORG=acme` (active org members) plus `FOREMAN_ADMINS`. The org check needs the app's **Members: read** permission, which the manifest requests. |
| GitHub App | Create it on the org (enter the org's login on the setup page). Installing it on the org needs an org owner. |
| Tailscale | The Standard plan (Personal is non-commercial). Environments also get `tag:foreman-<login>`, so ACLs can keep each developer to their own. Every such tag must be in `tagOwners` and allowed on the OAuth client. |
| Private images | If a repo's devcontainer uses a private image or feature on GHCR, add a registry credential: [ghcr-machine-user.md](ghcr-machine-user.md). |
| Images on pull requests | For `gh --attach` to work in environments, which GitHub refuses from the tokens they hold, add an attachment token: [attachments.md](attachments.md). |

For RDS, mount the RDS CA bundle read-only inside the control-plane container and set `DATABASE_SSL_CACERTFILE` to its absolute path in the container. Foreman verifies the database hostname and certificate using that bundle. By default it uses the operating system's CA store.

```sh
# docker/.env, beside compose.yml
FOREMAN_IMAGE=ghcr.io/<owner>/foreman:0.3.0-pg
```

```sh
# /etc/foreman/foreman.env (0600)
SECRET_KEY_BASE=...
# Keep a copy of this one in Secrets Manager.
FOREMAN_ENCRYPTION_KEY=...
DATABASE_URL=ecto://user:pass@ep-example.us-east-2.aws.neon.tech/foreman
PHX_HOST=foreman.tail1234.ts.net
FOREMAN_LISTEN_IP=0.0.0.0
FOREMAN_SLUG_STYLE=team
FOREMAN_ALLOWED_ORG=acme
FOREMAN_ADMINS=alice
FOREMAN_TAILSCALE_CLIENT_ID=...
FOREMAN_TAILSCALE_CLIENT_SECRET=...
FOREMAN_AGENT_RELEASE_PUBLIC_KEY=...
FOREMAN_AGENT_RELEASE_DIR=/var/lib/foreman/releases
```

The instance needs no inbound ports: put it on the tailnet and use
`tailscale serve` as in the personal setup. GitHub's OAuth callback is a
browser redirect, so a tailnet host name works.

`GET /healthz` answers `200 ok` when the app is up and the database
answers, and `503` when it doesn't. The image's `HEALTHCHECK` uses it,
so `docker compose ps` shows whether the database is reachable. It
needs no sign-in, so a load balancer or monitor can use it too.

Back up and upgrade as in [upgrading.md](upgrading.md); with Postgres,
take a snapshot before each upgrade.

## Boxes

A box is an amd64 Linux machine (6.2 or later, with Landlock) with
KVM; each environment on it runs in a VM of its own. Make a join token
per box with its developer as the owner. A box runs only its owner's environments unless it's shared on
its page. Code in one environment can't reach another's secrets or
files, or the box, since each is in its own VM. Sharing is still a
trust decision: whoever has root on a box can read every environment's
secrets and disks on it. See [../security.md](../security.md).

Every VM has a size, the environment's or repo's limits or the box's
default of 4 CPUs and 8 GB. Boxes allow placement past capacity by
default and show contention. A box that's tight on memory can be set to
**warn** (ask first) or **refuse** on its page.

Contention starts past a box's CPU threshold and its memory threshold,
both fractions of what the box has (0.9 to start). Past 1 overcommits.
CPU overcommit is cheap: an idle VM's vCPUs cost the box next to
nothing, and busy VMs share cores and run slower. Memory overcommit
isn't: a VM holds the memory its guest has touched, page cache included,
and a box that runs out kills a VM, losing everything running in it. A
box for a few big, mostly idle environments might use 4 for CPU and 1.2
for memory. Whatever the thresholds, a box whose CPU or memory is more
than 90% in use shows contention.

A developer's box can also be a Flatcar VM on a Linux machine or
Proxmox ([flatcar.md](flatcar.md)), which keeps the box's environments,
and their secrets, off the machine itself, at the cost of running them
nested (slower). With the Tailscale OAuth client set up, each Flatcar
box joins the tailnet as `tag:foreman-box`. Macs can't be boxes until
[#180](https://github.com/ntodd/foreman/issues/180) ([mac.md](mac.md)).

On a cloud instance, install with `--block-lan` if environments
shouldn't reach the instance's private network. Both LAN modes block access to
link-local metadata. On existing boxes, rerun the install script after updating
the agent to load the new rules ([box setup](personal.md#5-add-the-desktop-as-a-box)). The instance
needs KVM: bare metal, or an instance type with nested virtualization.
