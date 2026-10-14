# Team deployment

For a small team (four developers on
`acme/monolith`): the control plane on a small EC2
instance with Postgres (Neon or RDS), and roughly a box per developer.
Start from [personal.md](personal.md); this page covers what differs.

| | |
|---|---|
| Database | Postgres. Build with `--build-arg FOREMAN_DB=postgres` and set `DATABASE_URL`. TLS with certificate checks is on by default (`DATABASE_SSL=true`), which Neon requires. |
| Names | `FOREMAN_SLUG_STYLE=team` gives `monolith-ntodd-1`, so developers' environments never collide. |
| Who signs in | `FOREMAN_ALLOWED_ORG=acme` (active org members) plus `FOREMAN_ADMINS`. The org check needs the app's **Members: read** permission, which the manifest requests. |
| GitHub App | Create it on the org (enter `acme` on the setup page). Installing it on the org needs an org owner. |
| Tailscale | The Standard plan (Personal is non-commercial). Environments also get `tag:foreman-<login>`, so ACLs can keep each developer to their own. Every such tag must be in `tagOwners` and allowed on the OAuth client. |
| Private images | Monolith's base feature is on GHCR, so add a registry credential: [ghcr-machine-user.md](ghcr-machine-user.md). |

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
FOREMAN_ADMINS=ntodd
FOREMAN_TAILSCALE_CLIENT_ID=...
FOREMAN_TAILSCALE_CLIENT_SECRET=...
FOREMAN_AGENT_RELEASE_PUBLIC_KEY=...
FOREMAN_AGENT_RELEASE_DIR=/var/lib/foreman/releases
```

The instance needs no inbound ports: put it on the tailnet and use
`tailscale serve` as in the personal setup. GitHub's OAuth callback is a
browser redirect, so a tailnet host name works.

## Boxes

Make a join token per box with its developer as the owner. A box runs
only its owner's environments unless it's shared on its page. Sharing is
a trust decision: anyone with Docker on a box can read every
environment's secrets on it, and the docker-in-docker feature makes
environments privileged (root on the box). See
[../security.md](../security.md).

Boxes allow placement past capacity by default and show contention. A
box that's tight on memory can be set to **warn** (ask first) or
**refuse** on its page.

For shared machines, the plan is one Incus system container per
developer, each with its own Docker and agent; the control plane sees
each as a separate box. That isn't built yet.

## Monolith

[repos.md](repos.md) covers what to change in its devcontainer: the
`workspaceFolder`, moving the Codespaces secrets into Foreman (repo
secrets `HEX_API_KEY`, `OBAN_LICENSE_KEY`, `NEON_*`; user secrets
`DEV_USER_EMAIL`, `DEV_USER_OID`, `LEGACY_DATABASE_URL`), and the GHCR
credential. Neon Local's sidecars read their settings through compose
interpolation, so after changing those secrets, use **Restart affected**:
it recreates just those sidecars and restarts the devcontainer.
