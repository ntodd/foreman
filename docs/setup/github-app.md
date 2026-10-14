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
| Members | Read | Checking `FOREMAN_ALLOWED_ORG` membership |
| Metadata | Read | Required |

An environment's token never has more than this, and by default less:
contents, pull requests and issues (write) and metadata (read), for the
environment's repo plus any extra repos set on the repo's page.

After creating it, GitHub sends you to install it. Pick the repos (or
all of them); Foreman syncs as soon as you come back.

The app's credentials (client secret, private key) are stored encrypted
in the database. To manage them yourself instead, create the app by hand
and set `FOREMAN_GITHUB_APP_ID`, `FOREMAN_GITHUB_CLIENT_ID`,
`FOREMAN_GITHUB_CLIENT_SECRET` and `FOREMAN_GITHUB_PRIVATE_KEY` (or
`FOREMAN_GITHUB_PRIVATE_KEY_FILE`); the environment wins over the
database. The callback URL is `https://<host>/auth/github/callback`, and
"Expire user authorization tokens" must be on.

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
