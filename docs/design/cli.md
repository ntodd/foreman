# Foreman CLI for Linux and macOS

**Status — implementation requested.** This document defines the first standalone CLI release.

## First session

### Install the CLI

Add an **Install the CLI** section under **You → Connected apps**, visible to every signed-in user, including before they have connected an app. Show two separately copyable commands. The first installs the executable on the machine where the user runs it. The second starts device login against this control plane. Render the configured public instance origin in both commands. For example:

```sh
curl -fsSL https://foreman.example.org/cli/install.sh | sh
foreman --instance https://foreman.example.org login
```

Serve the installer over HTTPS so it works from a headless shell without browser cookies. Both commands are free of account credentials. The installer detects the shell host's OS and CPU, downloads the matching official CLI release, verifies its SHA-256 against the release manifest, and installs `foreman` into `~/.local/bin` as the current user. If that directory is outside `PATH`, print the command to add it before login. Unsupported targets and failed verification produce an actionable error and preserve any existing executable.

### Connect and launch

A developer installs `foreman` on a laptop or headless host and connects to their own Foreman instance. They can approve the login on a second device. Once connected, they can run the following commands from any directory.

```sh
foreman --instance https://foreman.example.org login
foreman me
foreman repo list
foreman env create acme/payments --branch fix/checkout
foreman env show "$ENV_ID"
foreman env stop "$ENV_ID"
```

Create prints the environment and operation IDs as soon as the server accepts the request. The developer can use those IDs in another terminal, even while provisioning runs. Omitting the branch uses the repository default. Omitting the box delegates placement to Foreman. No local Git checkout is required.

## Command surface

| Command | Behavior |
|---|---|
| `login [--scope '…']`, `me`, `logout` | Connect with device approval, inspect the acting identity, or revoke the selected personal connection. Preserve the existing explicit `--instance`, `--account` and `--scope` invocations and the JSON output of `me` when piped or given `--json`. At a terminal, `login` and `me` name the instance and the user's GitHub login, and describe a grant that holds every default permission in words instead of listing it. |
| `repo list`, `box list`, `env list` | List resources visible to the acting identity. Show full IDs in a copyable form. At a terminal, `env list` shows one status per environment, its repository and box by name, and its age. A connection that may not list repositories or boxes sees their IDs instead. |
| `env create REPO [--branch NAME] [--box BOX] [--expires-at TIME --on-expiry stop\|destroy]` | Accept a repository UUID or exact owner/name. Accept a box UUID or exact box name. Resolve names through all visible pages, require a unique match, and allow direct UUID use without list permission. Require both expiry fields together. |
| `env show ENV` | Show observed and desired state, current readiness, expiry and any connection details returned by the API. Surface unknown readiness when a box loses contact. |
| `env restart ENV [--all]` | Recreate the services whose compose configuration uses a secret that changed, and restart the workspace container. With `--all`, stop and start every container without recreating any, for processes that read the secrets file. The workspace container restarts either way. The environment must be running. |
| `env start ENV`, `env stop ENV`, `env destroy ENV` | Submit the action, report an already-reached state immediately, or report the accepted operation ID. Destroy requires confirmation in a terminal or an explicit `--yes`. The prompt names the environment and its ID. `--yes` is accepted with a UUID only: destroying by name always asks. |
| `op list ENV`, `op show OP_ID`, `op wait OP_ID` | Read history, including after destruction, inspect one operation, or wait for its terminal outcome. Surface the server's error code on failure. |
| `op logs OP_ID [--follow] [--cursor CURSOR]` | Read available log pages. Follow from the last cursor, including across empty pages. Report truncation. On a terminal operation, drain remaining output before exiting. |
| `secrets list`, `secrets set NAME=value …`, `secrets unset NAME …`, `secrets import FILE` | Manage secrets at one level, chosen with `--env ENV`, `--repo OWNER/NAME`, `--owner LOGIN` or `--user` (the default: the caller's own). `set` takes several pairs and sends them as one all-or-nothing request. `NAME=@file` reads a file and `NAME` alone asks without echo. `import` reads a dotenv file, or `-` for standard input. Values are never printed. `secret` is accepted as the same command. |
| `completion bash\|zsh\|fish` | Print a completion script for the shell. The script passes the words before the cursor to the CLI, which answers with commands, options and the names of the caller's environments, repositories and boxes. A lookup that fails offers nothing and prints nothing. With no candidates the shell completes file names. Works before login. The words go to the CLI on standard input and never as arguments, so a secret typed as `NAME=value` stays out of the process list when Tab is pressed. Completion only reads: it uses the saved access token as it is and never refreshes, because a refresh cut off mid-flight could spend the refresh token and lose the reply. Names are offered while that token is valid. A name a shell could read as syntax, or one shaped like a UUID, is not offered. |
| `update` | Check the official stable CLI release, install it if newer, and print the installed version. Works before login. An already-current installation exits successfully. |

`ENV` is an environment's name (its slug, as `env list` shows it) or its UUID. Resolve a name through all visible pages of the caller's environments. A UUID is used directly and needs no list permission. An operation has no name and is always given by UUID. A destroyed environment's history is read by UUID.

A name is not a stable identity. Once an environment is destroyed, a new one can take its name, so a command saved with a name can later act on a different environment. Scripts use UUIDs. For that reason a name never destroys unattended: `env destroy NAME` asks at a terminal, showing the ID it resolved, and refuses `--yes`, `--json` and a non-interactive shell with `confirmation_required`.

An explicit capacity confirmation flag passes the warning acknowledgement to the API for create or start. The CLI describes the warning before offering an interactive retry. A destroy confirmation applies only to destruction. A hard capacity limit is returned to the caller.

## Connections and permissions

The current CLI uses the public client ID `foreman-cli`. Retain issuer and endpoint-origin verification, outbound device polling, and HTTPS with the existing loopback development exception. Print the verification URL and code so login works over SSH. Only the human approving the request needs a browser.

Remember the instance and account after a successful login. Explicit `--instance` and `--account` take priority. For an explicit instance with multiple accounts and no selected account for that instance, list the choices and require a selection. Never borrow credentials from a different origin. Preserve working connections under `$XDG_STATE_HOME/foreman` (default `~/.local/state/foreman`), including account locks, atomic credential replacement, and pending revocations. An upgrade must allow the next refresh and logout to succeed using an existing personal connection.

A default login asks for every permission the CLI can use: discovery, reads, operations, logs, create, start, stop, destroy and secrets. Asking for less is the exception, done with `login --scope`. A secrets command refused for lack of permission says to log in again. Honor a narrower grant. For example, `env create REPO_UUID --no-wait` can submit with create permission alone. Report any missing read permission for a later wait as a separate error with the accepted IDs. Foreman authorizes every request.

## Long-running work and recovery

- The default for lifecycle commands is to wait, with `--no-wait` for submission only. Wait for the operation's terminal status. A successful create or start reports current workspace readiness separately when the grant allows it. An operation that succeeded yesterday and a workspace that is ready now are separate observations.
- Generate a fresh idempotency key for each intentional create. Persist the key, resolved request body and selected instance and identity in private local state before sending. Display the key on an uncertain outcome and support `env create --resume KEY` to replay that saved request after a process restart. Also accept `--request-key KEY` for a caller that persists its own inputs. Never silently create a replacement after an ambiguous response, conflict or destruction.
- On replay with expired operation history, report the original IDs and read the environment if permitted. On `original_environment_gone`, report that the original environment was destroyed. Retrying requires the same instance, client and acting identity.
- An interrupted or timed-out wait returns control to the shell and preserves the IDs for `op wait`. It leaves accepted server work running. A conflicting lifecycle action surfaces the API conflict. A lost response to start, stop or destroy calls for reading state and history before the caller decides to resubmit.

## Terminal and automation output

Human-readable output is the default for new commands. When standard output is a terminal, lists are aligned tables with the name first and the ID last, times are relative, and colour marks state unless `NO_COLOR` is set or `TERM` is `dumb`. An empty list says so. When standard output is a pipe or a file, lists keep their tab-separated lines with the original columns and values, so a script that reads them keeps working. `env list` at a terminal folds desired state, observed state and readiness into one status: the observed state, `running (not ready)` or `running (unconfirmed)` when readiness says so, and `stopped → running` when a settled environment is headed somewhere else. The separate fields stay in `env show`, the piped list and `--json`. With `--json`, ordinary commands emit one JSON document on stdout. List commands return a collection of items, following pagination by default. In follow mode, JSON log output uses one log-page object per line, preserving its cursor and truncation flag. Progress, prompts, warnings and errors go to stderr. Machine-readable failures include a stable code and message. A successful submission exits zero in no-wait mode. A failed or cancelled operation, wait timeout, authorization failure or invalid invocation exits nonzero. Scripts never need to parse a progress line or answer a prompt.

## Distribution and contract

The CLI will be written in Go and distributed as one executable per target. Developers can run it without installing Go. Verify the generated Go client against the live API, including form-encoded OAuth grants, idempotent create replay and paginated logs. Use a credential file written by the existing Python CLI in the upgrade test and verify that concurrent invocations can safely rotate the same grant.

Release targets are Linux and macOS, each on arm64 and x86-64. Install and upgrade the CLI independently of the Foreman server. Report the CLI version with `foreman --version`. Build against the versioned OpenAPI document in this repository. Use its operation definitions and types, and keep token handling, name resolution, output and polling in CLI code. Run acceptance tests against a real Foreman API instance. [Public API design](./public-api.md) · [OpenAPI contract](./public-api.openapi.yaml)

### Automated releases

Use Foreman’s existing `vX.Y.Z` release tag as the sole trigger. GitHub Actions builds the CLI from the tagged commit, embeds the tag version, and packages the `foreman` executable for each supported OS and architecture. CI unpacks each archive and runs `foreman --help` and `foreman --version` on its target, checking that the reported version matches the tag.

Once CI passes for the tagged commit and all four archives pass their smoke tests, the existing release job attaches the archives and a SHA-256 checksum manifest to the same GitHub Release. If a build or check fails, a maintainer can rerun the failed jobs against the same tag. The routine maintainer action is pushing the usual Foreman tag. CI handles version stamping, packaging, verification and upload. [Existing release workflow](../../.github/workflows/release.yml)

### Updates and notices

The installer, update check and `foreman update` use the newest published stable CLI release from the official Foreman GitHub Releases, compared by semantic version. Only complete CLI releases with a checksum manifest are eligible. Checks use no Foreman credentials. The updater verifies the archive, stages the executable beside the installer-managed binary and replaces it atomically. An interrupted download or checksum failure leaves the installed version usable. For a package-managed or unwritable installation, report how to update via its owner. Updating the executable preserves saved accounts and pending create requests.

On an ordinary interactive run, check for a newer release with a short timeout and an HTTP cache validator when available. On the first run that discovers it, write one line to stderr, for example `Foreman CLI 1.5.0 is available (installed 1.4.0). Run foreman update.` Record the version announced per local user so switching instances or opening another terminal does not repeat the notice. An explicit `foreman update` always checks immediately. The update command reports success itself. The first subsequent run stays quiet until a newer release is available.

Skip automatic checks and notices for scripts, redirected output and `--json`. An offline or rate-limited release service has no effect on the requested command's result. Only an explicit install or update command changes the executable.

## Sign-off and acceptance

The v1 CLI uses personal device connections. Team apps can use the service-account grant directly through the API. Users can connect with their SSH client using the details from `env show`. The API continues to own environment state, placement, authorization and expiry.

- Install a release artifact and run help and version on every supported OS and CPU. Exercise a headless login, restart the client, select the same account, and log out. Upgrade from the checkout CLI with an existing grant.
- As a non-admin with no existing grant, copy both commands from Connected apps and complete installation and device login from a clean shell. Publish a newer version in a release fixture, verify the first interactive invocation announces it once and JSON output stays clean, then run `foreman update` and verify the new version and the existing login. Repeat with a corrupt archive and confirm the previous executable still runs.
- Create using a repo name and a UUID. Exercise default placement, pinned placement, warnings, refusal, and stop or destroy at expiry. Exercise an account that may create but cannot list or inspect resources.
- Drop the first accepted create response and terminate the CLI. Resume with the saved key and observe one environment. Interrupt a wait, reconnect to logs, and distinguish remote operation failure from a local timeout.
- Verify pagination with a match on the second page, ambiguous names, grant restrictions, log truncation, and operation history after destroy. Pipe JSON output through a parser with stdout and stderr captured separately.
- Review the stack against this specification, exercise the published artifact format, and verify CI for each PR head.
