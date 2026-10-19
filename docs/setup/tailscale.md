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
   `tag:staging-access`), on a team deployment one
   `tag:foreman-<login>` per developer, and the deployment's own tag if
   it shares the tailnet with another ([below](#a-tag-per-deployment)).
5. Copy the client ID and secret; the secret is only shown once. Put
   them in the control plane's env file, without quotes (the file is
   read as written, so quotes would be part of the value):

   ```sh
   FOREMAN_TAILSCALE_CLIENT_ID=...
   FOREMAN_TAILSCALE_CLIENT_SECRET=...
   ```

6. Recreate the container with `sudo docker compose -f
   docker/compose.yml up -d --force-recreate`. `docker restart` doesn't
   reread the env file; only a new container does.

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
sudo tailscale up --advertise-tags=tag:foreman
```

`tailscale up` wants every setting you'd changed from the default
repeated; if you leave one out, it prints the full command to run
instead.

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
  https://<host>.<tailnet>.ts.net/healthz` should print `200`. If it
  does, serve and the certificate are fine and the problem is the client
  side.

## Notes

- **HTTPS:** a plain-HTTP tailnet name isn't a secure context, so secure
  cookies, WebAuthn, the clipboard API and service workers won't work.
  A repo that needs them runs `tailscale serve` (in a lifecycle command)
  to get `https://storefront-2.tail1234.ts.net`. Those names land in public
  certificate transparency logs; keep them bland.
- **Userspace networking:** Tailscale runs without a TUN device or
  `NET_ADMIN`, and doesn't change the container's routes, firewall or
  DNS (compose service names resolve as usual). Everything you connect
  into works normally: Tailscale SSH, an environment's ports, `tailscale
  serve`. Connections an environment makes out to other tailnet machines
  go through the proxy on `127.0.0.2:1055`; a repo that needs that sets
  `ALL_PROXY=socks5h://127.0.0.2:1055` (or
  `HTTP_PROXY=http://127.0.0.2:1055`) on its devcontainer service.
- **Localhost is on the tailnet:** Tailscale delivers tailnet
  connections to `127.0.0.1`, so a server bound only to localhost in an
  environment (a dev server, a debugger port) is reachable by anyone the
  ACL lets reach the environment, and sees them as 127.0.0.1. Keep
  `tag:foreman-env` reachable only by the people who own those
  environments.
- **Cleanup:** the agent reports the node each environment joined as,
  and destroying the environment deletes that device and no other. An
  hourly job retries deletes that failed. Every delete needs
  `tag:foreman-env` and the environment's hostname, so laptops or CI
  machines sharing a repo tag are safe. Tagged devices count against
  the plan.
- **Another deployment on the same tailnet** (a test box beside your
  main one, say) can have environments with the same names, so Foreman
  never deletes a device just because its name matches. Devices it has
  no record of (environments from before the agent reported nodes, or a
  create that joined and then failed) stay until you delete them in the
  admin console, unless you give each deployment its own tag; see
  below.

### A tag per deployment

Set `FOREMAN_TAILSCALE_DEPLOYMENT_TAG` to a tag only this deployment
uses, for example `tag:foreman-dev`, and every environment it creates
carries it. Foreman then also removes devices it has no record of, but
only ones with that tag that don't belong to a live environment, and it
never deletes or renames a device without the tag. That matters
because the node ID comes from inside the repo's container: without a
deployment tag, a repo could report the ID of another deployment's
environment with the same name and have it deleted when its own is
destroyed. Add
the tag to `tagOwners` and to the OAuth client's tags first: an auth key
with a tag the client doesn't own fails every create. Environments made
before you set it don't have the tag until they're recreated.
- **Without Tailscale configured,** environments still build and run;
  the feature skips Tailscale, and you connect with `docker exec` on the
  box.
