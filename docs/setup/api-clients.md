# Connect to the public API

## Generated clients

Generate your SDK from the [OpenAPI contract](../design/public-api.openapi.yaml). Set its base URL to the Foreman instance origin, for example `https://foreman.example.org`. The generated methods include the paths for OAuth and versioned API resources.

Personal clients send a client ID and device code to exchange an approved grant, then a client ID and refresh token to renew it. Team apps use HTTP Basic for the client credentials exchange. Both use the returned bearer token for environment requests. Generate an idempotency key before creating an environment and reuse it when retrying the same request.

## Personal CLI connection

Open **You → Connected apps → Install the CLI** on your Foreman instance. Run the install command on the Linux or macOS machine where you want to use Foreman. If the installer prints a command to add `~/.local/bin` to your `PATH`, run it in that shell. Then copy the login command from the same page. For example:

```sh
foreman --instance https://foreman.example.org login
foreman me
foreman repo list
```

Open the verification URL on a device with a browser, sign in, compare the code with the one printed in the terminal, and review the app name, client ID and permissions. The code expires in ten minutes. The built-in client ID is `foreman-cli`. Other apps get an ID when an administrator registers them under **Admin → API clients**.

A login asks for every permission the CLI can use, including destroying environments and managing secrets. To connect with fewer, name them: `foreman login --scope "repos:list environments:list environments:read"`.

The CLI validates the discovery issuer against the selected HTTPS origin. Local development supports loopback HTTP. It saves each connection under `$XDG_STATE_HOME/foreman` (default `~/.local/state/foreman`) in an owner-only file. For multiple accounts on an instance, supply `--account UUID` before the command. The login output includes the account UUID and granted permissions.

Access tokens last 15 minutes. Each successful refresh returns a replacement refresh token and starts a fresh 90-day inactivity period. The CLI locks the account file during refresh and saves the replacement atomically. If the server receives the refresh but the response is lost, follow the printed login command to reauthorize the affected account. Replaying the previous refresh token can revoke the grant. Logout revokes the selected connection server-side. **You → Connected apps** also lets you revoke a connection from the browser.

When you replace a connection with another login, the CLI saves and syncs the new credentials before revoking the old grant. If revocation is delayed, use the printed `me` command. It selects the exact instance and account and retries the pending revocation. If saving and revoking the new grant both fail, the CLI directs you to **Connected apps** for manual recovery.

## Environments with the installed CLI

After device login, run these commands from any directory.

```sh
foreman repo list
foreman box list
foreman env create acme/payments --branch topic --timeout 15m
foreman env list
foreman env show payments-you-1
foreman op list payments-you-1
foreman op logs "$OP_ID" --follow
```

Commands that act on an environment take its name, as `env list` shows it, or its UUID. An operation is always given by UUID.

At a terminal, lists are aligned tables: the name first, one status per environment, relative times and the ID last. Piped or redirected, they stay tab-separated with their original columns. Use `--json` in scripts.

For tab completion of commands, options and the names of your environments, repositories and boxes, install the script for your shell. `foreman help completion` lists where each one goes:

```sh
foreman completion zsh > ~/.zfunc/_foreman
```

`env create` accepts a repository UUID or an exact owner/name. Omit `--branch` to use the repository default. Omit `--box` for automatic placement, or supply a box UUID or exact name. With a create-only grant, use UUIDs and add `--no-wait`. To request expiry, supply both `--expires-at` with an absolute RFC 3339 timestamp and `--on-expiry stop` or `--on-expiry destroy`.

Create, start, stop and destroy print the accepted IDs and then wait up to 30 minutes by default. `--timeout` sets the wait budget after acceptance. Use `--no-wait` for submission alone. Waiting requires `operations:read`. After an interruption or a permission change, use `foreman op wait "$OP_ID"` to check the outcome. `op show` prints the operation and exits nonzero if it failed or was cancelled. `foreman env show "$ENV_ID"` reads current readiness. In a script, use `--confirm-capacity-warning` on create or start to acknowledge a capacity warning, and `--yes` on destroy to confirm disk removal.

Before sending a create request, the CLI saves its key and resolved inputs in the private `create-requests` directory under the Foreman state root and prints the key to stderr. Each instance, account and client has its own keys. If the process dies or its response is lost, select the original connection and run `foreman env create --resume "$KEY"` to replay the saved body. If stderr is unavailable, the saved JSON record contains `request_key`, the instance, account, client and request body.

Scripts can supply `--request-key "$KEY"` for each intentional create. If every attempt received a definitive validation or capacity rejection, supply corrected inputs with the same key. After a capacity warning, `foreman env create --resume "$KEY" --confirm-capacity-warning` acknowledges it. An uncertain attempt permanently binds that key to its saved body. Older journal records without a rejection history also replay their original inputs. For an uncertain start, stop or destroy, inspect the environment and its operation history before resubmitting.

Use `--json` for automation. Lists return an object with an `items` array. Diagnostics go to stderr. On failure the final JSON diagnostic includes `code`, `message` and any known recovery IDs. An ambiguous submission uses `outcome_unknown`. If replaying an uncertain create returns a validation or capacity rejection, the diagnostic keeps `outcome_unknown` and the original `request_key`. When available, `http_status` and `remote_code` preserve the HTTP status and the server's error code.

A single `op logs` read returns up to 16 whole pages and 1 MiB of text. In JSON mode it emits one object containing `text`, `next_cursor` and `truncated`. Continue with `foreman op logs "$OP_ID" --cursor "$CURSOR"` until an empty read returns the same cursor you supplied. The server sets `truncated` when earlier output has been discarded. The CLI preserves this flag on partial reads, including an empty page that advanced the cursor before a later request failed.

Use `--follow` for a continuous log stream. JSON follow mode writes one page per line, including empty pages. To reconnect, run `foreman op logs "$OP_ID" --follow --cursor "$CURSOR"` using the last delivered cursor.

## Secrets with the installed CLI

`foreman login` asks for the secret permissions along with the rest. A connection narrowed with `--scope`, or made by a CLI older than 0.8.2, has to log in again first.

Set, list and remove secrets at one level:

```sh
foreman secrets set LOG_LEVEL=debug API_KEY=@key.txt --env "$ENV_ID"
foreman secrets set DATABASE_PASSWORD            # asks, without showing what you type
op read op://vault/item/token | foreman secrets set API_TOKEN=-
foreman secrets import team.env --repo acme/payments
foreman secrets list --repo acme/payments
foreman secrets unset OLD_TOKEN --repo acme/payments
foreman env restart "$ENV_ID"                    # recreate the services that use what changed
```

With no level named, the secrets are your own and reach all of your environments. `--env` takes an environment ID. `--repo` takes an exact owner/name or a repository UUID, and `--owner` a login; both of those need an admin. An environment gets the owner's secrets, then the repository's, then your own, then its own, and a later level wins.

One `set`, `unset` or `import` is one request: everything in it is saved, or nothing is. A request takes up to 100 changes. `list` shows names and when each last changed. No command prints a value.

A value written as `NAME=value` stays in your shell history and is visible to other processes while the command runs. For anything sensitive use `NAME=@file`, which reads the file and drops its final newline, `NAME=-`, which reads standard input the same way, or `NAME` alone, which asks on the terminal. A value that itself begins with `@` has to come one of those three ways. Empty values and values that aren't UTF-8 text are refused. The CLI's messages never repeat what you typed, in case a value landed where a name or an option belonged. `import` reads `NAME=value` lines from a dotenv file, or from standard input when the file is `-`. It skips blank lines and `#` comments, accepts a leading `export`, keeps single-quoted values as written, and reads `\n`, `\r`, `\t`, `\"` and `\\` inside double quotes, leaving any other backslash as it is. In an unquoted value a `#` after a space starts a comment.

In a running environment new shells pick a change up once the box has written it, usually within seconds. Processes and services that were already running keep the values they started with. After a change the command lists your running environments that the level reaches, if your login includes `environments:list`.

`foreman env restart "$ENV_ID"` applies a change, as **Restart affected** does in the browser. It recreates the services whose compose configuration uses a secret that changed and restarts the workspace container, whether or not anything changed. `foreman env restart "$ENV_ID" --all` stops and starts every container without recreating any, which is what a process that read `/run/foreman/secrets.env` at startup needs. A stop and a start does no more than `--all`: the services come back in the containers they already had, with the environment those were created with.

Two limits to know. The default restart finds its services by the `$NAME` and `${NAME}` references in the compose files, so a service that receives a secret another way, such as a bare `NAME` in an `environment:` list, is not recreated. And once `--all` or a stop and start has run, Foreman counts the current values as applied and stops listing the environment as waiting, even though a container it did not recreate still has its old values. When in doubt, rebuild the environment from the browser.

## Update or disconnect

Run `foreman update` to install the latest stable CLI release. An interactive command announces a newly available version once. Updating preserves your login, including personal connections saved by the checkout CLI. Run `foreman logout` to disconnect the selected account.

## TLS termination

Tailscale Serve on the same host can forward HTTPS to Foreman's loopback listener. The Docker image also trusts the bridge gateway for installations using the documented loopback-only published port. For an external TLS terminator, set `FOREMAN_TLS_PROXIES` to its peer address and configure it to replace incoming `X-Forwarded-Proto` with the actual connection scheme. If migrating an existing reverse proxy, set this variable before upgrading. `FOREMAN_TRUSTED_PROXIES` controls client-address forwarding for rate limits and logs separately.

## Team installations

Under **Admin → API clients**, enter a service name and select the granted actions, repositories, boxes and workload secrets. The secret picker lists owner and repository secrets. Each installation gets a dedicated tailnet tag. Add any other approved tags and use the displayed tags when configuring tailnet access.

Save the installation client ID and the one-time client secret in the app backend. To obtain a 15-minute bearer, authenticate the client ID and secret using HTTP Basic at the discovered token endpoint and send an `application/x-www-form-urlencoded` body with `grant_type=client_credentials`. The optional space-separated `scope` requests a subset of the installation permissions. This exchange issues access tokens only. Clients can inspect their acting identity with `GET /api/v1/me`.

Rotate a secret from the installation's entry on the same admin page. Rotation invalidates the previous secret and outstanding access tokens. Disabling an installation also revokes its grant and keeps its service ID, resource selections and tailnet tags visible for follow-up. Disabling its installer leaves the service active.

## Offboarding workloads and SSH

Disabling a user or service stops new workload commands and credential renewals. Running environments stay up. A GitHub credential already copied into a guest keeps its original expiry. Administrators can still stop or destroy environments, and scheduled expiry continues.

Foreman guests use Tailscale SSH. Revoking a Tailscale SSH rule can close established sessions, so Foreman records outstanding SSH removal under **Admin → People**. For a service, **Admin → API clients** also links to the pending removal. Review the identity, groups, service tags and SSH rules with your tailnet administrator. Coordinate changes with active session owners, verify that the offboarded identity cannot start a new connection and confirm administrator access. Select **Acknowledge removal** after verification. [Tailscale SSH user revocation](https://tailscale.com/docs/features/tailscale-ssh#user-revocation)
