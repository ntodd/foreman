#!/usr/bin/env bats

load helpers

setup() { setup_installer; }

@test "pick_free_port takes the first port at or above the start that isn't used" {
  run pick_free_port 4000
  [ "$output" = 4000 ]
  run pick_free_port 4000 22 4000 4001 4003
  [ "$output" = 4002 ]
}

@test "host_port_choice keeps the port a previous run pinned" {
  run host_port_choice "" 4100 4000 22
  [ "$status" -eq 0 ]
  [ "$output" = 4100 ]
}

@test "host_port_choice skips 4000 when another container publishes it" {
  run host_port_choice "" "" 22 4000
  [ "$output" = 4001 ]
}

@test "host_port_choice takes a requested free port" {
  run host_port_choice 4100 "" 4000
  [ "$output" = 4100 ]
}

@test "host_port_choice refuses a requested port that's in use" {
  run host_port_choice 4000 "" 4000
  [ "$status" -eq 1 ]
  [[ "$output" == *"4000 is already in use"* ]]
}

@test "host_port_choice refuses a pinned port that something else took" {
  run host_port_choice "" 4100 4100
  [ "$status" -eq 1 ]
  [[ "$output" == *"4100"* ]]
}

@test "host_port_choice refuses a port that isn't a number" {
  run host_port_choice 40a0 "" 4000
  [ "$status" -eq 1 ]
  run host_port_choice 70000 ""
  [ "$status" -eq 1 ]
}

@test "ports_in_use reads ss and docker, leaving out Foreman's own container" {
  stub ss 'cat <<OUT
LISTEN 0      4096         0.0.0.0:4000      0.0.0.0:*
LISTEN 0      4096       127.0.0.1:4444      0.0.0.0:*
LISTEN 0      4096       127.0.0.1:4100      0.0.0.0:*
LISTEN 0      4096   127.0.0.53%lo:53        0.0.0.0:*
LISTEN 0      4096            [::]:22           [::]:*
LISTEN 0      4096               *:9100            *:*
OUT'
  stub docker 'case "$1" in
  ps) printf "%s\n" "0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp" "127.0.0.1:4100->4000/tcp" "" ;;
  port) echo "4000/tcp -> 127.0.0.1:4100" ;;
esac'
  run ports_in_use foreman
  [ "$status" -eq 0 ]
  [ "$(echo $output)" = "22 53 4000 4444 5432 9100" ]
}

@test "ports_in_use works when Foreman's container doesn't exist yet" {
  stub ss 'echo "LISTEN 0 4096 0.0.0.0:4000 0.0.0.0:*"'
  stub docker 'case "$1" in
  ps) echo "0.0.0.0:4000->4000/tcp" ;;
  port) echo "Error: No such container: foreman" >&2; exit 1 ;;
esac'
  run ports_in_use foreman
  [ "$status" -eq 0 ]
  [ "$(echo $output)" = "4000" ]
}

@test "pinned_host_port reads the port a previous run pinned" {
  mkdir -p "$FOREMAN_OPT"
  printf '%s\n' FOREMAN_IMAGE=x FOREMAN_PORT=4100 > "$FOREMAN_OPT/.env"
  stub docker 'exit 1'
  [ "$(pinned_host_port foreman)" = 4100 ]
}

@test "pinned_host_port adopts the port an existing foreman container publishes" {
  stub docker '[ "$1 $2 $3" = "port foreman 4000/tcp" ] && printf "%s\n" "127.0.0.1:4100" "[::1]:4100"'
  [ "$(pinned_host_port foreman)" = 4100 ]
}

@test "pinned_host_port is empty on a fresh host" {
  stub docker 'exit 1'
  [ -z "$(pinned_host_port foreman)" ]
}

@test "ports_in_use expands published port ranges" {
  stub ss 'true'
  stub docker 'case "$1" in
  ps) case "$*" in *-a*) ;; *) echo "0.0.0.0:4000-4002->4000-4002/tcp, 127.0.0.1:4005->80/tcp" ;; esac ;;
  *) exit 1 ;;
esac'
  run ports_in_use foreman
  [ "$status" -eq 0 ]
  [ "$(echo $output)" = "4000 4001 4002 4005" ]
}

@test "ports_in_use counts stopped containers that restart on their own, but not Foreman's" {
  stub ss 'true'
  stub docker 'case "$1" in
  ps) case "$*" in *-a*) printf "%s\n" aaa bbb ccc ddd ;; esac ;;
  inspect) printf "%s\n" "/web|always|4000 " "/once|no|4300 " "/later|unless-stopped|4400-4401 " "/foreman|unless-stopped|4100 " "/plain||4500 " ;;
  *) exit 1 ;;
esac'
  run ports_in_use foreman
  [ "$status" -eq 0 ]
  [ "$(echo $output)" = "4000 4400 4401" ]
}

@test "pinned_host_port reads a stopped foreman container's port bindings" {
  # docker port shows nothing for a stopped container.
  stub docker 'case "$1" in
  inspect) case "$*" in *PortBindings*) printf "%s\n" "4100 4100 " ;; *) exit 1 ;; esac ;;
  *) exit 0 ;;
esac'
  [ "$(pinned_host_port foreman)" = 4100 ]
}
