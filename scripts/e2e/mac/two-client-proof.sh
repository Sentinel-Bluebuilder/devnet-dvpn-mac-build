#!/bin/bash
# ─── Q0184 proof: two consecutive WireGuard clients on one node; B must not be billed for A's flows ───
#   bash scripts/e2e/mac/two-client-proof.sh <wg-node-address> <label> [inherit|clean]    (runs IN the guest)
#   inherit (default): A's download is still running when A disconnects (killed just before B connects)
#   clean: A's download is stopped and drained BEFORE A disconnects, so B cannot inherit any of A's flows
# Logs A's and B's WG tunnel address and whether A's curl is alive when B connects (FWX's rc1-vs-rc2 confound).
# A connects and keeps a bulk download running until it disconnects (its flows are still alive in the node's
# conntrack); B connects straight after (same node, so the address pool hands B a recently used address),
# moves almost nothing for 90 s, and must stay up with no "node overcharging" / usage dispute from dvpnd.
# Prints one verdict line: "PASS two-client <label>" or "FAIL two-client <label> :: <why>".
set -u
NODE=${1:?wg node address}; LABEL=${2:?label}; MODE=${3:-inherit}
case $MODE in inherit|clean|a-only) ;; *) echo "mode must be inherit, clean or a-only" >&2; exit 2 ;; esac
# a-only (two-machine proof): this Mac is only client A; it disconnects at DISCONNECT_AT (UTC epoch) and keeps the
# download running 60 s past it; client B (another machine) connects to the same node right after, on the clock.
export PATH="/Applications/Devnet dVPN.app/Contents/Resources/bin:/usr/local/bin:$PATH"
export DVPN_KEYFILE=$HOME/.ddv/test-wallet.json DVPN_DATA_DIR=$HOME/ddv-data
LOG=/Library/Logs/DevnetDVPN/dvpnd.log
OUT=~/sweep/two-client-$LABEL.log; mkdir -p ~/sweep; : > "$OUT"
say() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$OUT"; }
# the WG tunnel address dvpnd gave this session (the utun that holds a 10.x/172.x/192.168 point-to-point inet)
wg_addr() { local i a; for i in $(ifconfig -l | tr ' ' '\n' | grep '^utun'); do a=$(ifconfig "$i" 2>/dev/null | awk '/inet /{print $2}' | head -1); [ -n "$a" ] && echo "$i $a"; done | tr '\n' ' '; }
say "mode $MODE"
fail() { say "FAIL two-client $LABEL :: $*"; devnet-dvpn disconnect >/dev/null 2>&1; devnet-dvpn daemon restore-network >/dev/null 2>&1; exit 1; }

# meter sampler (Q0183/Q0184): every 2 s the WG peer counters (the layer dvpnd's local meter reads), the wg-quick
# name files (which utun dvpn-wg-client points at) and the utun interface byte counters, across A -> B
WG=$(command -v wg || echo /usr/local/bin/wg); SAMP=~/sweep/two-client-$LABEL-meter.log; : > "$SAMP"
( while :; do
    { echo "=== $(date -u +%H:%M:%SZ)"; sudo -n "$WG" show all transfer 2>&1
      # /var/run/wireguard is root-only: list and read it as root (a user glob silently sees nothing)
      echo "ls $(sudo -n ls /var/run/wireguard/ 2>&1 | tr '\n' ' ')"
      sudo -n sh -c 'for n in /var/run/wireguard/*.name; do [ -e "$n" ] && echo "name $(basename "$n") -> $(cat "$n")"; done' 2>&1
      netstat -ib 2>/dev/null | awk '$1 ~ /^utun/ && $3 ~ /Link/ {print "if", $0}'
      pgrep -fl wireguard-go | sed 's/^/proc /'
      # which local address each :443 flow uses (A's old .x vs B's new .y) + tcp loss counters
      netstat -an -p tcp 2>/dev/null | awk '$5 ~ /\.443$/ {print "tcp", $4, $5, $6, "rq=" $2}'
      netstat -s -p tcp 2>/dev/null | grep -E "bytes received in sequence|retransmit|out-of-order|duplicate" | head -8 | sed 's/^/tcps /'
      netstat -s -p udp 2>/dev/null | grep -iE "full socket|datagrams received" | sed 's/^/udps /'; } >> "$SAMP" 2>&1
    sleep 2
  done ) & SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null' EXIT
say "settle the refused deposit (if any) so connect can open a fresh one"
devnet-dvpn settle run --yes >> "$OUT" 2>&1 || say "settle: nothing to settle or failed (continuing)"
sleep 7

say "client A: connect $NODE (wireguard, 1 GB unit)"
devnet-dvpn connect "$NODE" --units 1 --yes >> "$OUT" 2>&1 || fail "A connect failed"
sleep 3; say "client A tunnel: $(wg_addr)"
# bulk download: looped paced pulls of BULK_URL (speed.cloudflare.com 403s >= 100 MB and 429s repeat pulls for 1 h+)
BULK_URL=${BULK_URL:-https://ash-speed.hetzner.com/100MB.bin}
DLLOG=~/sweep/two-client-$LABEL-dl.log; : > "$DLLOG"
( end=$(( $(date -u +%s) + $([ "$MODE" = a-only ] && echo 600 || echo 60) ))
  while [ "$(date -u +%s)" -lt "$end" ]; do
    # paced at 4 MB/s (one 50 MB pull per ~12 s): unpaced pulls trip Cloudflare's 429 limit after ~7 in 20 s
    r=$(curl -s -o /dev/null -m 30 --limit-rate 4M -w "code=%{http_code} size=%{size_download}" "$BULK_URL" 2>&1)
    echo "$(date -u +%H:%M:%SZ) $r" >> "$DLLOG"
    case $r in code=200*) ;; *) sleep 5 ;; esac
  done ) & DL=$!
if [ "$MODE" = a-only ]; then
  AT=${DISCONNECT_AT:?DISCONNECT_AT=<utc epoch> for a-only}
  [ "$(date -u +%s)" -lt "$((AT - 15))" ] || fail "DISCONNECT_AT is too soon (need >= 15 s of A traffic)"
  while [ "$(date -u +%s)" -lt "$AT" ]; do sleep 1; done
  say "client A: DISCONNECT at $(date -u +%H:%M:%SZ) with the bulk download running (curl pid $DL, alive: $(kill -0 "$DL" 2>/dev/null && echo yes || echo no)); B may connect now"
  devnet-dvpn disconnect >> "$OUT" 2>&1 || fail "A disconnect failed"
  for s in 15 30 45 60; do sleep 15; say "A+${s}s: curl alive: $(pgrep -f "limit-rate 4M" >/dev/null && echo yes || echo no); tcp :443 ESTABLISHED: $(netstat -an -p tcp 2>/dev/null | grep -c '\.443 .*ESTABLISHED')"; done
  pkill -P "$DL" 2>/dev/null; kill "$DL" 2>/dev/null; wait "$DL" 2>/dev/null
  devnet-dvpn daemon restore-network >/dev/null 2>&1
  say "DONE client-A $LABEL (B's verdict is read on B's side)"; exit 0
fi
sleep 20
if [ "$MODE" = clean ]; then
  pkill -P "$DL" 2>/dev/null; kill "$DL" 2>/dev/null; wait "$DL" 2>/dev/null; sleep 5
  say "client A: download stopped and drained 5 s; curl alive: $(pgrep -f "limit-rate 4M" >/dev/null && echo yes || echo no); disconnect"
  devnet-dvpn disconnect >> "$OUT" 2>&1 || fail "A disconnect failed"
else
  say "client A: disconnect with the bulk download still running (curl pid $DL)"
  devnet-dvpn disconnect >> "$OUT" 2>&1 || fail "A disconnect failed"
  pkill -P "$DL" 2>/dev/null; kill "$DL" 2>/dev/null; wait "$DL" 2>/dev/null
fi
say "before B: curl alive: $(pgrep -f "limit-rate 4M" >/dev/null && echo yes || echo no); tcp :443 ESTABLISHED: $(netstat -an -p tcp 2>/dev/null | grep -c '\.443 .*ESTABLISHED')"

# the log is root-only: count it as root (a `sudo wc < file` redirect runs as the user, gives "", scans the whole log)
START=$(sudo -n wc -l "$LOG" | awk '{print $1}')
[ -n "$START" ] || fail "could not read $LOG as root"
say "client B: connect $NODE straight after A"
devnet-dvpn connect "$NODE" --units 1 --yes >> "$OUT" 2>&1 || fail "B connect failed: $(tail -2 "$OUT" | tr '\n' ' ')"
sleep 2; say "client B tunnel: $(wg_addr)"
for i in 1 2 3 4 5 6; do
  sleep 15
  curl -s -m 8 https://api.ipify.org >/dev/null
  devnet-dvpn status 2>&1 | grep -q '^Session *Not connected' && fail "B session ended after $((i * 15)) s"
done
NEW=$(sudo -n tail -n +"$((START + 1))" "$LOG" | grep -v grpc.component)
printf '%s\n' "$NEW" | grep -E 'overcharg|usage dispute|exceeds local usage' >> "$OUT"
if printf '%s\n' "$NEW" | grep -qE 'overcharg|usage dispute|exceeds local usage'; then
  fail "dvpnd disputed B's usage: $(printf '%s\n' "$NEW" | grep -oE '"error":"[^"]{0,160}' | head -1)"
fi
devnet-dvpn sessions >> "$OUT" 2>&1
devnet-dvpn disconnect >> "$OUT" 2>&1
devnet-dvpn daemon restore-network >/dev/null 2>&1
say "PASS two-client $LABEL"
