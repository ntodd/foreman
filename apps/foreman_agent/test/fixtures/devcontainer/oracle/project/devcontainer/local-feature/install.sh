#!/bin/sh
set -e
echo "greeting=$GREETING loud=$LOUD zeta=$ZETA user=$_REMOTE_USER home=$_REMOTE_USER_HOME"
mkdir -p /usr/local/share /opt/zed/bin
printf "#!/bin/sh\nexec \"\$@\"\n" > /usr/local/share/local-entry.sh
chmod +x /usr/local/share/local-entry.sh
