#!/bin/bash
# ─── Every feature × every protocol on the macOS guest, driven from the laptop ───
#   bash scripts/e2e/mac/matrix.sh <case|all> [protocols…]
# The checks run IN the guest (matrix-steps.sh + lib.sh, four oracles). This driver only orders
# the steps and injects faults on the GCP host (ddv-faultctl: iptables on QEMU's traffic, QMP
# link / pause), because inside the guest dvpnd's pf anchor must stay the first rule.
# Results: guest ~/matrix/<case>.tsv + .log, pulled to docs/evidence/mac/matrix/, then
# matrix.json (scripts/e2e/mac/matrix-json.mjs).
# Kill-switch cases keep "allow LAN" on so this driver's SSH (via 10.0.2.2) stays up; the
# LAN-off case runs detached. Chain transactions are sequential, 7 s apart.
#
# case          A-rows        what
# pay-gb        A1 A8 A25     per GB, egress, live stats, own IP back
# pay-hour      A2            per hour
# adopt         A5            new process adopts; service restart keeps control
# coverage      A6 A23        coverage honest (device / proxy-only / proxy-apps); system proxy on/off exact
# whole         A7            curl, NSURLSession (nscurl), Python all exit at the node
# switch        A9            --switch to each other protocol
# ks-switch     A9 gap#67     --switch with the kill switch on: 0 direct egress samples
# topup         A10           channels fund mid-session
# ks-on         A11 A13 A14   path lost, service restart, SIGKILL, protocol killed
# ks-persist    A12           same + block kept after disconnect until restore
# dns           A15–A17       resolver, no clear lookups on the NIC (+ positive control), < 3 s
# lan           A18           LAN off blocks 10.0.2.2, LAN on live
# split-app     A20           curl chosen, python3 direct
# split-route   A21           include / exclude ipify
# split-ks      A22           split + kill switch
# reconnect     A28           node unreachable 75 s
# flap          A28           NIC unplugged 15 s
# pause         A28           VM paused 60 s (sleep)
# throughput    A24           100 MB, 1280-byte DF ping through the tunnel
# close         A26           copy for user stop and service stop
# ks-connfail   A11 edge      kill switch on + a server that does not exist: refused, nothing armed, nothing paid (once)
# ks-nodedown   A11 edge      kill switch on + server unreachable before connect: plain failure, block released
# ks-exhausted  Q0353         kill switch on + path lost until dvpnd gives up reconnecting: the block stays (fail closed),
#                             also after the node is reachable again, until Restore network
# ks-rpcdown    A11 edge      kill switch on + RPC names unresolvable 60 s: tunnel carries on
# safety-drivers F1 F17      a service tool removed: drivers says so, repair-drivers restores it, AWG works (once)
# safety-armed  A12 safety    uninstall while "Always" holds the block: network fully back, reinstall works (once)
# crash         A29           dvpnd + protocol process SIGKILLed together: leftovers cleaned
# keepalive     CF6           WG/AWG idle 5 min mid-session, then the first request goes via the node
# wipe          T13           no session config or tunnel secret left in dvpnd home after disconnect
# rival         D6            a foreign WireGuard utun owns 0/1+128/1: connect works or refuses plainly; its routes untouched
# loss5 loss20 lat300 bw1m  edge  host netem on the guest's path: connect + egress + 1 MB download, or a plain timely refusal
# mtu1280       edge          guest NIC MTU 1280 for the session
# udpblock tcp443  edge       UDP dropped / only TCP 443: Connected must carry traffic, else refuse plainly < 90 s
# proxy-crash   T10 T11       crash mid-session: every service gets the user's OWN SOCKS + PAC back
# test          A30           test run on each node
# money         A27           settle run + withdraw, wallet before/after (once)
# plan-a3a4    A3 A4         plan subscription, connect --plan (3 wallets x 2 protocols; DIR Q0277)
# Not here: A19 IPv6 (needs a dual-stack host), A31 logos (GUI)
set -u
# Run from a private copy: bash reads a script as it executes, so editing this file under a
# running driver made the driver read shifted bytes.
if [ -z "${DDV_MATRIX_COPY:-}" ]; then
  REPO=$(cd "$(dirname "$0")/../../.." && pwd); COPY=$(mktemp "${TMPDIR:-/tmp}/ddv-matrix.XXXXXX")
  cp "$0" "$COPY"; cd "$REPO"; DDV_MATRIX_COPY=1 exec bash "$COPY" "$@"
fi
[ -n "${REPO:-}" ] || REPO=$(pwd)
cd "$REPO"
ALL_CASES="pay-gb pay-hour adopt coverage whole switch ks-switch topup ks-on ks-persist ks-connfail ks-nodedown ks-exhausted ks-deposit-out ks-rpcdown safety-drivers safety-armed dns lan split-app split-route split-ks throughput slowread close reconnect flap pause crash keepalive wipe rival proxy-crash loss5 loss20 lat300 bw1m mtu1280 mtu-blackhole checking-label dns-forwarder udpblocktcp443 sdyn-toggle sdyn-switch-proxy sdyn-switch-full sdyn-user-change sdyn-user-pac sdyn-svc-restart sdyn-browser sdyn-port-taken sdyn-races sdyn-nodedown test money"
# split-dyn cases are about the SOCKS system proxy: V2Ray/Xray only
# (a function: bash 3.2 on macOS cannot parse a case inside $(...))
proxy_protos() { local x; for x in $PROTOS; do case $x in v2ray|xray) printf '%s ' "$x" ;; esac; done; }
PROXY_CASES="sdyn-toggle sdyn-switch-proxy sdyn-switch-full sdyn-user-change sdyn-user-pac sdyn-svc-restart sdyn-browser sdyn-port-taken sdyn-races sdyn-nodedown"
# cases that run once, not per protocol
ONCE="money topup zero-byte-conf ks-connfail safety-drivers safety-armed double-settle settle-stop disc-2nd rpc-nonsolana switch-comingup basis-override proxy-orphan" # topup: channel billing, protocol-independent (#34 review)
ALL_PROTOCOLS="wireguard amneziawg openvpn hysteria2 v2ray xray"
# host faults must hit the node the guest uses: take NODE_IP from the guest's ~/matrix/nodes.env when not given
[ -z "${NODE_IP:-}" ] && NODE_IP=$(ssh -o BatchMode=yes "${MAC:-ddv-mac}" 'sed -n "s/^NODE_IP=//p" ~/matrix/nodes.env 2>/dev/null' 2>/dev/null)
NODE_IP=${NODE_IP:-35.238.250.188} # default node-3; RC2 / SOLO node = ~/matrix/nodes.env in the guest (solo-nodes.sh on)
STEPS=scripts/e2e/mac/matrix-steps.sh
EVID=docs/evidence/mac/${EVID_NAME:-matrix}
# Which rig: MAC = the guest ssh alias, MHOST = its GCP host (second rig: MAC=ddv-mac-2 MHOST=ddv-mac-host-2)
MAC=${MAC:-ddv-mac-dv}; MHOST=${MHOST:-ddv-mac-host-dv}
WHAT=${1:?case|all}; shift
PROTOS=${*:-$ALL_PROTOCOLS}
[ "$WHAT" = all ] && CASES=$ALL_CASES || CASES=$WHAT

G() { ssh -o ServerAliveInterval=10 -o ServerAliveCountMax=6 "$MAC" "cd ~/devnet-dvpn-mac && bash $STEPS $*"; }
GD() { # <secs> <args…>: a step that cuts the rig link — start it detached, wait it out
  local s=$1; shift
  ssh "$MAC" "cd ~/devnet-dvpn-mac && nohup bash $STEPS $* > /dev/null 2>&1 < /dev/null &"
  sleep "$s"
  until ssh -o ConnectTimeout=8 "$MAC" true 2>/dev/null; do sleep 10; done
}
H() { ssh "$MHOST" "sudo -n /usr/local/sbin/ddv-faultctl $*"; }
# HDNS start|read,<label>|stop: count DNS (udp/tcp port 53) the QEMU process sends from the host, any interface
# (its slirp resolver included). read writes the count since the last read to the guest's ~/matrix/hostdns.<label>.
HDNS() {
  local q="-m owner --uid-owner \$(id -u \${QEMU_USER:-ubuntu}) -m comment --comment ddv-dnscount"
  case $1 in
    start) ssh "$MHOST" "sudo -n iptables -N DDVDNSCNT 2>/dev/null; sudo -n iptables -F DDVDNSCNT; sudo -n iptables -C OUTPUT -j DDVDNSCNT 2>/dev/null || sudo -n iptables -I OUTPUT 1 -j DDVDNSCNT; sudo -n iptables -A DDVDNSCNT -p udp --dport 53 $q; sudo -n iptables -A DDVDNSCNT -p tcp --dport 53 $q; sudo -n iptables -Z DDVDNSCNT" ;;
    read,*) local n; n=$(ssh "$MHOST" "sudo -n iptables -L DDVDNSCNT -vnx | awk '/ddv-dnscount/{s+=\$1} END{print s+0}'; sudo -n iptables -Z DDVDNSCNT" | head -1)
      ssh "$MAC" "echo ${n:-unknown} > ~/matrix/hostdns.${1#read,}" ;;
    stop) ssh "$MHOST" "sudo -n iptables -D OUTPUT -j DDVDNSCNT 2>/dev/null; sudo -n iptables -F DDVDNSCNT 2>/dev/null; sudo -n iptables -X DDVDNSCNT 2>/dev/null; true" ;;
  esac
}

# the steps of each case (g = guest step, h = host fault, w = wait, d = detached guest step)
steps_of() {
  case $1 in
    ks-on|ks-persist) echo 'g:a h:block,NODE,40 w:2 g:lost w:40 g:restart g:kill g:proto g:close' ;;
    reconnect) echo 'g:a h:block,NODE,75 w:120 g:b' ;;
    flap) echo 'g:a h:link,15 w:45 g:b' ;;
    pause) echo 'g:a h:pause,30 w:60 g:b' ;; # 60 s freezes panicked macOS on KVM (TLB flush timeout, rig 2 r3)
    lan) echo 'd:run,150' ;;
    ks-nodedown) echo 'g:a h:block,NODE,150 w:3 g:b' ;;
    ks-exhausted) echo 'g:a h:block,NODE,600 w:2 g:exhaust h:clear w:10 g:after g:close' ;; # Q0353
    ks-deposit-out) echo 'g:run' ;; # DIR 10-29 (FLX2: RC3 Linux lifts the KS when a session ends by itself)
    loss5) echo 'h:netem,5,0,0,400 w:2 g:run h:clear' ;;
    loss20) echo 'h:netem,20,0,0,400 w:2 g:run h:clear' ;;
    lat300) echo 'h:netem,0,300,0,400 w:2 g:run h:clear' ;;
    bw1m) echo 'h:netem,0,0,1000,400 w:2 g:run h:clear' ;;
    mtu-blackhole) echo 'h:bigudp,NODE,900 w:2 g:run h:clear' ;; # Q0357
    checking-label) echo 'h:netem,0,600,0,900 w:2 g:run h:clear' ;; # Q0357 UI: gate > the app's 1 s poll
    dns-forwarder) echo 'g:a c:start w:20 c:read,quiet g:b c:read,session g:c c:read,control g:e1 c:read,kspre g:e2 c:read,ksoff g:e3 c:stop g:d' ;; # Q0365
    udpblock) echo 'h:udp,300 w:2 g:run h:clear' ;;
    tcp443) echo 'h:tcp443,300 w:2 g:run h:clear' ;;
    sdyn-nodedown) echo 'g:a h:block,NODE,150 w:120 g:b' ;;
    *) echo 'g:run' ;;
  esac
}

# One driver per guest. A driver whose wrapper was killed kept running and connected/disconnected
# into a second run on the same guest (run 2/3: "Disconnect the current session first", sessions
# closed under the other driver). The lock holds this driver's host + pid; a stale one names it.
LOCK_ID="$(hostname)/$$"
if ! ssh "$MAC" "mkdir ~/matrix-driver.lock 2>/dev/null && echo '$LOCK_ID' > ~/matrix-driver.lock/owner"; then
  echo "another matrix driver holds $MAC: $(ssh "$MAC" 'cat ~/matrix-driver.lock/owner' 2>/dev/null) — stop it (or rm -r ~/matrix-driver.lock on the guest if it is dead)" >&2
  exit 3
fi
trap 'ssh "$MAC" "grep -qx \"$LOCK_ID\" ~/matrix-driver.lock/owner 2>/dev/null && rm -r ~/matrix-driver.lock"' EXIT
scp -q scripts/e2e/mac/lib.sh scripts/e2e/mac/matrix-steps.sh "$MAC":devnet-dvpn-mac/scripts/e2e/mac/
H clear >/dev/null
# an earlier cell cut mid-way can leave the service unloaded; start every run from a running service, said out loud
ssh "$MAC" 'export PATH="/Applications/Devnet dVPN.app/Contents/Resources/bin:/usr/local/bin:$PATH" DVPN_KEYFILE=$HOME/.ddv/test-wallet.json DVPN_DATA_DIR=$HOME/ddv-data
devnet-dvpn status 2>&1 | grep -q "^Daemon *running" && exit 0
echo "info [-] VPN service was down before this run; restore-network + daemon install"
devnet-dvpn daemon restore-network >/dev/null 2>&1 || echo "info [-] restore-network failed (continuing)"
o=$(devnet-dvpn daemon install --yes 2>&1); echo "info [-] $(echo "$o" | tail -1)"
for i in $(seq 1 30); do devnet-dvpn status 2>&1 | grep -q "^Daemon *running" && exit 0; sleep 2; done
echo "FAIL [-] VPN service still not running 60 s after daemon install :: $(echo "$o" | tail -3 | tr "\n" " ") $(sudo -n launchctl print system/network.sentinel.devnet-dvpn.dvpnd 2>&1 | grep -E "state|last exit" | tr "\n" " ")"
exit 1' || { echo "matrix: VPN service would not stay up; cases not run" >&2; exit 4; }
G env
for c in $CASES; do
  echo "═══ $c ═══"
  G "$c" - reset
  G "$c" - defaults
  ps=$PROTOS; case " $ONCE " in *" $c "*) ps=all ;; esac
  case " $PROXY_CASES " in *" $c "*) ps=$(proxy_protos) ;; esac
  for p in $ps; do
    G "$c" "$p" begin; lost=''
    for s in $(steps_of "$c"); do
      kind=${s%%:*}; arg=${s#*:}
      case $kind in
        # ssh 255 = the step never reached the guest (a fault cut the link): a red, never a silent pass
        g) G "$c" "$p" "$arg"; [ $? = 255 ] && lost="$lost $arg" ;;
        d) GD "${arg#*,}" "$c" "$p" "${arg%%,*}" ;;
        h) H "$(echo "$arg" | tr ',' ' ' | sed "s/NODE/$NODE_IP/")" ;;
        c) HDNS "$arg" ;;
        w) sleep "$arg" ;;
      esac
    done
    for l in $lost; do G "$c" "$p" "lost-$l"; done # recorded once the fault is cleared
    G "$c" "$p" end
  done
  G "$c" - summary
  sleep "${PACE_SUITE:-60}" # between suites
done
H clear >/dev/null
mkdir -p "$EVID"
scp -q "$MAC:matrix/*.tsv" "$MAC:matrix/*.log" "$EVID/"
node scripts/e2e/mac/matrix-json.mjs "$EVID"
