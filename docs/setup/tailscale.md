# Tailscale

Every environment joins the tailnet as its own node, named after the
environment (`storefront-2`), with Tailscale SSH on. Nothing publishes ports:
you reach `storefront-2:4000` and `ssh vscode@storefront-2` over the tailnet.

## The OAuth client

Foreman mints a single-use, pre-authorized auth key for each new
environment, and deletes devices when environments are destroyed. It
does both with an OAuth client:

1. In the admin console: **Settings → OAuth clients → Generate**.
2. Scopes: **Auth Keys: write** and **Devices Core: write**.
3. Tags: `tag:foreman-env`, plus any repo tags you'll use (storefront uses
   `tag:staging-access`) and, on a team deployment, one
   `tag:foreman-<login>` per developer.
4. Set `FOREMAN_TAILSCALE_CLIENT_ID` and `FOREMAN_TAILSCALE_CLIENT_SECRET`.

Keys are tagged, so the devices they create don't expire. A node's
identity lives in a volume, so the key is only used on the first boot
and rebuilds keep the same node.

## ACLs

Each environment is a full tailnet node, and anything running in it (an
npm postinstall script, say) can use the network. The policy below lets
people reach environments, and lets environments reach nothing they
aren't granted.

```jsonc
{
  "tagOwners": {
    "tag:foreman-env": ["autogroup:admin"],
    "tag:staging-access": ["autogroup:admin"],
    // Team deployments: one per developer.
    "tag:foreman-ntodd": ["autogroup:admin"]
  },

  "grants": [
    // Personal: you reach every environment.
    {"src": ["autogroup:member"], "dst": ["tag:foreman-env"], "ip": ["*"]},

    // Team: each developer reaches their own (replace the rule above).
    // {"src": ["alice@example.com"], "dst": ["tag:foreman-ntodd"], "ip": ["*"]},

    // What a repo tag grants environments, e.g. a staging database.
    {"src": ["tag:staging-access"], "dst": ["tag:staging"], "ip": ["*"]}
  ],

  "ssh": [
    {
      // accept, not check: editors and SSH tools shouldn't be sent to re-authenticate.
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:foreman-env"],
      "users": ["autogroup:nonroot"]
    }
  ]
}
```

With no grant whose `src` is `tag:foreman-env`, environments can't open
connections to your laptops or to each other.

## Notes

- **HTTPS:** a plain-HTTP tailnet name isn't a secure context, so secure
  cookies, WebAuthn, the clipboard API and service workers won't work.
  A repo that needs them runs `tailscale serve` (in a lifecycle command)
  to get `https://storefront-2.tail1234.ts.net`. Those names land in public
  certificate transparency logs; keep them bland.
- **DNS:** the feature accepts MagicDNS by default, which forwards other
  names to Docker's resolver, so compose service names keep working.
- **No TUN device:** the feature falls back to userspace networking,
  with a SOCKS5 and HTTP proxy on `localhost:1055`.
- **Cleanup:** an hourly job removes `tag:foreman-env` devices that
  don't belong to a live environment. Tagged devices count against the
  plan.
- **Without Tailscale configured,** environments still build and run;
  the feature skips Tailscale, and you connect with `docker exec` on the
  box.
