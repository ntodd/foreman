# Private images and features on GHCR

Only the team deployment needs this: monolith's devcontainer pulls
`ghcr.io/acme/devcontainer-features/base`, which is
private. The personal deployment pulls only public images.

GHCR only lets **classic** personal access tokens pull private packages;
GitHub App tokens and fine-grained tokens can log in but can't pull. So
Foreman uses a machine user's classic token, kept as an owner-level
registry credential (not an environment secret), and automates the rest.

GitHub has no API for creating personal access tokens, so steps 1–3 are
by hand. Each takes a minute.

## 1. Create the machine user

A separate GitHub account, for example `acme-foreman-bot`, with its
own email and 2FA. Store its credentials in the team's password manager.

## 2. Let it read the package

In the org: **Packages → devcontainer-features/base → Package settings →
Manage access → Add** the machine user with **Read**. Do this for every
private package the devcontainers use. (If the package inherits access
from a repo, give the machine user read access to that repo instead.)

## 3. Create a classic token with only `read:packages`

Signed in as the machine user: **Settings → Developer settings →
Personal access tokens → Tokens (classic) → Generate new token**.

- Scopes: **only `read:packages`**. Nothing else.
- Expiration: GitHub allows "no expiration", but a year with a calendar
  reminder is better. Foreman warns two weeks before it lapses.
- If the org enforces SAML SSO, click **Configure SSO → Authorize** for
  the org on the new token.

## 4. Paste it into Foreman

**Deployment → acme → Container registry credential →
Add**: registry `ghcr.io`, the machine user's login, and the token.

Foreman checks it before saving:

- the token's scopes include `read:packages`
- it can pull every private image and feature that the owner's repos
  reference

and records its expiry from GitHub's
`GitHub-Authentication-Token-Expiration` header. If a check fails,
nothing is saved and the page says which reference couldn't be pulled.

## How it's used

When a build needs it, the agent writes the credential to a throwaway
Docker config directory for that one `devcontainer up` (the CLI's
feature downloads and Docker's image pulls both read it), and deletes it
afterwards. The token never appears on a command line, and it's
redacted from build logs.

Repos whose devcontainer references a private `ghcr.io/<owner>/...`
image or feature, while the owner has no credential, are flagged on the
Repos page and the new-environment form, so a build doesn't start just
to fail.

## Rotating

Create the new token, paste it in with **Replace**, then delete the old
one on GitHub. Running environments aren't affected; the credential is
only used during builds.
