# The GitHub App

Foreman uses one GitHub App per deployment for three things:

1. **Sign-in**, through the app's user OAuth flow (with PKCE and a state
   check).
2. **Repo browsing**: the installations' repos, polled every 15 minutes
   (Foreman has no public webhook endpoint), and checked for a
   devcontainer.
3. **Environment tokens**: the signed-in user's token, narrowed to the
   environment's repo with `POST /applications/{client_id}/token/scoped`.

## Creating it

The setup page (`/setup`, guarded by the one-time token in the boot log)
creates the app from a manifest, so there's nothing to fill in on
GitHub beyond clicking **Create GitHub App**. Leave the organization
empty to create it on your own account, or enter the org.

The manifest asks for:

| Permission | Access | Why |
|---|---|---|
| Contents | Read and write | Clone and push from environments |
| Pull requests | Read and write | `gh pr` from environments |
| Issues | Read and write | `gh issue` from environments |
| Workflows | Read and write | Pushing changes to `.github/workflows` |
| Actions | Read and write | `gh run` (watch, re-run and dispatch CI) |
| Checks | Read and write | Reading check runs; write is opt-in per repo |
| Commit statuses | Read and write | Reading statuses; write is opt-in per repo |
| Deployments | Read and write | Opt-in per repo |
| Discussions | Read and write | Opt-in per repo |
| Pages | Read and write | Opt-in per repo |
| Members | Read | Checking `FOREMAN_ALLOWED_ORG` membership |
| Metadata | Read | Required |

An environment's token never has more than this, and by default less,
for the environment's repo plus any extra repos set on the repo's page:

- Write: contents, pull requests, issues, workflows, actions
- Read: checks, commit statuses, metadata

Checks and statuses stay read-only by default so code in an environment
can't mark a required check as passed. Admins change any of these per
repo under **Repo settings**.

Foreman records what each installation was actually granted at every
sync and never asks for more, so a missing permission leaves it out of
the token instead of breaking it. The repo page flags permissions the
installation lacks.

### Apps created before Actions, Checks and the rest

The manifest only applies when the app is created. An older app has
contents, pull requests, issues, workflows, members and metadata, so
its environments get the defaults above without actions, checks or
statuses. To add them, open the app's settings on GitHub
(**Permissions & events**), add the permissions from the table, and
save. Each installation then has to accept them: the account's owner
gets an email, or finds the request under **Settings → GitHub Apps →
Configure**. Foreman picks them up at its next sync (within 15
minutes, or **Sync from GitHub** on the Repos page). Running
environments get them with their next token, at the next start or
within four hours.

After creating it, GitHub sends you to install it. Pick the repos (or
all of them); Foreman syncs as soon as you come back.

The app's credentials (client secret, private key) are stored encrypted
in the database. To manage them yourself instead, create the app by hand
and set `FOREMAN_GITHUB_APP_ID`, `FOREMAN_GITHUB_CLIENT_ID`,
`FOREMAN_GITHUB_CLIENT_SECRET` and `FOREMAN_GITHUB_PRIVATE_KEY_FILE`;
the environment wins over the database. The callback URL is
`https://<host>/auth/github/callback`, and "Expire user authorization
tokens" must be on.

The private key is a multi-line PEM, which an env file can't hold, so
give it as a file. The container runs as `foreman` (uid 999), so the
file has to be readable by that uid, and mounted in. Add the mount to
`docker/compose.yml`:

```yaml
    volumes:
      - foreman-data:/var/lib/foreman
      - /etc/foreman/github-app.pem:/run/secrets/github-app.pem:ro
```

```sh
sudo chown 999 /etc/foreman/github-app.pem && sudo chmod 0400 /etc/foreman/github-app.pem
# in /etc/foreman/foreman.env
FOREMAN_GITHUB_PRIVATE_KEY_FILE=/run/secrets/github-app.pem
```

`FOREMAN_GITHUB_PRIVATE_KEY` takes the PEM itself, which only works
where the value can span lines (`docker run -e`, or `environment:` in
compose). The control plane reads the file at boot and won't start if
it can't.

## Tokens

- User tokens last 8 hours; refresh tokens last 6 months and are single
  use. Foreman refreshes a user's token when it's within five minutes of
  expiring, one refresh per user at a time, so two can't spend the same
  refresh token.
- Scoped tokens can't be refreshed. Every 30 minutes Foreman pushes a
  freshly scoped token to each environment whose last one is more than
  four hours old. The token reaches git and `gh` through a file, so
  nothing restarts.
- If a refresh token is rejected (six months unused, or revoked), the
  user's environments keep running, but git push and `gh` stop working:
  the UI shows a banner and new shells print a notice. Signing in again
  re-scopes and pushes fresh tokens to every environment the user owns.
- A repo set to **broad** gives its environments the user's own token,
  for repos where you regularly work across other projects.
