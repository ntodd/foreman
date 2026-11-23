# Connect to the public API

## Generated clients

Generate your SDK from the [OpenAPI contract](../design/public-api.openapi.yaml). Set its base URL to the Foreman instance origin, for example `https://foreman.example.org`. The generated methods include the paths for OAuth and versioned API resources.

Personal clients send a client ID and device code to exchange an approved grant, then a client ID and refresh token to renew it. Team apps use HTTP Basic for the client credentials exchange. Both use the returned bearer token for environment requests. Generate an idempotency key before creating an environment and reuse it when retrying the same request.

## Personal CLI connection

From the Foreman checkout on a Unix system with Python 3, run:

```sh
bin/foreman --instance https://foreman.example.org login --scope 'repos:list environments:read'
bin/foreman --instance https://foreman.example.org me
bin/foreman --instance https://foreman.example.org logout
```

Open the verification URL on a device with a browser, sign in, compare the code with the one printed in the terminal, and review the app name, client ID and permissions. The code expires in ten minutes. The built-in client ID is `foreman-cli`. Other apps get an ID when an administrator registers them under **Admin → API clients**.

The CLI validates the discovery issuer against the selected HTTPS origin. Local development supports loopback HTTP. It saves each connection under `$XDG_STATE_HOME/foreman` (default `~/.local/state/foreman`) in an owner-only file. For multiple accounts on an instance, supply `--account UUID` before the command. The login output includes the account UUID and granted permissions.

Access tokens last 15 minutes. Each successful refresh returns a replacement refresh token and starts a fresh 90-day inactivity period. The CLI locks each account file during refresh and replaces it atomically. If a refresh succeeds on the server but its response is lost, reuse of the old refresh token revokes the connection. Run `login` again to approve a new one. Logout revokes the connection server-side. **You → Connected apps** also lets you revoke a connection from the browser.

When you replace a connection with another login, the CLI saves and syncs the new credentials before revoking the old grant. If the old grant cannot be revoked immediately, the CLI records it in the private account file and retries on the next `me`, `login` or `logout`. If saving and revoking the new grant both fail, the CLI directs you to **Connected apps** for manual recovery.

## Environments with the installed CLI

After device login, run these commands from any directory.

```sh
foreman repo list
foreman box list
foreman env create acme/payments --branch topic --timeout 15m
foreman env show "$ENV_ID"
foreman op list "$ENV_ID"
foreman op logs "$OP_ID" --follow
```

`env create` accepts a repository UUID or an exact owner/name. Omit `--branch` to use the repository default. Omit `--box` for automatic placement, or supply a box UUID or exact name. With a create-only grant, use UUIDs and add `--no-wait`. To request expiry, supply both `--expires-at` with an absolute RFC 3339 timestamp and `--on-expiry stop` or `--on-expiry destroy`.

Create, start, stop and destroy print the accepted IDs and wait up to 30 minutes by default. Use `--no-wait` for submission alone. After an interruption, use `foreman op wait "$OP_ID"` to check the outcome. `foreman env show "$ENV_ID"` reads current readiness. In a script, use `--confirm-capacity-warning` on create or start to acknowledge a capacity warning, and `--yes` on destroy to confirm disk removal.

Before sending a create request, the CLI prints its key to stderr and saves the key and resolved inputs in the private `create-requests` directory under the Foreman state root. If the process dies or its response is lost, use the same instance and account and run `foreman env create --resume "$KEY"`. If stderr is unavailable, the saved JSON record contains `request_key`, the instance, account, and request body. Scripts that keep their own inputs can supply `--request-key "$KEY"` on the original request and on retries. If a start, stop or destroy response is lost, inspect the environment and its operation history before resubmitting.

Use `--json` for automation. Lists return an object with an `items` array. A follow-mode log stream writes one page per line, including its `next_cursor` and `truncated` flag. Reconnect with `foreman op logs "$OP_ID" --follow --cursor "$CURSOR"`. Diagnostics go to stderr. On a failed command the final JSON diagnostic includes `code`, `message`, and any known recovery IDs.

## TLS termination

Tailscale Serve on the same host can forward HTTPS to Foreman's loopback listener. The Docker image also trusts the bridge gateway for installations using the documented loopback-only published port. For an external TLS terminator, set `FOREMAN_TLS_PROXIES` to its peer address and configure it to replace incoming `X-Forwarded-Proto` with the actual connection scheme. If migrating an existing reverse proxy, set this variable before upgrading. `FOREMAN_TRUSTED_PROXIES` controls client-address forwarding for rate limits and logs separately.

## Team installations

Under **Admin → API clients**, enter a service name and select the granted actions, repositories, boxes and workload secrets. The secret picker lists owner and repository secrets. Each installation gets a dedicated tailnet tag. Add any other approved tags and use the displayed tags when configuring tailnet access.

Save the installation client ID and the one-time client secret in the app backend. To obtain a 15-minute bearer, authenticate the client ID and secret using HTTP Basic at the discovered token endpoint and send an `application/x-www-form-urlencoded` body with `grant_type=client_credentials`. The optional space-separated `scope` requests a subset of the installation permissions. This exchange issues access tokens only. Clients can inspect their acting identity with `GET /api/v1/me`.

Rotate a secret from the installation's entry on the same admin page. Rotation invalidates the previous secret and outstanding access tokens. Disabling an installation also revokes its grant and keeps its service ID, resource selections and tailnet tags visible for follow-up. Disabling its installer leaves the service active.

## Offboarding workloads and SSH

Disabling a user or service stops new workload commands and credential renewals. Running environments stay up. A GitHub credential already copied into a guest keeps its original expiry. Administrators can still stop or destroy environments, and scheduled expiry continues.

Foreman guests use Tailscale SSH. Revoking a Tailscale SSH rule can close established sessions, so Foreman records outstanding SSH removal under **Admin → People**. For a service, **Admin → API clients** also links to the pending removal. Review the identity, groups, service tags and SSH rules with your tailnet administrator. Coordinate changes with active session owners, verify that the offboarded identity cannot start a new connection and confirm administrator access. Select **Acknowledge removal** after verification. [Tailscale SSH user revocation](https://tailscale.com/docs/features/tailscale-ssh#user-revocation)
