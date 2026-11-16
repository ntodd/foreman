#!/bin/sh
# Checks the box firewall against a fake tailnet on a throwaway Linux
# host (CI, or a privileged container): a peer in its own network
# namespace, reached over an interface named tailscale0 the way a box on
# the tailnet reaches its peers.
#
#   sudo e2e/firewall/test.sh apps/foreman_agent/priv/firewall/foreman.nft [guest-forward]
#
# Environment VMs are stood in for by network namespaces on veth pairs
# named like their taps (fm-vm<n>), routed and with a /30 each, the way
# foreman-vmctl sets them up. With guest-forward (priv/vm/guest-forward),
# their traffic goes through Docker's FORWARD policy the way the install
# script lets it.
#
# It changes the host's network (an interface, routes, an nftables table
# and Docker networks), so don't run it on a real box or a shared one:
# CI runs it in a privileged docker:dind container.
set -eu

rules=${1:?usage: test.sh <rules.nft> [guest-forward]}
guest_forward=${2:-}
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

box=100.64.0.1    # the box's own tailnet address
peer=100.64.0.2   # another tailnet machine
subnet=10.213.0.2 # behind a subnet route the box accepts
# Statically linked, so its nc also runs on the host.
image=${FWTEST_IMAGE:-busybox:1.37-musl}

failures=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; failures=$((failures + 1)); }

work=$(mktemp -d)
cleanup() {
  for pid in "$work"/*.pid; do
    [ -e "$pid" ] && kill "$(cat "$pid")" 2>/dev/null
  done
  docker rm -f fwtest-published >/dev/null 2>&1 || true
  docker network rm fwtest-env fwtest-other >/dev/null 2>&1 || true
  nft delete table inet foreman 2>/dev/null || true
  nft delete table inet foreman_guests 2>/dev/null || true
  for n in 0 1; do
    ip link del "fm-vm$n" 2>/dev/null || true
    ip netns del "fwtest-guest$n" 2>/dev/null || true
  done
  ip link del fwtest-lan0 2>/dev/null || true
  ip netns del fwtest-lan 2>/dev/null || true
  ip link del tailscale0 2>/dev/null || true
  ip netns del fwtest-peer 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
cleanup
work=$(mktemp -d)

# -- the fake tailnet ----------------------------------------------------
ip netns add fwtest-peer
ip link add tailscale0 type veth peer name fwtest-peer0
ip link set fwtest-peer0 netns fwtest-peer
ip addr add "$box/32" dev tailscale0
ip link set tailscale0 up
ip route add 100.64.0.0/10 dev tailscale0 src "$box"
ip route add 10.213.0.0/24 dev tailscale0 src "$box"

peer_ns() { ip netns exec fwtest-peer "$@"; }
peer_ns ip link set lo up
peer_ns ip link set fwtest-peer0 up
peer_ns ip addr add "$peer/32" dev fwtest-peer0
peer_ns ip addr add 100.100.100.100/32 dev fwtest-peer0
peer_ns ip addr add "$subnet/32" dev fwtest-peer0
peer_ns ip route add "$box/32" dev fwtest-peer0

docker pull -q "$image" >/dev/null
nc_bin="$work/busybox"
docker create --name fwtest-bb "$image" >/dev/null
docker cp fwtest-bb:/bin/busybox "$nc_bin" >/dev/null
docker rm fwtest-bb >/dev/null

listen() { # name, netns-or-empty, address, port
  if [ -n "$2" ]; then
    ip netns exec "$2" "$nc_bin" nc -lk -s "$3" -p "$4" -e /bin/true >/dev/null 2>&1 &
  else
    "$nc_bin" nc -lk -s "$3" -p "$4" -e /bin/true >/dev/null 2>&1 &
  fi
  echo $! > "$work/$1.pid"
}
listen peer fwtest-peer "$peer" 8080
listen subnet fwtest-peer "$subnet" 8080
listen dns fwtest-peer 100.100.100.100 53
listen box "" "$box" 8081

# -- the networks ----------------------------------------------------------
docker network create -o com.docker.network.bridge.name=fm-fwtest0001 fwtest-env >/dev/null
docker network create fwtest-other >/dev/null
# Another container's port, published on the box's tailnet address.
docker run -d --name fwtest-published --network fwtest-other -p "$box:8082:8080" "$image" \
  nc -lk -p 8080 -e /bin/true >/dev/null
sleep 1

reach() { # network, address, port
  docker run --rm --network "$1" "$image" nc -z -w 3 "$2" "$3" >/dev/null 2>&1
}

# A Dockerfile's RUN step, on Docker's own builder.
build_reaches() { # address, port
  printf 'FROM %s\nRUN nc -z -w 3 %s %s\n' "$image" "$1" "$2" |
    docker build --no-cache -q - >/dev/null 2>&1
}

expect() { # open|shut, description, command...
  want=$1 what=$2
  shift 2
  if "$@"; then got=open; else got=shut; fi
  if [ "$got" = "$want" ]; then pass "$what"; else fail "$what (got $got)"; fi
}

# Without the rules every path is open: the test can see the hole.
expect open "without the firewall, an environment reaches a tailnet peer" reach fwtest-env "$peer" 8080
expect open "without the firewall, an environment reaches the box's tailnet address" reach fwtest-env "$box" 8081
expect open "without the firewall, an environment reaches a port published there" reach fwtest-env "$box" 8082
expect open "without the firewall, the default bridge reaches a tailnet peer" reach bridge "$peer" 8080
expect open "without the firewall, a build reaches a tailnet peer" build_reaches "$peer" 8080

nft -f "$rules"
nft -f "$rules" # loading again replaces the table

expect shut "an environment can't reach a tailnet peer" reach fwtest-env "$peer" 8080
expect shut "an environment can't reach a subnet route over tailscale0" reach fwtest-env "$subnet" 8080
expect shut "an environment can't reach the box's own tailnet address" reach fwtest-env "$box" 8081
expect shut "an environment can't reach a port published on it" reach fwtest-env "$box" 8082
expect shut "the default bridge can't reach a tailnet peer" reach bridge "$peer" 8080
expect shut "a build can't reach a tailnet peer" build_reaches "$peer" 8080
expect open "an environment can still use MagicDNS" reach fwtest-env 100.100.100.100 53
expect open "other containers on the box still reach the tailnet" reach fwtest-other "$peer" 8080
expect open "other containers still reach the box's tailnet address" reach fwtest-other "$box" 8081
internet() { reach fwtest-env 1.1.1.1 443 || reach fwtest-env 8.8.8.8 443; }
expect open "an environment still reaches the internet" internet
expect open "the default bridge still reaches the internet" sh -c "docker run --rm $image nc -z -w 3 1.1.1.1 443 || docker run --rm $image nc -z -w 3 8.8.8.8 443"

tables() { [ "$(nft list tables | grep -cx 'table inet foreman')" -eq 1 ]; }
expect open "loading the rules again leaves one foreman table" tables

# A box that opts out of filtering the default bridge (the install
# script's --default-bridge-reaches-tailnet) loads the rules without the
# lines marked for it.
sed '/# default-bridge$/d' "$rules" > "$work/opted-out.nft"
nft -f "$work/opted-out.nft"
expect open "opted out, the default bridge reaches a tailnet peer" reach bridge "$peer" 8080
expect shut "opted out, an environment still can't" reach fwtest-env "$peer" 8080

# -- environment VMs ------------------------------------------------------
if [ -n "$guest_forward" ]; then
  # Back to the full rules, and no table for VMs yet: the holes first.
  nft delete table inet foreman_guests
  nft -f "$rules"
  nft delete table inet foreman_guests

  # Two guests, each on a /30 of its own behind a "tap", as foreman-vmctl
  # makes them: guest n is 10.250.0.(4n+2), the box's end 10.250.0.(4n+1).
  for n in 0 1; do
    ns=fwtest-guest$n
    ip netns add "$ns"
    ip link add "fm-vm$n" type veth peer name eth0 netns "$ns"
    ip addr add "10.250.0.$((4 * n + 1))/30" dev "fm-vm$n"
    ip link set "fm-vm$n" up
    ip netns exec "$ns" ip link set lo up
    ip netns exec "$ns" ip addr add "10.250.0.$((4 * n + 2))/30" dev eth0
    ip netns exec "$ns" ip link set eth0 up
    ip netns exec "$ns" ip route add default via "10.250.0.$((4 * n + 1))"
  done
  g0() { ip netns exec fwtest-guest0 "$@"; }
  g0_reach() { g0 "$nc_bin" nc -z -w 3 "$1" "$2" >/dev/null 2>&1; }

  # The box's LAN: a machine on 192.168.77.0/24, in a namespace of its own.
  ip netns add fwtest-lan
  ip link add fwtest-lan0 type veth peer name lan0 netns fwtest-lan
  ip addr add 192.168.77.1/24 dev fwtest-lan0
  ip link set fwtest-lan0 up
  ip netns exec fwtest-lan ip link set lo up
  ip netns exec fwtest-lan ip addr add 192.168.77.2/24 dev lan0
  ip netns exec fwtest-lan ip link set lan0 up
  lan_ip=192.168.77.2
  listen lan fwtest-lan "$lan_ip" 8086

  # What the box listens on: the tap's gateway, its other address, and
  # guest 1's server.
  box_ip=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
  listen gateway "" 10.250.0.1 8083
  listen boxip "" "$box_ip" 8085
  listen guest1 fwtest-guest1 10.250.0.6 8084
  # A tailnet peer that knows a route to the guests, to try connecting in.
  peer_ns ip route add 10.250.0.0/16 dev fwtest-peer0
  sleep 1

  sh "$guest_forward"
  sh "$guest_forward" # running it again doesn't add the rules twice
  expect open "guest-forward adds its rules once" \
    sh -c "[ \"\$(iptables -S FORWARD | grep -c 'fm-vm+')\" -eq 2 ]"
  expect open "without the VM table, a guest reaches the box on its tap" g0_reach 10.250.0.1 8083
  expect open "without the VM table, a guest reaches another guest" g0_reach 10.250.0.6 8084

  # As the install script loads them by default: the lines for
  # --block-lan left out.
  sed '/# block-lan$/d' "$rules" > "$work/open-lan.nft"
  nft -f "$work/open-lan.nft"
  expect shut "a guest can't reach the box on its tap" g0_reach 10.250.0.1 8083
  expect shut "a guest can't reach the box's other addresses" g0_reach "$box_ip" 8085
  expect shut "a guest can't reach another guest" g0_reach 10.250.0.6 8084
  expect shut "a guest can't reach a tailnet peer" g0_reach "$peer" 8080
  expect shut "a guest can't reach the box's tailnet address" g0_reach "$box" 8081
  expect shut "a guest can't use the box's MagicDNS" g0_reach 100.100.100.100 53
  expect open "a guest reaches the box's LAN" g0_reach "$lan_ip" 8086
  guest_internet() { g0_reach 1.1.1.1 443 || g0_reach 8.8.8.8 443; }
  expect open "a guest reaches the internet" guest_internet
  spoofed() {
    g0 ip addr add 10.250.0.6/32 dev eth0
    g0 "$nc_bin" nc -z -w 3 -s 10.250.0.6 1.1.1.1 443 >/dev/null 2>&1
    status=$?
    g0 ip addr del 10.250.0.6/32 dev eth0
    return $status
  }
  expect shut "a guest can't send from another guest's address" spoofed
  expect open "the box reaches a guest" "$nc_bin" nc -z -w 3 10.250.0.6 8084
  expect shut "a tailnet peer can't connect into a guest" \
    peer_ns "$nc_bin" nc -z -w 3 10.250.0.6 8084

  nft -f "$rules"
  expect shut "with --block-lan, a guest can't reach the box's LAN" g0_reach "$lan_ip" 8086
  expect open "with --block-lan, a guest still reaches the internet" guest_internet
fi

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed" >&2; exit 1; }
echo "all checks passed"
