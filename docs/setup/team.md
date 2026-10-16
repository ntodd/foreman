# Team deployment

For a small team: the control plane on a small EC2 instance with
Postgres (Neon or RDS), and roughly a box per developer.
Start from [personal.md](personal.md); this page covers what differs.

| | |
|---|---|
| Database | Postgres. Build with `--build-arg FOREMAN_DB=postgres` and set `DATABASE_URL`; the image remembers which database it was built for, so there's no `FOREMAN_DB` to set at runtime (one that disagrees with the build stops it from starting). The database in `DATABASE_URL` must already exist: Foreman runs its migrations on boot but doesn't create it (Neon and RDS make one for you). TLS with certificate checks is on by default (`DATABASE_SSL=true`), which Neon requires. |
| Names | `FOREMAN_SLUG_STYLE=team` gives `storefront-alice-1`, so developers' environments never collide. |
| Who signs in | `FOREMAN_ALLOWED_ORG=acme` (active org members) plus `FOREMAN_ADMINS`. The org check needs the app's **Members: read** permission, which the manifest requests. |
| GitHub App | Create it on the org (enter the org's login on the setup page). Installing it on the org needs an org owner. |
| Tailscale | The Standard plan (Personal is non-commercial). Environments also get `tag:foreman-<login>`, so ACLs can keep each developer to their own. Every such tag must be in `tagOwners` and allowed on the OAuth client. |
| Private images | If a repo's devcontainer uses a private image or feature on GHCR, add a registry credential: [ghcr-machine-user.md](ghcr-machine-user.md). |

```sh
docker build -f docker/control-plane.Dockerfile --build-arg FOREMAN_DB=postgres -t foreman:pg .
```

```sh
# /etc/foreman/foreman.env (0600)
SECRET_KEY_BASE=...
FOREMAN_ENCRYPTION_KEY=...             # keep a copy in Secrets Manager
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
answers, and `503` when it doesn't. It needs no sign-in, so point a
Docker `HEALTHCHECK`, a systemd watchdog or a load balancer at it, for
example `curl -fsS http://127.0.0.1:4000/healthz`.

## Boxes

Make a join token per box with its developer as the owner. A box runs
only its owner's environments unless it's shared on its page. Sharing is
a trust decision: anyone with Docker on a box can read every
environment's secrets on it. Environments themselves run unprivileged,
so code in one can't do that, unless the box allows privileged
containers (`FOREMAN_POLICY=privileged=allow`, shown with a red alert).
Don't allow it on a shared box. See [../security.md](../security.md).

Boxes allow placement past capacity by default and show contention. A
box that's tight on memory can be set to **warn** (ask first) or
**refuse** on its page.

For shared machines, the plan is one Incus system container per
developer, each with its own Docker and agent; the control plane sees
each as a separate box. That isn't built yet.
