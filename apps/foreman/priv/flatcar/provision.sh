#!/bin/sh
# Turns a new Flatcar machine into a Foreman box. Runs from
# foreman-provision.service, which the box's first-boot config (Ignition,
# made by the control plane) installs: joins the tailnet with the key the
# control plane minted for this box, waits until the control plane
# answers, and runs its install script, which installs the agent and
# enrolls the box. Then it deletes the join token and the key, which also
# keeps it from running again. A failure is retried by the unit.
set -eu

env=/etc/foreman-box/provision.env
key=/etc/foreman-box/tailscale-authkey

# Progress goes to every console the kernel has (/dev/console is only the
# last of them: a VGA screen nobody watches, under QEMU), where the
# launchers and a person at the machine see it, and to the journal.
console() {
  echo "$*"
  while read -r c _; do
    if [ -w "/dev/$c" ]; then echo "$*" > "/dev/$c" 2>/dev/null || true; fi
  done < /proc/consoles
}
say() { console "foreman-box: $*"; }

# FOREMAN_URL, FOREMAN_JOIN_TOKEN and FOREMAN_BOX_NAME.
# shellcheck disable=SC1090
. "$env"

if [ -s "$key" ]; then
  say "joining the tailnet as $FOREMAN_BOX_NAME"
  # tailscaled comes from a system extension and may still be starting.
  i=0
  until tailscale up --auth-key="file:$key" --hostname="$FOREMAN_BOX_NAME" --timeout=2m; do
    i=$((i + 1))
    [ $i -lt 10 ] || { say "couldn't join the tailnet"; exit 1; }
    sleep 3
  done
  rm -f "$key"
fi

say "waiting for $FOREMAN_URL"
i=0
until curl -fsS -o /dev/null --max-time 10 "$FOREMAN_URL/healthz"; do
  i=$((i + 1))
  [ $i -lt 60 ] || { say "the control plane at $FOREMAN_URL doesn't answer"; exit 1; }
  sleep 5
done

say "installing the agent"
script=$(mktemp)
status=$(mktemp)
trap 'rm -f "$script" "$status"' EXIT
curl -fsSL --retry 5 -o "$script" "$FOREMAN_URL/agent/install.sh"
{
  sh "$script" --token "$FOREMAN_JOIN_TOKEN" 2>&1
  echo $? > "$status"
} | while IFS= read -r line; do console "$line"; done
[ "$(cat "$status")" = 0 ] || { say "the install script failed"; exit 1; }

# Spent: the token, and the config that carried it and the key (on bare
# metal and on a Mac it stays in the OEM partition).
rm -f "$env" /oem/config.ign
say "enrolled; this box shows as online in Foreman"
