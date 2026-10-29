#!/bin/sh
# Updates the Compose and Tailscale system extensions from Flatcar's
# sysext bakery (systemd-sysupdate, the configs in /etc/sysupdate.*.d).
# A new one takes effect on the next boot, so it's flagged the way a
# package flags a reboot on Debian, which the agent reports and Foreman
# shows on the box's page.
set -u

for ext in docker-compose tailscale; do
  before=$(readlink -f "/etc/extensions/$ext.raw")
  /usr/lib/systemd/systemd-sysupdate -C "$ext" update || continue
  after=$(readlink -f "/etc/extensions/$ext.raw")
  if [ "$before" != "$after" ]; then
    name=$(basename "$after" .raw)
    grep -qxF "$name" /run/reboot-required.pkgs 2>/dev/null || echo "$name" >> /run/reboot-required.pkgs
    [ -e /run/reboot-required ] || echo "*** System restart required ***" > /run/reboot-required
  fi
done
