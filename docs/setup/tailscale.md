# Tailscale

Every environment joins the tailnet as its own node, named after the
environment (`storefront-2`), with Tailscale SSH on. Nothing publishes ports:
you reach `storefront-2:4000` and `ssh vscode@storefront-2` over the tailnet.

## The OAuth client

Foreman mints a single-use, pre-authorized auth key for each new
environment, and deletes devices when environments are destroyed. It
does both with an OAuth client:

1. Add the tags to `tagOwners` in the policy file first (see
   [ACLs](#acls)). The console only offers tags that already exist.
2. In the admin console: **Trust credentials → Credential → OAuth**.
   (Older consoles had this under Settings → OAuth clients.)
3. Scopes: **Keys → Auth Keys: write** and **Devices → Core: write**.
4. Tags: `tag:foreman-env`, plus any repo tags you'll use (for example
   `tag:staging-access`) and, on a team deployment, one
   `tag:foreman-<login>` per developer.
5. Copy the client ID and secret; the secret is only shown once. Put
   them in the control plane's env file, without quotes (`--env-file`
   keeps quotes as part of the value):

   ```sh
   FOREMAN_TAILSCALE_CLIENT_ID=...
   FOREMAN_TAILSCALE_CLIENT_SECRET=...
   ```

6. Recreate the container. `docker restart` doesn't reread
   `--env-file`; only a new container does.

To check the client works, ask the API for the tailnet's devices from
inside the container:

```sh
docker exec foreman /app/bin/foreman eval '
  Application.ensure_all_started(:req)
  IO.inspect(Foreman.Tailscale.Client.impl().list_devices(Foreman.Tailscale.creds()))'
```

Environments created before the client was set up aren't on the
tailnet. Rebuild them to join.

Keys are tagged, so the devices they create don't expire. A node's
identity lives in a volume, so the key is only used on the first boot
and rebuilds keep the same node.

## The control plane host

`tailscale serve` puts the web UI on `https://<host>.<tailnet>.ts.net`,
but that only helps machines the policy lets reach it. With the default
allow-all policy that's everyone; with a custom one, tag the host and
grant it explicitly, so access doesn't hang on who owns the machine:

```jsonc
"tagOwners": {"tag:foreman": ["autogroup:admin"]},
"grants": [
  {"src": ["autogroup:member"], "dst": ["tag:foreman"], "ip": ["443"]}
]
```

Then tag it, from the host (an admin owns the tag, so this needs no
console visit) or under **Machines → ⋯ → Edit ACL tags**:

```sh
sudo tailscale set --advertise-tags=tag:foreman
```

A tagged machine no longer belongs to your user, so rules built on
`autogroup:self` stop covering it. If you SSH to the host over
Tailscale, grant that too before tagging it. The agent on the same host
reaches the control plane through its own address and needs no rule.

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
    "tag:foreman-alice": ["autogroup:admin"]
  },

  "grants": [
    // Personal: you reach every environment.
    {"src": ["autogroup:member"], "dst": ["tag:foreman-env"], "ip": ["*"]},

    // Team: each developer reaches their own (replace the rule above).
    // {"src": ["alice@example.com"], "dst": ["tag:foreman-alice"], "ip": ["*"]},

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

### Only some of your machines

To keep Foreman and its environments visible only to tagged development
machines (say `tag:dev`), use that tag as the `src` everywhere instead of
`autogroup:member`:

```jsonc
"grants": [
  {"src": ["tag:dev"], "dst": ["tag:foreman"],     "ip": ["443"]},
  {"src": ["tag:dev"], "dst": ["tag:foreman-env"], "ip": ["*"]}
],
"ssh": [
  {"action": "accept", "src": ["tag:dev"], "dst": ["tag:foreman-env"],
   "users": ["autogroup:nonroot"]}
]
```

Check nothing broader also matches, such as a grant with `"dst": ["*"]`;
grants only add access, so one like that lets everyone back in.

## When the host can't be reached

- **"Server Not Found" (no DNS answer) on a tailnet machine:** the policy
  doesn't let that machine reach the host. Peers a node can't reach are
  left out of its netmap, so their names don't resolve at all; it looks
  like DNS, not a blocked port. Add a grant as above. A host whose
  `tailscale status` lists far fewer peers than you have machines is
  the giveaway.
- **Only a few, long-offline peers:** the host may have joined a
  different tailnet. `tailscale switch --list` shows which one;
  `sudo tailscale login` adds the right one. Then update `PHX_HOST` and
  recreate the container.
- **DNS over HTTPS in the browser** (Firefox's is on in some regions)
  bypasses MagicDNS. Turn it off, or add `ts.net` as an exception.
- From the host, `curl -sS -o /dev/null -w '%{http_code}\n'
  https://<host>.<tailnet>.ts.net/setup` should print `200`. If it does,
  serve and the certificate are fine and the problem is the client side.

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
