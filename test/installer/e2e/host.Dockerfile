# A stand-in for the personal host: Ubuntu with systemd and Docker
# Engine, but no Node, jq or git (the installer adds them), and a fake
# tailscale (fake-tailscale) whose `serve` is nginx with a test CA.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus ca-certificates curl gnupg nginx openssl iproute2 sudo \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-compose-plugin \
    && rm -f /etc/nginx/sites-enabled/default \
    && rm -rf /var/lib/apt/lists/*
# The tailnet name gets a certificate from a CA the host trusts, the way
# tailscale serve's Let's Encrypt one is trusted.
ARG FQDN=fm-e2e.example.ts.net
RUN mkdir -p /etc/fake-tailscale && cd /etc/fake-tailscale \
    && openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=fake tailscale CA" -keyout ca.key -out ca.crt \
    && openssl req -newkey rsa:2048 -nodes -subj "/CN=$FQDN" -keyout host.key -out host.csr \
    && printf 'subjectAltName=DNS:%s\n' "$FQDN" > ext.cnf \
    && openssl x509 -req -in host.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -extfile ext.cnf -out host.crt \
    && cp ca.crt /usr/local/share/ca-certificates/fake-tailscale.crt && update-ca-certificates
COPY fake-tailscale /usr/local/bin/tailscale
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
