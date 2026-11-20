#!/bin/bash
# Q0508 ★★ screen truth through transitions (guest, run DETACHED). Usage: nohup bash transitions.sh <label> [filter] &
# Per transition: CLI sets the state, the app is launched with truth-start, the harness samples pf/proxy/egress
# once a second on the same clock, triggers the transition at +5 s, runs D s, then truth-compare.mjs joins both.
set -u
LABEL=${1:-r1}; TF=${2:-.}; D=${D:-40}
export DVPN_KEYFILE=$HOME/ksm/ksm-wallet.json DVPN_DATA_DIR=$HOME/ksm/profile PATH=/usr/local/bin:$PATH
ROOT=$HOME/ksm/out/transitions-$LABEL; mkdir -p "$ROOT"; LOG=$ROOT/run.log
DIRECT=${DIRECT_IP:-104.196.36.139}
V2=Di5V9K2Vt5uptJUk7oVVnkDRXt9qWy5HhLbkEJMxEuM2; WG=85UXF7JoeojwCe3vBEQsu8A3iBhqtggi1n828Lq84K3q
SVC=system/co.sentinel.sentinel-dvpnd.c0
c() { echo "> $*" >> "$LOG"; devnet-dvpn "$@" >> "$LOG" 2>&1; }
setstate() { # <ks> <node> <whole-device>
  c disconnect; c daemon restore-network
  c daemon set --kill-switch "$1" --split-mode off --split-apps none --allow-lan true --dns cloudflare --whole-device "$3" --yes
  c connect "$2" --basis per_gb --yes; sleep 5; }
sampler() { # <file> <seconds>: 1 s truth on the shared clock (ms)
  local end=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    local t0; t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
    local e; e=$(curl -s -m 1.5 https://api.ipify.org || echo FAIL)
    local pf; pf=$(sudo -n pfctl -a sentinel-dvpn-c0 -sr 2>/dev/null | grep -cE '^(block|pass)')
    local so; so=$(networksetup -getsocksfirewallproxy Ethernet | awk -F': ' '/^Enabled/{print $2}')
    # service up = its control socket ACCEPTS a connection (a unix connect is immediate; Perl Timeout breaks it on macOS)
    # (DIR r7: up counts from the first answer, not from launchd
    # running + a socket file nobody serves yet). DIR rule: "restarting" while up > 6 s fails.
    local up=down
    perl -MIO::Socket::UNIX -MSocket -e 'exit(IO::Socket::UNIX->new(Peer => $ARGV[0], Type => SOCK_STREAM) ? 0 : 1)' \
      "/Library/Application Support/sentinel-dvpn/c0/daemon.sock" 2>/dev/null && up=up
    printf '%s\t%s\t%s\t%s\t%s\n' "$t0" "$e" "$pf" "$so" "$up" >> "$1"
    local t1; t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000'); local rest=$(( 1000 - (t1 - t0) ))
    [ "$rest" -gt 0 ] && perl -e "select(undef,undef,undef,$rest/1000)"
    sudo -n touch /var/run/ddv-deadman.hold
  done; }
run() { # <name> <ks> <node> <wd> <trigger shell code> [app steps at the trigger] [END=released]
  # App steps run INSIDE the recording: the app waits for trig.ack, which the shell writes at TRIGGER time.
  local N=$1 KS=$2 NODE=$3 WD=$4 TRIG=$5 POST=${6:-} END=${7:-}
  echo "$N" | grep -qE "$TF" || return
  local O=$ROOT/$N; rm -rf "$O"; mkdir -p "$O/sig"
  echo; echo "######## $(date -u +%T) $N (ks=$KS wd=$WD)" >> "$LOG"
  setstate "$KS" "$NODE" "$WD"
  printf 't_ms\tegress\tpf_rules\tsocks\tservice\n' > "$O/shell.tsv"
  DVPN_UI_SIG_DIR=$O/sig DVPN_UI_SCENARIO="nav=Connect;truth-start;signal=go;${POST:+await=trig:60;$POST}await=done:$((D + 60));truth-stop" UI_TIMEOUT=$((D + 180)) \
    bash ~/rc-030/scripts/e2e/mac/ui-smoke.sh dark "$O/ui" >> "$LOG" 2>&1 &
  local UIP=$!
  for i in $(seq 1 120); do [ -f "$O/sig/go" ] && break; sleep 1; done
  [ -f "$O/sig/go" ] || { echo "$N: app never signalled go" >> "$LOG"; kill $UIP 2>/dev/null; return; }
  sampler "$O/shell.tsv" "$D" &
  local SP=$!
  sleep 5; echo "TRIGGER $(perl -MTime::HiRes=time -e 'printf "%d", time*1000') $N" | tee "$O/trigger.txt" >> "$LOG"
  echo ok > "$O/sig/trig.ack"
  ( eval "$TRIG" ) >> "$LOG" 2>&1
  wait $SP; echo ok > "$O/sig/done.ack"; wait $UIP
  "$HOME/node/bin/node" ~/ksm/truth-compare.mjs "$O" "$DIRECT" >> "$LOG" 2>&1
  if [ -f "$O/ksoff.txt" ]; then bash ~/ksm/t10-takedown.sh "$O"; fi
  # Q0534 end state: an Apply that ends the session must release the block (internet back, pf 0) by the end.
  # Still connected through a node is fine; blocked or pf rules held with no session is the bug.
  if [ "$END" = released ]; then
    local bad; bad=$(tail -3 "$O/shell.tsv" | awk -F'\t' -v d="$DIRECT" '$2=="FAIL"||($2==d&&$3>0){b++} END{print b+0}')
    local st; st=$(devnet-dvpn status 2>&1 | head -12 | tr '\n' ' ' | cut -c1-300)
    if [ "$bad" -gt 0 ]; then
      sed -i '' '1s/	PASS	/	FAIL	/' "$O/verdict.txt"
      echo "Q0534 FAIL: block kept at the end ($bad of the last 3 samples blocked or pf held while direct) | $st" >> "$O/verdict.txt"
    else echo "Q0534 end state ok: $(tail -1 "$O/shell.tsv" | cut -f2,3) | $st" >> "$O/verdict.txt"; fi
    cat "$O/verdict.txt" >> "$LOG"
  fi
}

# T1 in-app Apply: kill switch off -> persist while V2Ray (proxy) is connected
run t1-apply-ks-persist off "$V2" false 'true' 'nav=Kill switch;ks-mode=persist;nav=Connect;'
# T2 CLI daemon set with the app open (WireGuard, kill switch off -> persist)
run t2-cli-set-app-open off "$WG" false 'devnet-dvpn daemon set --kill-switch persist --yes'
# T3 service restart (persist + WireGuard)
run t3-service-restart persist "$WG" false 'sudo -n launchctl kickstart -k '"$SVC"
# T4 dvpnd killed (persist + WireGuard)
run t4-dvpnd-kill persist "$WG" false 'sudo -n launchctl kill SIGKILL '"$SVC"
# T5 network off/on 10 s (persist + WireGuard)
run t5-network-off-on persist "$WG" false 'sudo -n networksetup -setnetworkserviceenabled Ethernet off; sleep 10; sudo -n networksetup -setnetworkserviceenabled Ethernet on'
# T6 the app quits mid-session and opens again (persist + V2Ray proxy): the truth run is the second launch
run t6-app-restart persist "$V2" false 'true'
# T7 kill switch persist -> off while connected (CLI, app open)
run t7-cli-ks-off persist "$WG" false 'devnet-dvpn daemon set --kill-switch off --yes'
# T8 Q0534 (release blocker): persist + connected, in-app settings Apply (DNS) -> if it ends the session: internet back, pf 0
run t8-q0534-app-apply persist "$WG" false 'true' 'nav=Settings;select=DNS while connected:custom;fill=Custom DNS servers:9.9.9.9, 149.112.112.112;click=text:Apply;nav=Connect;' released
# T9 Q0534 from another process: persist + connected, CLI daemon set --dns with the app open
run t9-q0534-cli-apply persist "$WG" false 'devnet-dvpn daemon set --dns quad9 --yes' '' released
# T10 (#31 fe95792 / AND-34 blk x ks-off): persist + connected, dvpnd SIGKILL -> held view, then at +15 s kill switch
# Off + Apply (CLI): the held view must come down (Not connected) within ~5 s once the internet answers.
run t10-held-then-ks-off persist "$WG" false 'sudo -n launchctl kill SIGKILL '"$SVC"'; sleep 15; perl -MTime::HiRes=time -e '"'"'printf "KSOFF %d\n", time*1000'"'"' > "$O/ksoff.txt"; devnet-dvpn daemon set --kill-switch off --yes' '' released
c disconnect; c daemon restore-network; c daemon set --kill-switch off --yes
echo "TRANSITIONS_DONE $(date -u +%T)" >> "$LOG"
