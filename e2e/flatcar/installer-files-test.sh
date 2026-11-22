#!/bin/sh
# Run inside a disposable Linux test container as root. Exercise the same
# file operations the installer uses on an existing box.
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed '/^# The installed launcher/,$d' apps/foreman/priv/agent/vm.sh > "$work/functions"
# shellcheck source=/dev/null
. "$work/functions"
USER_NAME=nobody
DIR=$work/box
chmod 0755 "$work"
mkdir "$DIR"
chown "$USER_NAME" "$DIR"
printf 'name=test\ncpus=2\nmemory=4\n' > "$DIR/box.conf"
chmod 0644 "$DIR/box.conf"
cat > "$work/qemu" <<'EOF'
#!/bin/sh
id -u > "$FOREMAN_BOX_DIR/probe-uid"
EOF
chmod 0755 "$work/qemu"
export FOREMAN_BOX_DIR="$DIR"
aio=$(probe_aio "$DIR" "$work/qemu")
[ "$aio" = io_uring ]
[ "$(cat "$DIR/probe-uid")" = "$(id -u nobody)" ]
update_config 3 4 "$work/qemu" /fixture/firmware "$aio"
[ "$(stat -c %u "$DIR/box.conf")" = "$(id -u nobody)" ]
[ "$(conf cpus)" = 3 ]
[ "$(conf name)" = test ]
