# Mac boxes

A Mac can be a box: it runs one as a Flatcar Container Linux VM on
Apple's hypervisor, through [vfkit](https://github.com/crc-org/vfkit),
started at login. The box is a [Flatcar box](flatcar.md) like any other:
it sets itself up on its first boot, updates its OS itself, and waits
for a reboot from its page in Foreman.

It's quick. Builds in the VM run as fast as in Docker Desktop's best
case (a named volume) and its disk is faster, and against a workspace
bind-mounted from macOS, which is what most Docker Desktop setups have,
it's several times faster (see
[flatcar.md](flatcar.md#performance)).

## What it needs

- macOS 13 or newer, on Apple silicon (Intel Macs work too, with the
  amd64 image)
- To be run from a logged-in session (Terminal on the Mac, not over SSH):
  launchd starts the VM in your session, and it runs while you're logged
  in.
- No admin rights, Homebrew or Docker Desktop.

## Adding it

**Boxes → Add a box → Mac** gives the command. Run it in Terminal on the
Mac:

```sh
curl -fsSL https://desktop.tail1234.ts.net/agent/mac.sh | sh -s -- --token fj_...
```

It downloads vfkit (Red Hat's signed release, checked against a pinned
digest) and Flatcar (checked against the digests from Flatcar's signed
release files), writes the box's disk, stages the box's first-boot
config, and starts the box with a launchd agent. Then it prints the box's
progress until it has enrolled, which takes a minute or two.

| Option | Default | |
|---|---|---|
| `--cpus N` | half the Mac's cores | virtual CPUs |
| `--memory GiB` | half the Mac's memory, at most 16 | |
| `--disk GiB` | 100 | the disk's size; the file only takes what the box uses |

Everything lives in `~/.foreman-box`. The VM sees none of the Mac's
files, and reaches the network through the Mac (vmnet's NAT), so a box
on a Mac that's on the tailnet could reach the control plane even
without a key of its own; with one, it's a tailnet node of its own (see
[flatcar.md](flatcar.md#the-box-on-the-tailnet)).

Running the command again updates the launcher and vfkit and keeps the
box, its disk and its enrollment; it needs no token. `--cpus` and
`--memory` then change the box's size from its next start.

## Managing it

`~/.foreman-box/bin/foreman-box` manages the box:

| Command | |
|---|---|
| `foreman-box status` | size, disk use, whether it's running, its address |
| `foreman-box stop`, `start`, `restart` | stop shuts the box down cleanly and keeps it from starting at login until `start` |
| `foreman-box ssh` | a shell on the box as `core` |
| `foreman-box logs` | the box's console |
| `foreman-box uninstall --yes` | stops the box and deletes it, disk and all; revoke it in Foreman too |

## Sleep

While the Mac sleeps, so does the box: it's offline in Foreman, and its
environments can't be reached. On wake the box's clock has fallen behind
by however long the Mac slept, and the control plane refuses an agent
whose clock is off by more than a minute. The box puts its clock right
from the Mac's within ten seconds of waking (a timer that only runs on
Apple's hypervisor), and the agent rejoins.

A box that has to stay up belongs on a Mac that doesn't sleep (a Mac
mini, say, with sleep turned off in System Settings → Energy) or on a
Linux machine.

## Reboots

Apple's hypervisor can't reboot a VM: when the box reboots (from its
page in Foreman, or for an update), vfkit exits and launchd starts it
again a few seconds later. The box's console from before the reboot is
kept in `~/.foreman-box/box/serial.log.1`.
