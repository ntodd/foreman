# Upgrading, backups and rolling back

A release is one tag. It publishes control plane images that carry the
agents built with them (see [personal.md](personal.md#1-make-the-release-keys-and-the-first-release)).
Upgrading the control plane is a pull and a restart, and boxes then
update their agents to the ones the new image carries. With the updater
installed on its host, an admin does it from the Deployment page
([below](#from-the-deployment-page)).

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
again as a new one), and work that isn't pushed lives on each
environment's data disk, `/srv/foreman/vms/<env_id>/data.raw`. It's an
ext4 image: with the environment stopped, `sudo mount -o ro,loop` it
somewhere to look inside, and the clone is under
`srv/envs/<env_id>/workspace/`.

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
- With a deployment tag, the hourly tailnet sweep removes devices for
  environments the restored database doesn't know, unless it's turned
  off.
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

### From the Deployment page

The control plane checks GitHub for releases every five minutes
(`FOREMAN_UPDATE_CHECK=false` turns that off). When there's a newer
one, admins see it in the sidebar, and the Deployment page has an
**Update and restart** button once the host's updater is installed.

The control plane can't replace its own container, so a small script on
the host does it: `foreman-update`, run as root by a systemd path unit.
The button writes the version to `/var/lib/foreman-update/request/`,
which is mounted into the container, and the updater:

1. takes it only if it's `X.Y.Z` and newer than the running version, and
   pulls that version from the running image's repository (`-pg` for
   Postgres). A version is all the control plane can ask for.
2. stops the control plane and backs up the `foreman-data` volume to
   `/var/lib/foreman-update/backups/` (it keeps the last three).
3. pins the version in the `.env` beside `compose.yml` and starts it.
4. waits up to five minutes for `/healthz`. If the new version doesn't
   answer, it restores the backup and the previous version, so the
   database is as it was before the update.

The page follows along and reconnects once the new version is up.
Environments keep running, and boxes then update their agents as below.
Read the release notes first all the same; the updater doesn't hold a
box back on its agent (step 3 below).

Install the updater once, as root, from the image the control plane
runs, with the path to its `compose.yml`:

```sh
img=$(sudo docker inspect -f '{{.Config.Image}}' foreman)
sudo docker run --rm --entrypoint cat "$img" /app/updater/foreman-update |
  sudo sh -s -- install /opt/foreman/compose.yml
```

It needs `compose.yml` to mount the update directory, as
[`docker/compose.yml`](../../docker/compose.yml) now does. With an
older copy of the file, copy the new one over it (or add its two
`/var/lib/foreman-update` volumes) and recreate the container with
`sudo docker compose up -d`; the installer says so if they're missing.
Root's Docker login is what pulls the image, as with `docker compose
pull`.

After each update the updater replaces itself with the copy the new
image carries. On the host:

```sh
sudo foreman-update status                # the last run
sudo journalctl -u foreman-update         # what it did, and the new version's logs if it rolled back
ls /var/lib/foreman-update/backups/       # the volume backups
```

On Postgres there's no volume to back up: take a snapshot first, as for
an upgrade by hand. A failed update still goes back to the previous
version, but the database keeps whatever the new version's migrations
did.

To remove it: `sudo systemctl disable --now foreman-update.path`, then
delete `/usr/local/sbin/foreman-update`, the two
`/etc/systemd/system/foreman-update.*` units and
`/etc/foreman/update.conf`.

### By hand

1. Back up, as above.
2. Read the release notes. They say which protocol the release speaks
   and whether that changed, and list the migrations since the previous
   release.
3. To hold a box back on the agent it runs, pin it to that version on
   its page now. Boxes start updating as soon as the new control plane
   is up. Upgrading to 0.3.0 from an older release clears every pin, so
   for that one, stop the agent on the box first (`sudo systemctl stop
   foreman-agent`), pin it once the new control plane is up, then start
   the agent again. Running the install command on a pinned box installs
   the newest agent first, and the box then moves back to its pin.
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

Some releases change what the install script sets up on a box, which a
self-update can't do: the box firewall, for one, which keeps
environments off the box, each other and the tailnet as the box (see
[tailscale.md](tailscale.md#boxes-on-the-tailnet)); the VM helper; and
the unit that reboots a box from its page (a box without it says so in
its reboot alert, and offers no Reboot). A box whose agent reports no
firewall, or older rules than the agent ships with, gets an alert on
its page and its cards, and one whose VM helper is missing or too old
says it can't run environments. Run the install command on it again;
an enrolled box needs no token, but pass any `--block-lan`,
`--vm-subnet` or `--default-bridge-reaches-tailnet` it had:

```sh
curl -fsSL https://desktop.tail1234.ts.net/agent/install.sh | sudo sh
```

Upgrade the control plane before agents, which following does for you:
the control plane usually accepts agents on its protocol and the one
before, but an older control plane refuses newer agents. Protocol 6 is
the exception; see [Moving to environment VMs](#moving-to-environment-vms).

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

## Moving to environment VMs

The first release on protocol 6 runs every environment in a Cloud
Hypervisor VM of its own, with its own kernel and Docker, instead of on
the box's shared Docker ([architecture.md](../architecture.md#environment-vms)).
That changes what a box needs, and existing environments don't move
across, so this upgrade takes more than following the release:

- **Boxes** need amd64 Linux 6.2 or later with KVM (`/dev/kvm`; a box
  that is itself a VM needs nested virtualization) and Landlock
  (`landlock` in `/sys/kernel/security/lsm`, which confines each VM),
  systemd, nftables, iproute2, e2fsprogs and util-linux. They no longer need Docker or git. An arm64
  box still enrolls but can't run environments yet.
- **Mac boxes** are gone until
  [#180](https://github.com/ntodd/foreman/issues/180) ([mac.md](mac.md)).
- **Every box** needs the install script run on it again. The control
  plane refuses protocol 5 agents, which run environments on shared
  Docker, and a refused box can't update itself.
- **Environments** made before the upgrade can't start on the new agent.
  Push their work first; afterwards you make them again.
- **The compose policy** and `FOREMAN_POLICY` are gone. Privileged
  containers and docker-in-docker work
  ([repos.md](repos.md#what-an-environment-can-do)), and `--policy`
  does nothing any more.
- **No way back:** once boxes run protocol 6 agents, the control plane
  can't be rolled back past this release.

The steps:

1. **Check each box**: `uname -m` says `x86_64`, and `/dev/kvm` exists.
   A Flatcar box from `vm.sh` needs nested virtualization on the machine
   it runs on, and one on Proxmox the CPU type `host`
   ([flatcar.md](flatcar.md#on-a-linux-machine-as-a-vm)). A box without
   KVM enrolls after the upgrade but can't run environments, and its page
   says why.
2. **Push the work in every environment** while the old agents still run.
   Afterwards Foreman can't start them, or check them for unpushed work
   before a destroy. On a Mac box, destroy its environments too, then
   revoke the box and remove it (`~/.foreman-box/bin/foreman-box
   uninstall --yes`).
3. **Back up and upgrade the control plane**, as above. Every box then
   shows "Agent too old" on its card, and its page has the command to
   run on it.
4. **Put `/srv/foreman` on its own disk** if you want one (optional):
   ext4 is fine, and XFS saves space with reflinks at a cost to write
   speed ([personal.md](personal.md#disks-for-environments)). Now, with no
   environments on the box, is the easy time. Copy out anything you still
   need from the old clones in `/srv/foreman/envs` first: the new mount
   hides them.
5. **Run the install script on every box**, with `--block-lan` or
   `--vm-subnet` if you want them, and `--default-bridge-reaches-tailnet`
   if the box had it:

   ```sh
   curl -fsSL https://desktop.tail1234.ts.net/agent/install.sh | sudo sh
   ```

   It installs the new agent, the VM helper and the new firewall, takes
   the `foreman` user out of the `docker` group, turns IPv4 forwarding
   on from boot (`/etc/sysctl.d/90-foreman.conf`), and says whether
   `/srv/foreman` can reflink. If forwarding wasn't on already (Docker
   turns it on), the kernel turns LRO off on the box's network cards,
   and some drivers (atlantic, for one) reset the link to do that: the
   box may drop off the network for a moment, this once. The box then
   rejoins, and its page shows "VMs on KVM" or "VMs nested" (with
   "full-copy disks" when it can't reflink), or why it can't run
   environments.
6. **Make the environments again.** Starting an old one fails ("this
   environment has no VM on this box"). Destroy it in Foreman and create
   a new one rather than rebuilding it: the new one gets a fresh clone,
   its own VM and its own Tailscale node. Each new environment's first
   build pulls its images into its own VM, and the first on a box
   downloads the guest image.
7. **Clean up the old environments by hand.** Destroying one removes
   Foreman's record, its tailnet device and the box's copy of its
   secrets, but not its clone, which stays in
   `/srv/foreman/envs/<env_id>/`, or its containers and volumes, which
   stay in the box's Docker. Once nothing in them is needed:

   ```sh
   sudo docker ps -a --filter label=foreman.env_id    # the old environments' containers
   p=storefront-1                                      # an old environment's name, its compose project
   sudo docker rm -f $(sudo docker ps -aq --filter label=com.docker.compose.project=$p)
   sudo docker volume rm $(sudo docker volume ls -q --filter label=com.docker.compose.project=$p)
   sudo docker network rm $(sudo docker network ls -q --filter label=com.docker.compose.project=$p)
   sudo rm -rf /srv/foreman/envs                       # every old clone
   ```

   Their images and build cache are still in the box's Docker too. A box
   that doesn't use Docker for anything else can drop it altogether; a
   personal desktop still runs the control plane in it.

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
features, Pull and rebuild, the `gpu` policy rule, and agents reporting
the box firewall) with 0.4.0. Protocol 4 (registry credentials on start
and restart, so environments with private features can start without a
rebuild) came in with 0.4.10. A 0.4.10 control plane refuses agents on
protocol 2 (older than 0.4.0), and a refused box can't update from it, so
update those boxes to 0.4.0 or later before upgrading past 0.4.9.
Protocol 5 (rebooting a box from its page) came in with 0.5.0. A 0.5.0
control plane refuses agents on protocol 3 (older than 0.4.10) the same
way, so update those boxes to 0.4.10 or later before upgrading past
0.4.13. A box that was refused anyway comes back when you run the
install command on it again. Protocol 6 (environment VMs) refuses every
older agent, protocol 5 included, and a control plane from before it
refuses protocol 6 agents, so neither side can go back past it; see
[Moving to environment VMs](#moving-to-environment-vms).

Following starts with 0.3.0, and 0.3.0 is the first release with
images, so rolling back from it means building the older version
yourself. A control plane older than 0.3.0 doesn't move boxes back:
they stay on the agent they run, which works as long as it speaks the
same protocol, and they only move when you set a version on their page.

## Changing the encryption key

The control plane won't start if `FOREMAN_ENCRYPTION_KEY` can't decrypt
what's in the database, and the log says so. That's usually a copy that
lost a character or a settings file that was generated again, so put the
original key back.

To change the key on purpose (because it leaked, say):

1. Back up, as above. That backup needs the old key, so keep the two
   together.
2. In `/etc/foreman/foreman.env`, set `FOREMAN_ENCRYPTION_KEY` to a new
   key (`openssl rand -base64 32`) and move the old one to
   `FOREMAN_ENCRYPTION_KEYS_RETIRED` (comma-separated, if there's more
   than one).
3. Recreate the container so it reads the file again:
   `sudo docker compose up -d --force-recreate`. It now encrypts with
   the new key and reads with either.
4. Re-encrypt everything with the new key. It's safe while the control
   plane runs, and prints how many rows of each table it rewrote:

   ```sh
   sudo docker exec foreman env -u PHX_SERVER /app/bin/foreman eval 'Foreman.Release.reencrypt()'
   ```

5. Take `FOREMAN_ENCRYPTION_KEYS_RETIRED` out of the settings file and
   recreate the container again.

Don't drop the old key before step 4 has finished. Anything still
encrypted with it can't be read without it.

## Rebooting boxes

A box whose updates asked for a reboot (a new kernel, libc, systemd)
shows **Reboot required** on its card and its page, with the packages
that asked, and everyone who can see the box gets a notice when it
starts needing one. The agent reads `/run/reboot-required`, the flag
Debian's packages use for this. Ubuntu writes it for the usual
suspects; on Debian it depends on the package, so a Debian box may not
flag every update that needs a reboot. With a kernel livepatch enabled,
the page says so, but the reboot stays required: a livepatch doesn't
show which fixes are in. Depending on its version and settings, a
Livepatch client that has confirmed coverage may clear the flag itself.

Reboot the box when its environments can stop for a few minutes:

```sh
sudo reboot
```

Environments come back up once the agent rejoins, and the alert clears.

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

### Boxes with a loopback `FOREMAN_URL`

An agent downloads a new release from the control plane at its own
`FOREMAN_URL`, the same address it connects to, not the control
plane's public URL. That matters on a box that reaches the control
plane some other way, like `http://127.0.0.1:4000` on the control
plane's own host when something else (Traefik, say) holds port 443
there.

Agents before 0.4.9 downloaded from the public URL, so on such a box
the update fails (often with `TLS client alert: Bad Certificate`) and
rolls back. Reinstall it once by hand with the same `--url` it was
installed with (and any `--block-lan`, `--vm-subnet` or
`--default-bridge-reaches-tailnet` it had); an enrolled box needs no
token:

```sh
curl -fsSL http://127.0.0.1:4000/agent/install.sh | sudo sh -s -- --url http://127.0.0.1:4000
```

From 0.4.9 on, its updates come from the Deployment page like any
other box's.
