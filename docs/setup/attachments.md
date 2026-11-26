# Images on issues and pull requests

`gh pr edit --attach shot.png` uploads a file to GitHub and adds it to the pull
request's body. Coding agents use it to show what they changed. By default it
fails in an environment:

```
could not upload shot.png: attaching files requires write access to the repository
```

The message is misleading. GitHub's attachment upload endpoint only accepts
personal access tokens. It returns 404 for a GitHub App token, no matter what
that token is allowed to do
([cli/cli#14309](https://github.com/cli/cli/issues/14309)), and every token
Foreman gives an environment is a GitHub App token.

So Foreman does the upload for the environment. An admin sets an **attachment
token** for each owner. The control plane stores it and uploads with it, and
`gh --attach` works in that owner's environments with no change to how you run
it. The token is never sent to a box or an environment.

## 1. Pick the account

You need a fine-grained personal access token from an account that has
**write** access to the repos that environments attach files to.

- **Team:** use a machine user, such as the one that pulls private images
  ([ghcr-machine-user.md](ghcr-machine-user.md)). Give it the Write role on
  those repos, directly or through a team.
- **Personal:** your own account already has write access.

GitHub doesn't show who uploaded an attachment. The pull request or comment
that contains the image is still posted by the person who owns the
environment.

## 2. Create a fine-grained token with no permissions

Signed in as that account, go to **Settings → Developer settings → Personal
access tokens → Fine-grained tokens → Generate new token**.

- **Resource owner:** the org (or your own account) that owns the repos. The
  org has to allow fine-grained tokens, and may require an owner to approve
  this one.
- **Repository access:** *Only select repositories*, then pick the repos that
  environments attach files to. *All repositories* also works, but is broader
  than needed.
- **Permissions:** none. Leave everything at *No access*. GitHub adds
  *Metadata: Read-only* automatically.
- **Expiration:** whatever the org allows. Foreman shows the expiry date and
  highlights it two weeks before.

The upload endpoint ignores the token's permissions. It checks two things:
that the token includes the repository, and that the account can write to it.
A token with no permissions can upload attachments to the selected repos and
read their metadata, and that's all.

## 3. Add it to Foreman

Go to **Deployment → *the owner* → Attachment token → Add** and paste the
token.

Foreman checks the token with GitHub before saving it. It only accepts
fine-grained tokens. A classic token would also work for uploads, but its
scopes allow much more.

## What an environment needs

There's nothing to configure in a repo. An environment needs:

- **Foreman feature 1.3.0 or later,** from a box whose agent release includes
  it. The feature installs a small helper, `foreman-gh-attach`, and a `gh`
  wrapper that runs gh through it. The environment page offers a rebuild when
  the box has a newer feature than the environment was built with.
- **gh 2.102 or later.** Older versions reject the environment's token
  themselves, before uploading anything.
- **Your own write access to the repository.** Foreman only uploads for
  someone GitHub would have accepted the upload from.

The Foreman CLI isn't involved, and the feature's `cli` option doesn't affect
this.

After that, every gh command that takes `--attach` works as documented:

```sh
gh pr create --title "Fix the login error" --body-file body.md --attach ./login.png
gh pr edit 23 --attach './after.png#The login page after the fix'
gh issue comment 7 --body "Reproduced." --attach ./repro.mp4
```

## How it works

1. The feature's `gh` wrapper sees `--attach` and runs gh through
   `foreman-gh-attach`.
2. The helper starts a proxy on loopback for that one gh process. The proxy
   handles requests to `uploads.github.com` itself and passes every other
   connection through untouched. gh trusts the proxy through a certificate
   authority created for that run. The authority is only valid for that one
   host name, and it's deleted when gh exits. The proxy only serves the gh
   process it started.
3. gh uploads as usual. The proxy sends the file to the control plane in
   chunks, over the environment's own connection (`/run/foreman/api.sock`).
4. The control plane checks that the file is an image or video, that it's for
   the environment's own repository, that it's within the size limits, and
   that you have write access to that repository on GitHub. Then it uploads
   the file with the owner's attachment token and returns the asset's URL.
5. gh puts the URL in the body, the same as it would after its own upload.

gh still does its own checks and its own markdown rewriting. The only
difference is where the file's bytes are sent.

## Limits

- Images up to 10 MB (GitHub's limit) and video up to 25 MB.
- png, jpg, jpeg, gif, webp, svg, mp4, mov and webm, the same as gh.
- Only the environment's own repository. A pull request in another repo (an
  extra repo, or a fork's parent) can't get attachments this way yet.
- A service account's environment has no connection of its own to the control
  plane, so `--attach` fails there the same way it does without Foreman.

## Troubleshooting

| gh says | What it means |
|---|---|
| `attaching files requires write access to the repository`, after a line starting with `foreman:` saying attachments aren't set up | The owner has no attachment token. gh tried its own upload and GitHub rejected it. Add a token (step 3). |
| `attaching files requires write access to the repository`, with no `foreman:` line | Either your account doesn't have write access to the repository (gh checks that before uploading), or the environment has no helper. Check with `ls /usr/local/share/foreman/foreman-gh-attach`. If it's missing, the environment was built with a feature older than 1.3.0 or from an agent release without the helper. Rebuild it. |
| `GitHub rejected the upload. The attachment token's account … needs write access to …` | The token's account can't write to that repo, or the token doesn't include it. Fix the account's role or the token's repository list. |
| `GitHub rejected the attachment token for …` | The token expired or was revoked. Replace it on the Deployment page. |
| `This environment can only attach files to …` | The pull request or issue is in a different repository. |
| `You need write access to … on GitHub to attach files to it` | You can read the repository but not push to it. GitHub wouldn't accept the upload from you directly either. |
| A `foreman:` line about a proxy, or `couldn't connect to …` | The helper sends gh's other connections wherever the environment's proxy settings say. It supports HTTP and HTTPS proxies. It doesn't support SOCKS proxies, so gh can't connect through one. |
| `unsupported authentication type` | gh is older than 2.102. Update it in the image. |

Every upload is recorded in the audit log (**Admin → Audit**) as
`environment.attachment`, with the file's name and size, the repository, the
asset's URL and who requested it.

## Without an attachment token

If an owner has no attachment token, the helper passes gh's own upload through
to GitHub unchanged, so having the wrapper installed doesn't break anything.
If GitHub starts accepting GitHub App tokens, `--attach` will work without an
attachment token.

If you run gh with your own token (`GH_TOKEN=… gh …`, or `GITHUB_TOKEN`), the
wrapper stays out of the way. It only acts when gh is using the token Foreman
provides. That also applies to an environment where `GITHUB_TOKEN` is set as a
secret: gh uses that secret, as it does anywhere else, and not Foreman's
token. A script that reads Foreman's token with `gh auth token` and passes it
back in `GH_TOKEN` is still using Foreman's token, so its uploads go through
Foreman too (from feature 1.3.1).

## Using your own gh login

To make gh use your own login in an environment, turn Foreman's token off for
that command:

```sh
FOREMAN_GH_TOKEN=off gh auth login                      # once
FOREMAN_GH_TOKEN=off gh pr edit 23 --attach ./shot.png  # as that login
```

With `FOREMAN_GH_TOKEN=off`, the wrapper runs gh untouched. It doesn't set
Foreman's token and doesn't upload through Foreman, so the upload is gh's own
and can do whatever your login allows. This has to be an explicit setting: gh
won't store a login while a token is set in its environment, and it uses a
token from the environment before a stored login.

To make this the default somewhere, export the variable in a shell, or set it
as an environment or user secret. git still pushes with Foreman's token either
way. A login stored in an environment is a credential that anything running
there can use, and it stays until you run `gh auth logout`.
