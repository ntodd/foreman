#!/bin/sh
# Runs scripts/install-control-plane.sh end to end on a throwaway host: a
# privileged Ubuntu container with systemd and its own Docker, a fake
# tailscale (see fake-tailscale) and a control plane image you have
# locally. Port 4000 is taken by another container and 443 is already
# served with Funnel on, as on the host this installer was written for.
#
#   test/installer/e2e/run.sh [IMAGE]     # default foreman-smoke:0.3.0
#
# Two hosts. On the first, a new install, then a no-op re-run, an
# upgrade and a refused downgrade. On the second, taking over a manual
# install in /opt/foreman that publishes 127.0.0.1:4100 and is served on
# 8443, then one run from a checkout's docker/ dir (no /opt/foreman/.env)
# on a newer image than the installer's.
#
# Not part of CI: it needs network access for apt, NodeSource and npm.
# KEEP=1 leaves the host container running for poking at. Each run gets
# its own host container, volumes and log directory, so runs can
# overlap; FOREMAN_E2E_NAME names the container (default
# fm-installer-e2e-PID).
set -eu

image=${1:-foreman-smoke:0.3.0}
host=${FOREMAN_E2E_NAME:-fm-installer-e2e-$$}
work=$(mktemp -d "${TMPDIR:-/tmp}/fm-installer-e2e.XXXXXX")
fqdn=fm-e2e.example.ts.net
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)

say() { echo "== $*"; }
fail() { echo "FAILED: $* (last installer run: $work/last-run.log)" >&2; exit 1; }
on_host() { docker exec "$host" "$@"; }
check() { # DESCRIPTION COMMAND (run on the host)
  if on_host sh -c "$2" >/dev/null 2>&1; then echo "ok: $1"; else fail "$1 ($2)"; fi
}

cleanup() {
  if [ -z "${KEEP:-}" ]; then
    docker rm -f "$host" >/dev/null 2>&1 || true
    docker volume rm "$host-docker" "$host-containerd" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

docker image inspect "$image" >/dev/null 2>&1 || fail "no image $image; build one with docker/control-plane.Dockerfile"
# The release key the image's agents were signed against, from the
# bundled agent's compiled config.
key=$(docker run --rm --entrypoint sh "$image" -c \
  't=$(ls /app/lib/foreman-*/priv/agent/releases/foreman_agent-*.tar.gz | head -1); tar -xzOf "$t" --wildcards "releases/*/sys.config"' |
  tr ',' '\n' | sed -n 's/.*<<"\([A-Za-z0-9+/=]*\)">>.*/\1/p' | head -n 1)
[ -n "$key" ] || fail "couldn't read the release key from $image's agents"

say "building the host image"
docker build -q -t foreman-installer-host:e2e -f "$here/host.Dockerfile" --build-arg FQDN="$fqdn" "$here" >/dev/null

# A new host with 443 served (Funnel on) and port 4000 taken.
fresh_host() {
  say "starting a fresh host"
  cleanup
  docker run -d --name "$host" --privileged --hostname fm-e2e \
    --add-host "$fqdn:127.0.0.1" --tmpfs /run --tmpfs /run/lock \
    -v "$host-docker:/var/lib/docker" -v "$host-containerd:/var/lib/containerd" \
    foreman-installer-host:e2e >/dev/null
  i=0
  until on_host docker info >/dev/null 2>&1; do
    i=$((i + 1)); [ $i -lt 60 ] || fail "Docker didn't start on the host"; sleep 1
  done
  on_host sh -c "mkdir -p /var/lib/fake-tailscale && echo $fqdn > /var/lib/fake-tailscale/fqdn && echo '[\"tag:foreman\"]' > /var/lib/fake-tailscale/tags.json"
  docker exec -i "$host" sh -c "cat > /var/lib/fake-tailscale/serve.json" <<JSON
{"TCP": {"443": {"HTTPS": true}},
 "Web": {"$fqdn:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:4444"}}}},
 "AllowFunnel": {"$fqdn:443": true}}
JSON
  docker save "$image" busybox:latest | docker exec -i "$host" docker load -q >/dev/null
  on_host docker run -d --name squatter -p 4000:80 busybox:latest httpd -f -p 80 >/dev/null
  docker cp "$root/scripts/install-control-plane.sh" "$host:/root/install-control-plane.sh"
}

secrets() { on_host sh -c 'grep -E "^(SECRET_KEY_BASE|FOREMAN_ENCRYPTION_KEY)=" /etc/foreman/foreman.env'; }

# Like `curl ... | sudo bash` with no terminal: answers from the environment.
install() {
  docker exec -i \
    -e FOREMAN_IMAGE="$image" \
    -e FOREMAN_AGENT_RELEASE_PUBLIC_KEY="$key" \
    -e FOREMAN_ADMINS="${ADMINS-octocat}" \
    -e FOREMAN_INSTALL_PACKAGES=yes -e FOREMAN_INSTALL_NODE=yes \
    "$@" "$host" bash -c 'cat /root/install-control-plane.sh | bash' 2>&1 | tee "$work/last-run.log"
}

fresh_host
say "run 1: control plane only"
install -e FOREMAN_GITHUB_APP=manifest -e FOREMAN_BOX=skip -e FOREMAN_TAILSCALE=skip
token=$(on_host sh -c 'docker logs foreman 2>&1 | grep -A1 "setup token" | tail -n 1 | tr -d " "')
grep -q "one-time setup token: $token\$" "$work/last-run.log" || fail "run 1 didn't print the current setup token ($token)"
echo "ok: the current setup token is printed"
grep -q "Open https://$fqdn:8443/setup" "$work/last-run.log" || fail "run 1 didn't print the setup URL"
check "the free port 4001 is pinned" "grep -qx FOREMAN_PORT=4001 /opt/foreman/.env"
check "the image is pinned" "grep -qx FOREMAN_IMAGE=$image /opt/foreman/.env"
check "foreman.env is root 0600 in a 0700 dir" "[ \"\$(stat -c '%a %U' /etc/foreman/foreman.env)\" = '600 root' ] && [ \"\$(stat -c %a /etc/foreman)\" = 700 ]"
check "the base URL carries 8443" "grep -qx FOREMAN_BASE_URL=https://$fqdn:8443 /etc/foreman/foreman.env"
check "so does the extra origin" "grep -qx FOREMAN_EXTRA_ORIGINS=https://$fqdn:8443 /etc/foreman/foreman.env"
check "443 still serves the other service, Funnel on" "jq -e '.Web[\"$fqdn:443\"].Handlers[\"/\"].Proxy == \"http://127.0.0.1:4444\" and .AllowFunnel[\"$fqdn:443\"] == true' /var/lib/fake-tailscale/serve.json"
check "8443 serves Foreman, no Funnel" "jq -e '.Web[\"$fqdn:8443\"].Handlers[\"/\"].Proxy == \"http://127.0.0.1:4001\" and (.AllowFunnel[\"$fqdn:8443\"] // false) == false' /var/lib/fake-tailscale/serve.json"
check "funnel was never run" "! grep -q 'tailscale funnel' /var/lib/fake-tailscale/calls.log"
check "healthz answers through serve" "curl -fsS https://$fqdn:8443/healthz"
check "setup is still needed" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4001/setup)\" = 200 ]"
check "the squatter on 4000 is untouched" "docker ps --format '{{.Names}}' | grep -qx squatter"
check "Node 20+ is on the system PATH" "node --version | grep -Eq '^v(2[0-9]|[3-9][0-9])'"
secrets > "$work/secrets-1"

say "the admin signs in (stood in for by a user row)"
on_host docker exec foreman env -u PHX_SERVER /app/bin/foreman eval '
Application.load(:foreman)
{:ok, _} = Application.ensure_all_started([:ecto_sql, :cloak])
Ecto.Migrator.with_repo(Foreman.Repo, fn _ ->
  {:ok, _} = Foreman.Vault.start_link()
  Foreman.Repo.insert!(%Foreman.Accounts.User{login: "octocat", github_id: 1, role: "admin"})
end)' >/dev/null

say "run 2: GitHub App by hand, a Tailscale client, the box"
on_host sh -c 'openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /root/app.pem 2>/dev/null'
install -e FOREMAN_GITHUB_APP=manual -e FOREMAN_GITHUB_APP_ID=12345 -e FOREMAN_GITHUB_CLIENT_ID=Iv1.e2e \
  -e FOREMAN_GITHUB_CLIENT_SECRET=e2e-client-secret-value -e FOREMAN_GITHUB_KEY_FILE=/root/app.pem \
  -e FOREMAN_TAILSCALE_CLIENT_ID=e2e-client -e FOREMAN_TAILSCALE_CLIENT_SECRET=e2e-tailscale-secret-value
secrets | cmp -s - "$work/secrets-1" ||
  fail "the secrets changed between runs"
echo "ok: secrets weren't regenerated"
check "the key is installed for uid 999, 0400" "[ \"\$(stat -c '%u %a' /etc/foreman/github-app.pem)\" = '999 400' ]"
check "and mounted" "grep -q '/etc/foreman/github-app.pem:/run/secrets/github-app.pem:ro' /opt/foreman/compose.yml"
check "GitHub counts as configured" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4001/setup)\" = 302 ]"
grep -Eq "GitHub rejected the app|couldn't check the app" "$work/last-run.log" ||
  fail "the made-up App ID wasn't checked with GitHub"
echo "ok: the App ID and key were checked with GitHub"
if grep -Eq 'e2e-client-secret-value|e2e-tailscale-secret-value' "$work/last-run.log"; then fail "a secret was printed"; fi
echo "ok: no secret was printed"
check "the box is enrolled" "[ -s /var/lib/foreman-agent/identity.json ]"
check "the agent is running" "systemctl is-active foreman-agent"

say "run 3: nothing to do"
id_before=$(on_host docker inspect -f '{{.Id}}' foreman)
install -e FOREMAN_TAILSCALE=skip
[ "$(on_host docker inspect -f '{{.Id}}' foreman)" = "$id_before" ] || fail "a re-run recreated the container"
echo "ok: the container wasn't recreated"
grep -q "already running with these settings" "$work/last-run.log" || fail "run 3 didn't notice it was up to date"
grep -q "already enrolled" "$work/last-run.log" || fail "run 3 didn't skip the box"

say "run 4: upgrade to another release"
on_host docker tag "$image" foreman-smoke:9.9.9
first_image=$image
image=foreman-smoke:9.9.9
install -e FOREMAN_TAILSCALE=skip
grep -q "FOREMAN_UPGRADE=yes when unattended" "$work/last-run.log" ||
  fail "an unattended upgrade went ahead without FOREMAN_UPGRADE=yes"
check "without it, the old image stays pinned" "grep -qx FOREMAN_IMAGE=$first_image /opt/foreman/.env"
check "and running" "[ \"\$(docker inspect -f '{{.Config.Image}}' foreman)\" = $first_image ]"
install -e FOREMAN_TAILSCALE=skip -e FOREMAN_UPGRADE=yes
check "the new image is pinned" "grep -qx FOREMAN_IMAGE=foreman-smoke:9.9.9 /opt/foreman/.env"
check "and running" "[ \"\$(docker inspect -f '{{.Config.Image}}' foreman)\" = foreman-smoke:9.9.9 ]"
check "the data was backed up first" "tar -tzf /var/backups/foreman/foreman-data.*.tgz | grep -qx ./foreman.db"
check "so were the settings, root only" "[ \"\$(stat -c '%a %U' /var/backups/foreman/foreman.env.*)\" = '600 root' ] && [ \"\$(stat -c %a /var/backups/foreman)\" = 700 ]"
check "and the GitHub App's key; the tarball is root only too" "[ \"\$(stat -c %a /var/backups/foreman/github-app.pem.*)\" = 600 ] && [ \"\$(stat -c %a /var/backups/foreman/foreman-data.*.tgz)\" = 600 ]"
secrets | cmp -s - "$work/secrets-1" || fail "the secrets changed on upgrade"
echo "ok: secrets survived the upgrade"
check "GitHub is still configured" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4001/setup)\" = 302 ]"

say "run 5: an older release's installer doesn't downgrade"
image=$first_image
install -e FOREMAN_TAILSCALE=skip -e FOREMAN_UPGRADE=yes
grep -q "FOREMAN_DOWNGRADE=yes downgrades anyway" "$work/last-run.log" || fail "the downgrade wasn't refused"
check "9.9.9 stays pinned" "grep -qx FOREMAN_IMAGE=foreman-smoke:9.9.9 /opt/foreman/.env"

fresh_host
say "taking over a manual install (127.0.0.1:4100, served on 8443)"
on_host sh -c 'apt-get update -qq && apt-get install -y -qq jq >/dev/null 2>&1'
on_host sh -c "install -d -m 0700 /etc/foreman && printf '%s\n' \
  \"SECRET_KEY_BASE=\$(openssl rand -base64 48 | tr -d '\n')\" \
  \"FOREMAN_ENCRYPTION_KEY=\$(openssl rand -base64 32)\" \
  PHX_HOST=$fqdn FOREMAN_LISTEN_IP=0.0.0.0 FOREMAN_ADMINS=octocat \
  FOREMAN_AGENT_RELEASE_PUBLIC_KEY=$key FOREMAN_AGENT_RELEASE_DIR=/var/lib/foreman/releases \
  FOREMAN_BASE_URL=https://$fqdn:8443 FOREMAN_EXTRA_ORIGINS=https://$fqdn:8443 > /etc/foreman/foreman.env && chmod 0600 /etc/foreman/foreman.env"
on_host install -d /opt/foreman
sed 's/127.0.0.1:4000:4000/127.0.0.1:4100:4000/' "$root/docker/compose.yml" | docker exec -i "$host" sh -c 'cat > /opt/foreman/compose.yml'
on_host sh -c "echo FOREMAN_IMAGE=$image > /opt/foreman/.env && cd /opt/foreman && docker compose up -d -q 2>/dev/null || docker compose up -d >/dev/null 2>&1"
on_host tailscale serve --bg --https=8443 http://127.0.0.1:4100 >/dev/null
i=0
until on_host curl -fsS -o /dev/null http://127.0.0.1:4100/healthz 2>/dev/null; do
  i=$((i + 1)); [ $i -lt 90 ] || fail "the manual install didn't come up"; sleep 1
done
secrets > "$work/secrets-1"
# A settings file that lost its key, beside a container that has it.
on_host sed -i '/^FOREMAN_ENCRYPTION_KEY=/d' /etc/foreman/foreman.env
ADMINS=""
install -e FOREMAN_GITHUB_APP=skip -e FOREMAN_BOX=skip -e FOREMAN_TAILSCALE=skip
grep -q "took FOREMAN_ENCRYPTION_KEY from the running foreman container" "$work/last-run.log" ||
  fail "the missing key wasn't taken from the running container"
check "the manual install's port is kept" "grep -qx FOREMAN_PORT=4100 /opt/foreman/.env"
check "so is its serve port" "grep -qx FOREMAN_BASE_URL=https://$fqdn:8443 /etc/foreman/foreman.env"
check "nothing new is served" "[ \"\$(jq -c '.Web | keys' /var/lib/fake-tailscale/serve.json)\" = '[\"$fqdn:443\",\"$fqdn:8443\"]' ]"
check "the old compose file is kept" "ls /opt/foreman/compose.yml.before-installer.*"
check "the admin came from the settings file" "grep -qx FOREMAN_ADMINS=octocat /etc/foreman/foreman.env"
secrets | cmp -s - "$work/secrets-1" || fail "taking over changed the secrets"
echo "ok: the manual install's secrets are kept"
check "healthz answers through serve" "curl -fsS https://$fqdn:8443/healthz"

say "taking over a manual install from a checkout's docker/ dir, on a newer image"
on_host sh -c 'cd /opt/foreman && docker compose down >/dev/null 2>&1 && rm -rf /opt/foreman'
on_host docker tag "$image" foreman-smoke:9.9.9
on_host install -d /root/foreman/docker
sed 's/127.0.0.1:4000:4000/127.0.0.1:4100:4000/' "$root/docker/compose.yml" | docker exec -i "$host" sh -c 'cat > /root/foreman/docker/compose.yml'
on_host sh -c "echo FOREMAN_IMAGE=foreman-smoke:9.9.9 > /root/foreman/docker/.env && cd /root/foreman/docker && docker compose up -d >/dev/null 2>&1"
i=0
until on_host curl -fsS -o /dev/null http://127.0.0.1:4100/healthz 2>/dev/null; do
  i=$((i + 1)); [ $i -lt 90 ] || fail "the checkout's manual install didn't come up"; sleep 1
done
install -e FOREMAN_GITHUB_APP=skip -e FOREMAN_BOX=skip -e FOREMAN_TAILSCALE=skip
grep -q "FOREMAN_DOWNGRADE=yes downgrades anyway" "$work/last-run.log" ||
  fail "the installer's older image replaced the manual install's newer one"
check "the manual install still runs 9.9.9" "[ \"\$(docker inspect -f '{{.Config.Image}}' foreman)\" = foreman-smoke:9.9.9 ]"
check "and nothing was pinned" "[ ! -e /opt/foreman/.env ]"
image=foreman-smoke:9.9.9
install -e FOREMAN_GITHUB_APP=skip -e FOREMAN_BOX=skip -e FOREMAN_TAILSCALE=skip
grep -q "was started from /root/foreman/docker" "$work/last-run.log" ||
  fail "the old compose dir wasn't pointed out"
check "the same image is pinned in /opt/foreman" "grep -qx FOREMAN_IMAGE=foreman-smoke:9.9.9 /opt/foreman/.env"
check "and runs from there" "[ \"\$(docker inspect -f '{{index .Config.Labels \"com.docker.compose.project.working_dir\"}}' foreman)\" = /opt/foreman ]"
check "healthz answers through serve" "curl -fsS https://$fqdn:8443/healthz"

say "a settings file that says 443, where another service now has 443"
on_host sh -c 'cd /opt/foreman && docker compose down >/dev/null 2>&1 && rm -rf /opt/foreman'
on_host sed -i -e "s|^FOREMAN_BASE_URL=.*|FOREMAN_BASE_URL=https://$fqdn|" \
  -e "s|^FOREMAN_EXTRA_ORIGINS=.*|FOREMAN_EXTRA_ORIGINS=https://$fqdn,https://$fqdn:8443|" /etc/foreman/foreman.env
install -e FOREMAN_GITHUB_APP=skip -e FOREMAN_BOX=skip -e FOREMAN_TAILSCALE=skip
grep -q "https://$fqdn no longer reaches Foreman (it serves http://127.0.0.1:4444 now)" "$work/last-run.log" ||
  fail "the old URL wasn't reported as another service's"
if grep -q "serve --https=443 off" "$work/last-run.log"; then fail "it suggested unserving the other service"; fi
echo "ok: it doesn't suggest unserving the other service"
check "443 still serves the other service, Funnel on" "jq -e '.Web[\"$fqdn:443\"].Handlers[\"/\"].Proxy == \"http://127.0.0.1:4444\" and .AllowFunnel[\"$fqdn:443\"] == true' /var/lib/fake-tailscale/serve.json"
check "its origin is no longer allowed" "! grep -E '^FOREMAN_EXTRA_ORIGINS=(.*,)?https://$fqdn(,|\$)' /etc/foreman/foreman.env"
check "healthz answers at the new URL" "curl -fsS \"\$(sed -n 's/^FOREMAN_BASE_URL=//p' /etc/foreman/foreman.env)/healthz\""

rm -rf "$work"
say "passed"
