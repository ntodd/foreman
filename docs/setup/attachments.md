# Images on issues and pull requests

`gh pr edit --attach shot.png` uploads a file to GitHub and puts it in the
pull request's body. Coding agents use it to show what they changed. Out of
the box it fails in an environment:

```
could not upload shot.png: attaching files requires write access to the repository
```

The message is misleading. GitHub's upload endpoint takes personal access
tokens and answers 404 to a GitHub App's token, whatever the token may do
([cli/cli#14309](https://github.com/cli/cli/issues/14309)). Every token
Foreman gives an environment is a GitHub App's.

So Foreman uploads for the environment. An admin gives each owner an
**attachment token**, the control plane keeps it, and `gh --attach` in that
owner's environments works with no change to how it's typed. The token never
reaches a box or an environment.

## 1. Pick the account

A fine-grained personal access token of an account that can **write** to the
repos environments attach to.

- **Team:** a machine user, such as the one that pulls private images
  ([ghcr-machine-user.md](ghcr-machine-user.md)). Give it the Write role on
  those repos, directly or through a team.
- **Personal:** your own account already has it.

Uploads don't show who made them. The pull request or comment that holds the
image is still written by the person whose environment it is.

## 2. Create a fine-grained token with no permissions

Signed in as that account: **Settings → Developer settings → Personal access
tokens → Fine-grained tokens → Generate new token**.

- **Resource owner:** the org (or your own account) that owns the repos. An
  org has to allow fine-grained tokens, and may ask an owner to approve this
  one.
- **Repository access:** *Only select repositories*, and the repos
  environments attach to. *All repositories* works and is more than it needs.
- **Permissions:** none. Leave every one at *No access*; GitHub adds
  *Metadata: Read-only* by itself.
- **Expiration:** whatever the org allows. Foreman shows the date and marks it
  two weeks before.

The upload ignores a token's permissions. It asks two things: that the token
includes the repository, and that the account can write to it. A token with no
permissions can upload attachments to the selected repos and read their
metadata, and nothing else.

## 3. Paste it into Foreman

**Deployment → *the owner* → Attachment token → Add.**

Foreman asks GitHub whose the token is before saving it, and refuses anything
but a fine-grained token: a classic one would work for the upload and carries
scopes that do far more.

## What an environment needs

Nothing is configured in a repo. An environment picks it up when it has:

- **The Foreman feature 1.3.0 or later,** from a box whose agent release
  carries it. The feature brings a small helper, `foreman-gh-attach`, and a
  `gh` wrapper that runs gh behind it. The environment page offers a rebuild
  when the box ships a newer feature than the environment was built with.
- **gh 2.102 or later.** Older ones refuse an environment's token themselves,
  before anything is uploaded.
- **Write access of your own to the repository.** The upload is made with the
  attachment token, and only for someone GitHub would have taken it from.

The Foreman CLI isn't involved, and the feature's `cli` option makes no
difference.

Then any of gh's commands that take the flag work as documented:

```sh
gh pr create --title "Fix the login error" --body-file body.md --attach ./login.png
gh pr edit 23 --attach './after.png#The login page after the fix'
gh issue comment 7 --body "Reproduced." --attach ./repro.mp4
```

## How it works

1. The feature's `gh` wrapper sees `--attach` and runs gh behind
   `foreman-gh-attach`, the helper the feature installed.
2. The helper starts a proxy on loopback for this one gh, which answers for
   `uploads.github.com` itself and tunnels every other connection untouched.
   gh trusts it through a certificate authority made for the run, good for
   that one host name and gone when gh exits. The proxy serves only the gh it
   started.
3. gh uploads as usual. The proxy sends the file to the control plane over the
   environment's own connection (`/run/foreman/api.sock`), in chunks.
4. The control plane checks that the file is an image or video, that it's for
   the environment's own repository and within the size limits, and that you
   can write to that repository on GitHub yourself. It uploads the file with
   the owner's attachment token and returns the asset's URL.
5. gh puts the URL in the body, the way it would have with its own upload.

gh does its own checks and its own rewriting of the markdown. The only thing
that changes is where the file's bytes go.

## Limits

- Images up to 10 MB (GitHub's limit), video up to 25 MB.
- png, jpg, jpeg, gif, webp, svg, mp4, mov and webm, as in gh.
- The environment's own repository only. A pull request in another repo
  (an extra repo, a fork's parent) can't take attachments this way yet.
- A service account's environment has no connection of its own to the control
  plane, so `--attach` there fails the way it does without Foreman.

## When it doesn't work

| gh says | What it means |
|---|---|
| `attaching files requires write access to the repository`, after a line from `foreman:` about attachments not being set up | The owner has no attachment token. gh's own upload was tried and GitHub refused it. Add a token (step 3). |
| `GitHub refused the upload. The attachment token's account … needs write access to …` | The account can't write to that repo, or the token doesn't include it. Fix the role or the token's repository list. |
| `GitHub rejected the attachment token for …` | The token expired or was revoked. Replace it under Deployment. |
| `This environment attaches files to … only` | The pull request or issue is in another repository. |
| `Attaching files takes write access to …, which your GitHub account doesn't have` | You can read the repository and not push to it. GitHub wouldn't take the upload from you either. |
| The first row's message with no line from `foreman:` | Either gh's own check, made before anything is uploaded: your account can't write to the repository. Or the environment has no helper (`ls /usr/local/share/foreman/foreman-gh-attach`): it was built with a feature older than 1.3.0, or by an agent release without one, and a rebuild brings it. |
| A line from `foreman:` about a proxy, or `couldn't connect to …` | The helper passes gh's other connections on the way the environment's proxy settings say, and can go through an HTTP or HTTPS proxy. Through a SOCKS proxy it can't, and gh fails to connect. |
| `unsupported authentication type` | gh is older than 2.102. Update it in the image. |

Each upload is in the audit log (**Admin → Audit**) as
`environment.attachment`, with the file's name and size, the repository, the
asset's URL and who asked.

## Without a token

Where an owner has no attachment token, gh's own upload is sent on unchanged,
so nothing is lost by the wrapper being there. If GitHub starts taking GitHub
App tokens, `--attach` works without one.

A gh run with a token of your own (`GH_TOKEN=… gh …`, or `GITHUB_TOKEN`) is
left alone entirely: the wrapper only steps in for the token Foreman delivers.
That includes an environment where `GITHUB_TOKEN` is set as a secret: gh uses
it there, as gh does anywhere, and not Foreman's.

## Using your own gh login

To have gh act as a login of your own in an environment, switch Foreman's
token off for it:

```sh
FOREMAN_GH_TOKEN=off gh auth login                      # once
FOREMAN_GH_TOKEN=off gh pr edit 23 --attach ./shot.png  # as that login
```

With the switch, the wrapper runs gh untouched: no token of Foreman's and no
upload through Foreman, so an upload is gh's own, with whatever your login may
do. It has to be a switch. gh stores no login while a token is in its
environment, and uses any token there before one it has stored.

Export it in a shell, or set it as an environment or user secret, to make your
login the one gh uses there. git still pushes with Foreman's token either way.
A login stored in an environment is a credential anything in it can use, and
it lasts until you `gh auth logout`.
