#!/usr/bin/env bats

load helpers

HOST=dev.osiris-delta.ts.net
TARGET=http://127.0.0.1:4100

setup() {
  setup_installer
  # A fake tailscale that answers from fixture files. `serve --bg` copies
  # $TS_SERVE_AFTER over the current state when it's set, and otherwise
  # changes nothing (the way serve exits 0 when HTTPS still needs
  # enabling).
  export TS_STATUS="$FIXTURES/status-running-tagged.json"
  export TS_SERVE_STATE="$BATS_TEST_TMPDIR/serve.json"
  cp "$FIXTURES/serve-empty.json" "$TS_SERVE_STATE"
  stub tailscale 'case "$1 $2" in
  "status --json") cat "$TS_STATUS" ;;
  "serve status")
    if [ "${3:-}" = --json ]; then cat "$TS_SERVE_STATE"; else echo "https://'"$HOST"':8443 (tailnet only)"; fi ;;
  "serve --bg") if [ -n "${TS_SERVE_AFTER:-}" ]; then cp "$TS_SERVE_AFTER" "$TS_SERVE_STATE"; fi ;;
  "serve --https="*) [ "${3:-}" = off ] && if [ -n "${TS_SERVE_OFF:-}" ]; then cp "$TS_SERVE_OFF" "$TS_SERVE_STATE"; fi ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'
}

serve_json() { cat "$FIXTURES/serve-$1.json"; }

@test "serve_port_choice takes 443 when nothing is served" {
  run serve_port_choice "$(serve_json empty)" "$HOST" 4100
  [ "$status" -eq 0 ]
  [ "$output" = 443 ]
}

@test "serve_port_choice moves off 443 when another service (with Funnel) has it" {
  run serve_port_choice "$(serve_json funnel-443)" "$HOST" 4100
  [ "$output" = 8443 ]
}

@test "serve_port_choice reuses the port already serving Foreman" {
  run serve_port_choice "$(serve_json foreman-8443)" "$HOST" 4100
  [ "$output" = 8443 ]
}

@test "serve_port_choice counts ports held by a foreground serve session" {
  run serve_port_choice "$(serve_json foreground)" "$HOST" 4100
  [ "$output" = 443 ]
  run serve_port_choice "$(serve_json foreground)" "$HOST" 5000
  # The foreground session isn't ours to take over, even with the same target.
  [ "$output" = 443 ]
}

@test "serve_port_choice falls back past the Funnel ports" {
  run serve_port_choice "$(serve_json funnel-ports-taken)" "$HOST" 4100
  [ "$output" = 8444 ]
}

@test "serve_port_choice refuses a requested port another service uses" {
  run serve_port_choice "$(serve_json funnel-443)" "$HOST" 4100 443
  [ "$status" -eq 1 ]
  [[ "$output" == *"443"* ]]
  [[ "$output" == *"http://127.0.0.1:4444"* ]]
}

@test "serve_port_choice takes a requested free port, or Foreman's own" {
  run serve_port_choice "$(serve_json funnel-443)" "$HOST" 4100 9443
  [ "$output" = 9443 ]
  run serve_port_choice "$(serve_json foreman-8443)" "$HOST" 4100 8443
  [ "$output" = 8443 ]
}

@test "serve_check passes for Foreman's port served tailnet only" {
  run serve_check "$(serve_json foreman-8443)" "$HOST" 8443 "$TARGET"
  [ "$status" -eq 0 ]
}

@test "serve_check fails when the port doesn't serve Foreman" {
  run serve_check "$(serve_json empty)" "$HOST" 8443 "$TARGET"
  [ "$status" -eq 1 ]
  run serve_check "$(serve_json funnel-443)" "$HOST" 443 "$TARGET"
  [ "$status" -eq 1 ]
}

@test "serve_check fails when Foreman's port has Funnel on" {
  run serve_check "$(serve_json foreman-funnel)" "$HOST" 8443 "$TARGET"
  [ "$status" -eq 2 ]
}

@test "tailscale_self reads the MagicDNS name, tags and tailnet" {
  tailscale_self
  [ "$TS_HOST" = "$HOST" ]
  [ "$TS_TAGS" = "tag:foreman" ]
  [ "$TS_TAILNET" = "nate@example.com" ]
}

@test "tailscale_self handles an untagged host" {
  export TS_STATUS="$FIXTURES/status-running-untagged.json"
  tailscale_self
  [ "$TS_HOST" = "$HOST" ]
  [ -z "$TS_TAGS" ]
}

@test "tailscale_self says to log in when tailscale isn't running" {
  export TS_STATUS="$FIXTURES/status-needs-login.json"
  run tailscale_self
  [ "$status" -eq 1 ]
  [[ "$output" == *"tailscale up"* ]]
}

@test "tailscale_self says to turn on HTTPS certificates when they're off" {
  export TS_STATUS="$FIXTURES/status-no-https.json"
  run tailscale_self
  [ "$status" -eq 1 ]
  [[ "$output" == *"login.tailscale.com/admin/dns"* ]]
}

@test "serve_https serves in the background, tailnet only, and verifies it" {
  cp "$FIXTURES/serve-funnel-443.json" "$TS_SERVE_STATE"
  export TS_SERVE_AFTER="$FIXTURES/serve-foreman-8443.json"
  run serve_https "$HOST" 8443 "$TARGET"
  [ "$status" -eq 0 ]
  grep -q "^tailscale serve --bg --https=8443 $TARGET\$" "$STUB_LOG"
  run ! grep -q funnel "$STUB_LOG"
  run ! grep -q "reset" "$STUB_LOG"
}

@test "serve_https skips serving when the port already serves Foreman" {
  cp "$FIXTURES/serve-foreman-8443.json" "$TS_SERVE_STATE"
  run serve_https "$HOST" 8443 "$TARGET"
  [ "$status" -eq 0 ]
  run ! grep -q "serve --bg" "$STUB_LOG"
}

@test "serve_https fails when serve exits 0 but changed nothing" {
  run serve_https "$HOST" 8443 "$TARGET"
  [ "$status" -eq 1 ]
  [[ "$output" == *"8443"* ]]
}

@test "serve_https turns Funnel off rather than accept it on Foreman's port" {
  cp "$FIXTURES/serve-foreman-funnel.json" "$TS_SERVE_STATE"
  export TS_SERVE_AFTER="$FIXTURES/serve-foreman-8443.json"
  run serve_https "$HOST" 8443 "$TARGET"
  [ "$status" -eq 0 ]
  grep -q "serve --bg --https=8443" "$STUB_LOG"
}

@test "policy_snippet grants the chosen port on the host's tag" {
  run policy_snippet 8443 tag:foreman
  [ "$status" -eq 0 ]
  [[ "$output" == *'"tag:foreman-env": ["autogroup:admin"]'* ]]
  [[ "$output" == *'"dst": ["tag:foreman-env"], "ip": ["*"]'* ]]
  [[ "$output" == *'"dst": ["tag:foreman"], "ip": ["8443"]'* ]]
  [[ "$output" == *'"users": ["autogroup:nonroot"]'* ]]
}

@test "policy_snippet for an untagged host says the allow-all policy covers the UI" {
  run policy_snippet 443 ""
  [ "$status" -eq 0 ]
  [[ "$output" != *'"ip": ["443"]'* ]]
  [[ "$output" == *"isn't tagged"* ]]
}

@test "serve_port_choice refuses serve status output that isn't a JSON object" {
  run serve_port_choice "" "$HOST" 4100
  [ "$status" -eq 1 ]
  [[ "$output" == *"serve status"* ]]
  run serve_port_choice "not json" "$HOST" 4100
  [ "$status" -eq 1 ]
}

@test "serve_https refuses to go on when serve status can't be read" {
  : > "$TS_SERVE_STATE"
  run serve_https "$HOST" 443 "$TARGET"
  [ "$status" -eq 1 ]
  run ! grep -q "serve --bg" "$STUB_LOG"
}

@test "serve_port_choice recognizes Foreman served through localhost or [::1]" {
  run serve_port_choice "$(serve_json foreman-localhost-8443)" "$HOST" 4100
  [ "$output" = 8443 ]
  json=$(serve_json foreman-localhost-8443 | sed 's|http://localhost:4100|http://[::1]:4100|')
  run serve_port_choice "$json" "$HOST" 4100
  [ "$output" = 8443 ]
}

@test "serve_port_choice keeps Foreman's serve port when its loopback port changed" {
  run serve_port_choice "$(serve_json foreman-8443)" "$HOST" 4100
  [ "$output" = 8443 ]
}

@test "serve_port_choice keeps the base URL's port when it's free" {
  run serve_port_choice "$(serve_json empty)" "$HOST" 4100 "" 8443
  [ "$output" = 8443 ]
}

@test "serve_port_choice doesn't keep the base URL's port when something else took it" {
  run serve_port_choice "$(serve_json funnel-443)" "$HOST" 4100 "" 443
  [ "$output" = 8443 ]
}

@test "serve_port_choice doesn't take over another service on a different loopback port" {
  run serve_port_choice "$(serve_json funnel-443)" "$HOST" 4200
  [ "$output" = 8443 ]
}

@test "port_443_note names what 443 serves, Funnel included" {
  run port_443_note "$(serve_json funnel-443)" "$HOST" 8443
  [[ "$output" == *"already serves http://127.0.0.1:4444 (with Funnel on); leaving it alone"* ]]
}

@test "port_443_note doesn't claim 443 is taken when it's free" {
  run port_443_note "$(serve_json foreman-localhost-8443)" "$HOST" 8443
  [[ "$output" != *"already serves"* ]]
  [[ "$output" == *"stays on 8443"* ]]
  run port_443_note "$(serve_json empty)" "$HOST" 443
  [ -z "$output" ]
}

@test "tagged-host notes don't claim a tag rules out allow-all" {
  run policy_snippet 8443 tag:server
  [[ "$output" == *"isn't the default allow-all"* ]]
  [[ "$output" != *"only through grants"* ]]
  [[ "$output" != *"reached only"* ]]
  run tagged_host_note tag:server 8443
  [[ "$output" == *"tag:server"* ]]
  [[ "$output" == *"isn't the default allow-all"* ]]
  [[ "$output" == *'"dst": ["tag:server"], "ip": ["8443"]'* ]]
}

@test "serve_port_choice doesn't count a loopback proxy as Foreman's without a sign Foreman was there" {
  # Another service on 443 -> 127.0.0.1:4000 with Funnel, down for now.
  json=$(serve_json funnel-443 | sed 's|127.0.0.1:4444|127.0.0.1:4000|')
  run serve_port_choice "$json" "$HOST" ""
  [ "$output" = 8443 ]
  run serve_port_choice "$json" "$HOST" 4100
  [ "$output" = 8443 ]
}

@test "serve_port_choice counts the base URL's port as Foreman's when it proxies to loopback" {
  # The settings file says Foreman is on 8443; its container is gone.
  run serve_port_choice "$(serve_json foreman-8443)" "$HOST" "" "" 8443
  [ "$output" = 8443 ]
}

@test "serve_port_choice skips ports something on this host listens on" {
  run serve_port_choice "$(serve_json empty)" "$HOST" 4100 "" "" "22 443 8443"
  [ "$output" = 10000 ]
  run serve_port_choice "$(serve_json empty)" "$HOST" 4100 "" 8443 "8443"
  [ "$output" = 443 ]
  # Foreman's own serve port stays, whatever listens there.
  run serve_port_choice "$(serve_json foreman-8443)" "$HOST" 4100 "" "" "8443"
  [ "$output" = 8443 ]
}

@test "serve_port_choice warns when a requested port shadows a local listener" {
  run serve_port_choice "$(serve_json empty)" "$HOST" 4100 8443 "" "8443"
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = 8443 ]
  [[ "$output" == *"listens on port 8443"* ]]
}

@test "serve_loopback_ports lists the loopback ports serve forwards to" {
  run serve_loopback_ports "$(serve_json foreground)"
  [ "$(echo $output)" = "22 5000" ]
  run serve_loopback_ports "$(serve_json funnel-443)"
  [ "$output" = 4444 ]
  run serve_loopback_ports "$(serve_json empty)"
  [ -z "$output" ]
}

@test "a fresh install keeps off another service's serve port and its loopback target" {
  # 443 -> 127.0.0.1:4000 with Funnel on, and that service is down, so
  # nothing listens on 4000. Foreman on 4000 would be on the internet.
  serve_json funnel-443 | sed 's|127.0.0.1:4444|127.0.0.1:4000|' > "$TS_SERVE_STATE"
  stub docker 'exit 1'
  stub ss 'exit 0'
  choose_tailnet_and_ports >/dev/null
  [ "$HOST_PORT" = 4001 ]
  [ "$HTTPS_PORT" = 8443 ]
  run ! grep -q "serve --bg" "$STUB_LOG"
}

@test "port_443_note says when a local listener has 443" {
  run port_443_note "$(serve_json empty)" "$HOST" 8443 "22 443"
  [[ "$output" == *"listens on 443"* ]]
  [[ "$output" != *"443 is free"* ]]
}

@test "serve_port_choice doesn't claim the base URL's port when its loopback target is another live service" {
  # 443 -> 127.0.0.1:4444 with Funnel, and something listens on 4444:
  # foreman.env restored onto a rebuilt host, or /opt/foreman removed.
  json=$(serve_json funnel-443 | jq 'del(.AllowFunnel)')
  run serve_port_choice "$json" "$HOST" "" "" 443 "22 4444"
  [ "$status" -eq 0 ]
  [ "$output" = 8443 ]
  # A requested port gets the same answer: it isn't Foreman's to take.
  run serve_port_choice "$json" "$HOST" "" 443 443 "22 4444"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already serves http://127.0.0.1:4444"* ]] || false
}

@test "serve_port_choice doesn't claim the base URL's port when it has Funnel on" {
  # Nothing listens on 4444, but Funnel is on: Foreman is never on Funnel.
  run serve_port_choice "$(serve_json funnel-443)" "$HOST" "" "" 443 "22"
  [ "$status" -eq 0 ]
  [ "$output" = 8443 ]
  run serve_port_choice "$(serve_json funnel-443)" "$HOST" "" "" 443 "22 4444"
  [ "$output" = 8443 ]
}

@test "serve_port_choice still claims the base URL's port when it proxies to an idle loopback port without Funnel" {
  run serve_port_choice "$(serve_json foreman-8443)" "$HOST" "" "" 8443 "22 4000"
  [ "$output" = 8443 ]
  # ...but not when something listens on its target.
  run serve_port_choice "$(serve_json foreman-8443)" "$HOST" "" "" 8443 "22 4100"
  [ "$output" = 10000 ]
}

@test "serve_https says so when it turns Funnel off on Foreman's port" {
  cp "$FIXTURES/serve-foreman-funnel.json" "$TS_SERVE_STATE"
  export TS_SERVE_AFTER="$FIXTURES/serve-foreman-8443.json"
  run serve_https "$HOST" 8443 "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Funnel is on for https://$HOST:8443"* ]] || false
  [[ "$output" == *"turning it off"* ]] || false
}

@test "serve_https takes Foreman off the port when Funnel stays on, before failing" {
  cp "$FIXTURES/serve-foreman-funnel.json" "$TS_SERVE_STATE"
  # serve leaves Funnel on; serve --https=8443 off clears the port.
  export TS_SERVE_AFTER="$FIXTURES/serve-foreman-funnel.json"
  export TS_SERVE_OFF="$FIXTURES/serve-empty.json"
  run serve_https "$HOST" 8443 "$TARGET"
  [ "$status" -eq 1 ]
  grep -qx "tailscale serve --https=8443 off" "$STUB_LOG"
  [[ "$output" == *"funnel --https=8443 off"* ]] || false
  [[ "$output" == *"took Foreman off"* ]] || false
}

@test "serve_port_choice counts a port with only Funnel set as used" {
  json='{"AllowFunnel": {"dev.osiris-delta.ts.net:443": true}}'
  run serve_port_choice "$json" "$HOST" 4100
  [ "$output" = 8443 ]
  json='{"Foreground": {"abc": {"AllowFunnel": {"dev.osiris-delta.ts.net:443": true}}}}'
  run serve_port_choice "$json" "$HOST" 4100
  [ "$output" = 8443 ]
  run serve_port_choice "$json" "$HOST" 4100 443
  [ "$status" -eq 1 ]
}

@test "serve_port_choice doesn't claim the base URL's port when it has handlers besides /" {
  # "/" -> an idle loopback port, "/api" -> another app: serving Foreman
  # there would only replace "/" and leave the two sharing the port.
  json=$(jq -n --arg hp "$HOST:443" '{TCP: {"443": {HTTPS: true}},
    Web: {($hp): {Handlers: {"/": {Proxy: "http://127.0.0.1:4000"}, "/api": {Proxy: "http://127.0.0.1:5000"}}}}}')
  run serve_port_choice "$json" "$HOST" "" "" 443 "22 5000"
  [ "$status" -eq 0 ]
  [ "$output" = 8443 ]
}

@test "serve_loopback_ports reads targets with a path, query or fragment, and every loopback spelling" {
  run serve_loopback_ports "$(serve_json loopback-targets)"
  [ "$status" -eq 0 ]
  # 4001 has a query, 4002 a trailing path, 4003 is https+insecure on
  # 127.0.1.1, 4004 0.0.0.0 with a path, 4005 [::1] with a fragment,
  # 4006 a TCP forward to localhost, 4007 a service, 4008 a foreground
  # TCP forward to [::]; LOCALHOST without a port is 80. 192.168.1.5
  # isn't this host's loopback.
  [ "$(echo $output)" = "80 4001 4002 4003 4004 4005 4006 4007 4008" ]
}

@test "a fresh install keeps off a Funnel target that has a path" {
  # 443 -> http://127.0.0.1:4000/app with Funnel on, and that service is
  # down. Foreman on 4000 would be on the internet.
  cp "$FIXTURES/serve-funnel-443-path.json" "$TS_SERVE_STATE"
  stub docker 'exit 1'
  stub ss 'exit 0'
  choose_tailnet_and_ports >/dev/null
  [ "$HOST_PORT" = 4001 ]
  [ "$HTTPS_PORT" = 8443 ]
}

@test "a fresh install keeps off a Funnel target with a query, and off a TCP forward" {
  serve_json funnel-443-path | sed 's|4000/app|4000/?x=1|' |
    jq '.TCP["5432"] = {"TCPForward": "127.0.0.1:4001"}' > "$TS_SERVE_STATE"
  stub docker 'exit 1'
  stub ss 'exit 0'
  choose_tailnet_and_ports >/dev/null
  [ "$HOST_PORT" = 4002 ]
}

@test "serve_port_choice and serves_loopback_port read a target with a path as Foreman's pinned port" {
  json=$(serve_json foreman-8443 | sed 's|127.0.0.1:4100|127.0.0.1:4100/|')
  run serve_port_choice "$json" "$HOST" 4100
  [ "$output" = 8443 ]
  serves_loopback_port "$json" "$HOST" 8443 4100
  json=$(serve_json foreman-8443 | sed 's|127.0.0.1:4100|localhost:4100/app?x=1|')
  serves_loopback_port "$json" "$HOST" 8443 4100
  run ! serves_loopback_port "$json" "$HOST" 8443 4000
}

@test "serve_port_choice doesn't guess that a base URL port proxying to a path is Foreman's" {
  # Nothing pinned: only a bare loopback target can be Foreman's.
  json=$(serve_json foreman-8443 | jq 'del(.AllowFunnel)' | sed 's|127.0.0.1:4100|127.0.0.1:4100/app|')
  run serve_port_choice "$json" "$HOST" "" "" 8443
  [ "$output" = 10000 ]
  json=$(serve_json foreman-8443 | jq 'del(.AllowFunnel)')
  run serve_port_choice "$json" "$HOST" "" "" 8443
  [ "$output" = 8443 ]
}
