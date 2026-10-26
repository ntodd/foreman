# Pairing clients from the environment page

Some tools run a server inside the environment that a client on your
laptop or phone pairs with: Orca's runtime, say. A devcontainer feature
can put that pairing on the environment's page as a **connect hook**,
so you get a pairing code (or a QR code for a phone) from Foreman
instead of running commands over SSH.

Foreman doesn't assume any tool. The buttons only show up when a
feature in the environment installed a hook, and only to the
environment's owner.

## Pairing Orca

The Orca feature (`ghcr.io/ntodd/devcontainer-features/orca`, 1.1.0 or
later) installs a hook.

1. Add the feature to your environments, either in the repo's
   `devcontainer.json` or for yourself under **Settings → Devcontainer
   features**:

   ```json
   {
     "ghcr.io/ntodd/devcontainer-features/orca:1": {}
   }
   ```

2. Rebuild the environment. Foreman looks for hooks every time an
   environment comes up (create, rebuild, start, restart all), so a
   rebuild that installs the feature also finds its hook.
3. On the environment's page, the **Connect** panel shows **Orca** with
   **Pair a desktop** and **Pair a phone**.
4. Pick one and confirm. To make an offer, Orca restarts in pairing
   mode, which stops the agents running in it. Clients that are already
   paired reconnect on their own.
5. Within a minute or so the dialog shows the pairing code with a copy
   button.
   - **Desktop:** in Orca, add a remote environment and paste the code.
     From a terminal, `orca environment add --name <name> --pairing-code '<code>'`
     does the same.
   - **Phone:** scan the QR code with the Orca app.
6. Close the dialog. Once a client has used the code, Orca restarts
   supervised (it restarts itself if it crashes), which the feature does
   for you.

The code works like a password for the environment's Orca runtime. It
appears only in the dialog of the person who asked for it. It isn't
saved with the operation, written to the operation's log, or shown to
admins, and it's gone once the dialog closes. Ask for a new one any
time; Orca hands out the same code again until one is used, so
unused codes don't pile up.

The buttons are only active while the environment is running and its
box is online. If the dialog reports an error, the operation's entry
under **Activity** has the same message.

## Writing a connect hook

A hook is an executable in the devcontainer at
`/usr/local/share/foreman/connect.d/<name>`, where `<name>` is lowercase
letters, digits and dashes, up to 32 characters. A feature's
`install.sh` typically puts it there:

```sh
mkdir -p /usr/local/share/foreman/connect.d
install -m 0755 "$here/foreman-connect.sh" /usr/local/share/foreman/connect.d/mytool
```

Nothing outside Foreman reads that directory, so the feature works the
same elsewhere.

The agent runs hooks as the devcontainer's remote user, in the
workspace folder, under `timeout`. The container needs a `timeout`
command (coreutils and busybox both have one); without it, no hook
runs, because stopping `docker exec` doesn't stop what it started. Their
output is read as one stream (stdout and stderr together), and **the
last non-empty line must be a JSON object**. Anything printed before it
is ignored.

### `describe`

Run whenever the environment comes up, with a 30-second limit. It
lists what the hook offers:

```json
{"label":"Orca","actions":[{"id":"desktop","label":"Pair a desktop","confirm":"Orca restarts to make a pairing offer, which stops its running agents."}]}
```

- `label`: what the page shows for the hook, up to 60 characters
- `actions`: one to four, each with an `id` (same rules as the hook's
  name), a `label` (up to 60 characters) and an optional `confirm`
  (up to 300), which the page asks before running it

A hook whose `describe` fails or prints something that doesn't fit is
left off the page, and the up's log says why. An environment shows at
most eight hooks.

### `run <action>`

Run when someone clicks the action, with a 4-minute limit. Foreman
gives up on one that hasn't answered in 10 minutes. It prints the
result:

```json
{"value":"orca://pair?code=…","qr":false,"note":"In Orca, add a remote environment and paste this pairing code."}
```

- `value`: what to show and copy, up to 2048 bytes, one line
- `qr`: `true` to also show `value` as a QR code (default `false`)
- `note`: one line of instructions, up to 300 characters

Text fields can't contain control characters.

If the action fails, exit non-zero and make the last line
`{"error": "..."}` (up to 300 characters): that's the error the dialog
and the operation show. It's stored with the operation and anyone who
can see the environment's activity can read it, so keep secrets out of
it. Nothing else a run prints is shown or kept,
since it could hold the secret, so a failure without that line, or a
run that exits 0 without a result, reads "connect hook <name> failed".
