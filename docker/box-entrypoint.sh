#!/bin/sh
# Starts dockerd, prepares the tmpfs secrets directory, then runs the
# agent as the foreman user and restarts it whenever it exits, the way
# the systemd unit does (self-update exits after switching `current`).
set -eu

dockerd >/var/log/dockerd.log 2>&1 &
i=0
until docker info >/dev/null 2>&1; do
  i=$((i + 1))
  [ $i -lt 60 ] || { echo "dockerd didn't start"; cat /var/log/dockerd.log; exit 1; }
  sleep 1
done

# /run is a tmpfs in the container too, so secrets vanish on restart,
# like a reboot.
install -d -m 0711 -o foreman -g foreman /run/foreman
install -d -m 0700 -o foreman -g foreman /run/foreman/envs

# The agent's settings come from the container environment.
(umask 077 && env | grep -E '^(FOREMAN_|HOME=|LANG=|LC_ALL=)' > /run/foreman-agent.env)
chgrp foreman /run/foreman-agent.env && chmod 0640 /run/foreman-agent.env

while true; do
  su -s /bin/sh foreman -c 'set -a; . /run/foreman-agent.env; set +a; export PATH=/usr/local/bin:/usr/bin:/bin; exec /opt/foreman-agent/current/bin/foreman_agent start' || true
  echo "box: agent exited; restarting in 2s"
  sleep 2
done
