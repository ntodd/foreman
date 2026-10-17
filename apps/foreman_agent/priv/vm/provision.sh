#!/bin/sh
# Runs as root inside the VM that becomes the environment image (see
# build-image.sh). Installs what ForemanAgent.Guest needs to run an
# environment: Docker Engine with Compose and Buildx, git, Node and the
# devcontainer CLI, and a `foreman` user (uid 1990) in the docker group.
set -eu
DEVCONTAINER_CLI_VERSION=${DEVCONTAINER_CLI_VERSION:-0.89.0}
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg git util-linux >/dev/null

install -m 0755 -d /etc/apt/keyrings
. /etc/os-release
curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
apt-get install -y -qq --no-install-recommends docker-ce docker-ce-cli containerd.io \
  docker-compose-plugin docker-buildx-plugin nodejs >/dev/null

id foreman >/dev/null 2>&1 || useradd --system --uid 1990 --user-group \
  --home-dir /var/lib/foreman-agent --shell /usr/sbin/nologin foreman
usermod -aG docker foreman
install -d -m 0700 -o foreman -g foreman /var/lib/foreman-agent /var/lib/foreman-agent/ops /var/lib/foreman-agent/tmp
install -d -m 0755 -o foreman -g foreman /srv/foreman /srv/foreman/envs /opt/foreman-agent /opt/foreman-agent/releases
cat > /etc/tmpfiles.d/foreman.conf <<TMP
d /run/foreman 0711 foreman foreman -
d /run/foreman/envs 0700 foreman foreman -
TMP
systemd-tmpfiles --create /etc/tmpfiles.d/foreman.conf
npm install --prefix /opt/foreman-agent/node --no-fund --no-audit --silent "@devcontainers/cli@$DEVCONTAINER_CLI_VERSION"
chown -R foreman:foreman /opt/foreman-agent

# A faster, quieter boot: nothing here needs snaps, and nothing should
# upgrade packages under a running environment.
apt-get purge -y -qq snapd unattended-upgrades >/dev/null 2>&1 || true
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer man-db.timer >/dev/null 2>&1 || true
apt-get clean
rm -rf /var/lib/apt/lists/*
# cloud-init has done its one job (installing the incus agent); later boots
# don't need it.
touch /etc/cloud/cloud-init.disabled
fstrim -av >/dev/null 2>&1 || true
echo "foreman: image ready"
