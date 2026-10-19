# Upgrading, backups and rolling back

A release is one tag. It publishes control plane images that carry the
agents built with them (see [personal.md](personal.md#1-make-the-release-keys-and-the-first-release)).
Upgrading the control plane is a pull and a restart, and boxes then
update their agents to the ones the new image carries.

## What to keep

| | Where | Without it |
|---|---|---|
| `FOREMAN_ENCRYPTION_KEY` | `/etc/foreman/foreman.env`; keep a copy off the host | Every secret, token and key in the database is unreadable |
| The release signing key | The `FOREMAN_RELEASE_PRIVATE_KEY` secret, and a copy off GitHub | New agents can't be signed; every box needs reinstalling with a new key |
| The database | SQLite: `foreman.db` in the `foreman-data` volume. Postgres: your provider's snapshots or point-in-time restore | Everything |
| Agent releases | `releases/` in the `foreman-data` volume | Boxes can't install or update until they're registered again (an image registers its own on boot; `scripts/publish-agent-release.sh` does older ones) |
| `SECRET_KEY_BASE`, the Tailscale OAuth secret | `/etc/foreman/foreman.env` | Sessions end; environments can't join the tailnet until it's replaced |

Foreman doesn't back up boxes. A box's identity is
`/var/lib/foreman-agent/identity.json` (lose it and the box enrolls
again as a new one), and work that isn't pushed lives in
`/srv/foreman/envs/*/workspace`.

## Backing up SQLite

The database runs in WAL mode, so copying `foreman.db` while it's in
use can miss recent writes. Stop the control plane, copy the volume and
start it again; environments keep running, and boxes reconnect within
about 30 seconds of it coming back:

```sh
cd docker   # wherever compose.yml is
sudo docker compose stop
sudo docker run --rm -v foreman-data:/data:ro -v "$PWD":/backup debian:trixie-slim \
  tar czf "/backup/foreman-data-$(date +%F).tgz" -C /data .
sudo docker compose start
```

Restoring an older database isn't neutral. When boxes reconnect, the
control plane makes them match it:

- Environments it thinks are running but are missing are created again,
  ones it thinks are stopped are stopped, and environments made since
  the backup show up as orphans on their box's page.
- The hourly tailnet sweep removes devices for environments the
  restored database doesn't know, unless it's turned off.
- A box revoked since the backup has its key back and can reconnect, so
  revoke it again. A box enrolled since the backup is refused until it's
  enrolled again with `--reenroll` and a new token.
- GitHub refresh tokens are single use, so anyone who signed in since
  the backup has to sign in again.

So turn the sweep off before the control plane starts, then restore:

```sh
printf '\nFOREMAN_TAILNET_SWEEP=false\n' | sudo tee -a /etc/foreman/foreman.env >/dev/null
sudo docker compose stop
sudo docker run --rm -v foreman-data:/data -v "$PWD":/backup debian:trixie-slim \
  sh -c 'find /data -mindepth 1 -delete && tar xzf /backup/foreman-data-2026-10-17.tgz -C /data'
sudo docker compose up -d --force-recreate
```

`up -d --force-recreate` rather than `start`, because only a new
container reads the settings file again. Once the orphans and boxes are
sorted out, take the line out of the settings file and recreate the
container again.

With Postgres, take a snapshot (Neon: a branch; RDS: a manual snapshot)
before an upgrade, and restore from it the provider's way.

## Upgrading the control plane

1. Back up, as above.
2. Read the release notes. They say which protocol the release speaks
   and whether that changed, and list the migrations since the previous
   release.
3. To hold a box back on the agent it runs, pin it to that version on
   its page now. Boxes start updating as soon as the new control plane
   is up. Upgrading to 0.3.0 from an older release clears every pin, so
   for that one, stop the agent on the box first (`sudo systemctl stop
   foreman-agent`), pin it once the new control plane is up, then start
   the agent again.
4. Point `FOREMAN_IMAGE` at the new version (in the `.env` beside
   `compose.yml`), then pull and recreate:

   ```sh
   sudo docker compose pull
   sudo docker compose up -d
   ```

5. Migrations run on boot, then the image registers the agents it
   carries. `sudo docker compose ps` shows it healthy once `/healthz`
   answers, and the Deployment page shows the running version. If the
   log says a bundled agent "wasn't registered" (usually the release key
   in the settings file), boxes stay on the agent they run until that's
   fixed.

Boxes that aren't pinned to a version then get the new agent within a
minute or so. A box waits while its environments have operations
running, and its agent restarts only once it's idle; environments keep
running throughout. The box page shows the version a box is updating
to.

Upgrade the control plane before agents, which following does for you:
the control plane accepts agents on its protocol and the one before,
but an older control plane refuses newer agents.

### Coming from `docker run`

Control planes set up before 0.3.0 ran under `docker run --name
foreman`, which compose can't take over. Remove that container (the
`foreman-data` volume stays), then start it with compose as in
[personal.md](personal.md#2-run-the-control-plane):

```sh
sudo docker stop foreman && sudo docker rm foreman
echo "FOREMAN_IMAGE=ghcr.io/<owner>/foreman:0.3.0" > docker/.env   # :0.3.0-pg for Postgres
sudo docker compose -f docker/compose.yml up -d
```

Use the `-pg` image if the control plane runs on Postgres. The SQLite
one refuses to start when `DATABASE_URL` is set.

Compose warns that `foreman-data` already exists but wasn't created by
compose, and uses it; that's expected. The upgrade unpins every box, so
they all follow the new control plane's agent from then on.

## Rolling back

Point `FOREMAN_IMAGE` at the previous version and run `up -d` again.
Migrations don't run backwards, so check the release notes of the
version you're leaving. So far every migration has added tables or
columns, which older code ignores, or changed data in a way older code
reads the same; one that doesn't means restoring the backup you took
before upgrading.

Boxes that follow the control plane follow it back to the older image's
agent, and new boxes install that one too. The protocol sets a floor,
though: once boxes run agents on a newer protocol, a control plane older
than that protocol refuses them when they connect, and they can't be
moved back from there. The release notes say when the protocol changes;
protocol 2 came in with 0.2.1, and protocol 3 (your own devcontainer
features, and Pull and rebuild) with the release after 0.3.0.

Following starts with 0.3.0, and 0.3.0 is the first release with
images, so rolling back from it means building the older version
yourself. A control plane older than 0.3.0 doesn't move boxes back:
they stay on the agent they run, which works as long as it speaks the
same protocol, and they only move when you set a version on their page.

## When an agent update fails

An update counts as failed when the box doesn't come back on the new
version within ten minutes of it being sent, or 70 minutes after the
agent said it would restart once idle. After two failures in a row the
version isn't sent to that box again, and the box's page says so; fix
what stopped it, then **Retry**.

On the box:

```sh
journalctl -u foreman-agent -n 200          # why the new release didn't come up
systemctl status foreman-agent foreman-agent-rollback
ls -l /opt/foreman-agent                    # current, and previous during an update
```

If the new release keeps crashing, systemd switches back to `previous`.
If the box is offline and the rollback unit says there was no previous
release to roll back to, switch back by hand:

```sh
ls /opt/foreman-agent/releases
sudo ln -sfn releases/<version that worked> /opt/foreman-agent/current
sudo systemctl reset-failed foreman-agent && sudo systemctl start foreman-agent
```

Then pin the box to that version until the new one is fixed.
