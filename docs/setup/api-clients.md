# Connect to the public API

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

## TLS termination

Tailscale Serve on the same host can forward HTTPS to Foreman's loopback listener. The Docker image also trusts the bridge gateway for installations using the documented loopback-only published port. For an external TLS terminator, set `FOREMAN_TLS_PROXIES` to its peer address and configure it to replace incoming `X-Forwarded-Proto` with the actual connection scheme. If migrating an existing reverse proxy, set this variable before upgrading. `FOREMAN_TRUSTED_PROXIES` controls client-address forwarding for rate limits and logs separately.

## Team installations

Under **Admin → API clients**, enter a service name and select the granted actions, repositories, boxes and workload secrets. The secret picker lists owner and repository secrets. Each installation gets a dedicated tailnet tag. Add any other approved tags and use the displayed tags when configuring tailnet access.

Save the installation client ID and the one-time client secret in the app backend. To obtain a 15-minute bearer, authenticate the client ID and secret using HTTP Basic at the discovered token endpoint and send an `application/x-www-form-urlencoded` body with `grant_type=client_credentials`. The optional space-separated `scope` requests a subset of the installation permissions. This exchange issues access tokens only. Clients can inspect their acting identity with `GET /api/v1/me`.

Rotate a secret from the installation's entry on the same admin page. Rotation invalidates the previous secret and outstanding access tokens. Disabling an installation also revokes its grant and keeps its service ID, resource selections and tailnet tags visible for follow-up. Disabling its installer leaves the service active.
