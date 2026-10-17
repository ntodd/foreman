#!/bin/sh
# Runs as root inside the VM that becomes the environment image (see
# build-image.sh). Installs what ForemanAgent.Guest needs to run an
# environment: Docker Engine with Compose and Buildx, git, Node and the
# devcontainer CLI, and a `foreman` user (uid 1990) in the docker group.
set -eu
DEVCONTAINER_CLI_VERSION=${DEVCONTAINER_CLI_VERSION:-0.89.0}
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg git util-linux cloud-guest-utils >/dev/null

install -m 0755 -d /etc/apt/keyrings
# shellcheck source=/dev/null
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

# cloud-init grew the root filesystem on the first boot only. Each VM
# made from this image has a bigger disk than this one, so it grows its
# own on every boot (a no-op once it fills the disk).
cat > /usr/local/sbin/foreman-growroot <<'GROW'
#!/bin/sh
dev=$(findmnt -no SOURCE /)
disk=/dev/$(lsblk -no PKNAME "$dev")
part=$(cat "/sys/class/block/$(basename "$dev")/partition")
growpart "$disk" "$part" >/dev/null 2>&1 || true
resize2fs "$dev" >/dev/null 2>&1 || true
GROW
chmod 0755 /usr/local/sbin/foreman-growroot
cat > /etc/systemd/system/foreman-growroot.service <<'UNIT'
[Unit]
Description=Grow the root filesystem to the VM's disk
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/foreman-growroot

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable foreman-growroot.service >/dev/null 2>&1

# DHCP by MAC: every VM made from this image would otherwise send the same
# client id (it comes from the machine id) and get the same address.
rm -f /etc/netplan/50-cloud-init.yaml
cat > /etc/netplan/50-foreman.yaml <<'NET'
network:
  version: 2
  ethernets:
    nics:
      match: {name: "en*"}
      dhcp4: true
      dhcp-identifier: mac
NET
chmod 0600 /etc/netplan/50-foreman.yaml

# Nothing logs in over SSH; incus exec goes through the Incus agent.
systemctl disable ssh.service ssh.socket >/dev/null 2>&1 || true

# A faster, quieter boot: nothing here needs snaps, and nothing should
# upgrade packages under a running environment.
apt-get purge -y -qq snapd unattended-upgrades >/dev/null 2>&1 || true
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer man-db.timer >/dev/null 2>&1 || true
apt-get clean
rm -rf /var/lib/apt/lists/*
# cloud-init has done its one job (installing the incus agent); later boots
# don't need it.
touch /etc/cloud/cloud-init.disabled
# Each VM generates its own machine id on first boot (from its SMBIOS UUID).
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
fstrim -av >/dev/null 2>&1 || true
echo "foreman: image ready"
