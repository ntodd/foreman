# The guest system image: the kernel and root filesystem every
# environment's VM boots. Each environment gets its own copy of the root
# disk; its data (Docker's, the clone's, the guest agent's) lives on a
# disk of its own, and the agent comes from the box on a third, so this
# image changes only when what's below Docker does.
#
#   guest/build.sh out/      # out/foreman-guest-linux-amd64.tar
#
# The tarball holds vmlinuz, root.raw.zst (a sparse ext4 image, mostly
# empty space) and manifest.json. Agents are built with its URL and
# SHA-256 (see docs/design/vm-environments.md).
ARG UBUNTU_IMAGE=ubuntu:24.04@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8
ARG TOOLS_IMAGE=debian:trixie-20261005-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f

FROM ${UBUNTU_IMAGE} AS rootfs
ARG DEBIAN_FRONTEND=noninteractive
# systemd and udev to boot; Docker, Compose and buildx for the
# environment; git for the clone; socat joins vsock to the guest agent;
# e2fsprogs supplies ext4 tools. Noble's HWE virtual kernel boots
# directly without an initrd and ships zram in its base modules.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    systemd-sysv udev kmod dbus iproute2 iptables ca-certificates curl git socat e2fsprogs \
    util-linux docker.io docker-compose-v2 docker-buildx linux-image-virtual-hwe-24.04 \
  && rm -rf /var/lib/apt/lists/* /var/cache/apt/*
# The agent maps the remote user to this account when it brings a
# devcontainer up. It does that itself (ForemanAgent.Devcontainer, its
# own implementation of the devcontainer CLI's `up`), so there's no CLI
# or Node in this image. UID 1000 is the usual developer UID. Ubuntu's
# unused image user occupies it.
RUN userdel --remove ubuntu \
  && groupadd --gid 1000 foreman \
  && useradd --uid 1000 --gid foreman --groups docker --no-create-home \
       --home-dir /var/lib/foreman-agent --shell /usr/sbin/nologin foreman
# Older data disks need both of their original IDs available at boot.
RUN ! getent passwd 997 >/dev/null && ! getent group 993 >/dev/null
COPY rootfs/ /
RUN systemctl enable foreman-guest-net foreman-guest-disks foreman-guest-agent foreman-guest-vsock.socket \
    foreman-guest-reclaim.socket foreman-guest-zram.service docker fstrim.timer \
  && systemctl mask getty.target console-getty.service serial-getty@ttyS0.service systemd-resolved.service \
    systemd-timesyncd.service systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service \
    systemd-firstboot.service e2scrub_all.timer apt-daily.timer apt-daily-upgrade.timer motd-news.timer \
    dpkg-db-backup.timer \
  # A machine id of its own for each environment, made on its first boot.
  && : > /etc/machine-id \
  && mkdir -p /out \
  && cp "$(ls /boot/vmlinuz-* | sort -V | tail -n 1)" /out/vmlinuz \
  && basename "$(ls -d /lib/modules/* | sort -V | tail -n 1)" > /out/kernel \
  && modprobe --set-version "$(cat /out/kernel)" --show-depends zram > /dev/null \
  && rm -f /boot/initrd.img* /boot/vmlinuz* /boot/System.map* \
  && docker --version > /out/docker && docker compose version --short > /out/compose

FROM ${TOOLS_IMAGE} AS image
RUN apt-get update \
  && apt-get install -y --no-install-recommends e2fsprogs zstd \
  && rm -rf /var/lib/apt/lists/*
COPY --from=rootfs / /rootfs
RUN mv /rootfs/out /out \
  && truncate -s 4G /out/root.raw \
  && mkfs.ext4 -q -F -L fm-root -E root_owner=0:0 -d /rootfs /out/root.raw \
  && zstd -q -T0 -19 --sparse --rm /out/root.raw -o /out/root.raw.zst \
  && printf '{"format":1,"arch":"amd64","kernel":"%s","docker":"%s","compose":"%s"}\n' \
    "$(cat /out/kernel)" "$(cut -d, -f1 /out/docker | sed 's/Docker version //')" "$(cat /out/compose)" \
    > /out/manifest.json \
  && tar -C /out -cf /foreman-guest-linux-amd64.tar manifest.json vmlinuz root.raw.zst

FROM scratch AS artifact
COPY --from=image /foreman-guest-linux-amd64.tar /
