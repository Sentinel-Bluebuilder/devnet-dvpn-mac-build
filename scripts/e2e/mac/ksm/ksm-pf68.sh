#!/bin/bash
# final6.8 proof cells (guest, run DETACHED; the kill switch here can cut SSH).
#  Q0538: kill switch (on + persist) + APP include/exclude split on WireGuard -> pf loads, connect works, no fail-open.
#  Q0539 (DIR): persist + connected, kill the protocol process (block kept), connect to a node that fails -> stays blocked.
# Each try: x3. Results: ~/ksm/out/pf68/cells.tsv (+ run.log). allow_lan=true keeps the guest's SSH reachable.
set -u
export DVPN_KEYFILE=$HOME/ksm/ksm-wallet.json DVPN_DATA_DIR=$HOME/ksm/profile PATH=/usr/local/bin:$PATH
WG=85UXF7JoeojwCe3vBEQsu8A3iBhqtggi1n828Lq84K3q
DOWN=Kg96W7ScKBycWHjDyoTPxeQZTv7ry15P7Ug663rC7yf   # WireGuard node listed "down (Node is not reachable)" on 11-12
DIRECT=${DIRECT_IP:-104.196.36.139}
FF=/Applications/Firefox.app/Contents/MacOS/firefox
O=$HOME/ksm/out/pf68; mkdir -p "$O"; LOG=$O/run.log; TSV=$O/cells.tsv
printf 'cell\ttry\tconnect_exit\tpf_rules\tegress\tsession\tverdict\tnote\n' > "$TSV"
c() { echo "> $*" >> "$LOG"; devnet-dvpn "$@" >> "$LOG" 2>&1; }
pfn() { sudo -n pfctl -a sentinel-dvpn-c0 -sr 2>/dev/null | grep -cE '^(block|pass)'; }
egr() { curl -s -m 4 https://api.ipify.org || echo FAIL; }
hold() { sudo -n touch /var/run/ddv-deadman.hold; }
reset() { c disconnect; c daemon restore-network
  c daemon set --kill-switch off --split-mode off --split-apps none --allow-lan true --dns cloudflare --whole-device false --yes; }
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$TSV"; }

q0538() { # <ks on|persist> <split include|exclude> <try>
  local ks=$1 mode=$2 n=$3 cell="q0538-$1-$2"
  echo "#### $(date -u +%T) $cell try $n" >> "$LOG"; reset; hold
  c daemon set --split-mode "$mode" --split-apps "$FF" --kill-switch "$ks" --yes
  local out; out=$(devnet-dvpn connect "$WG" --basis per_gb --yes 2>&1); local rc=$?; echo "$out" >> "$LOG"; sleep 6; hold
  local pf; pf=$(pfn); local e; e=$(egr); local st; st=$(devnet-dvpn status 2>&1 | head -3 | tr '\n' ' ' | cut -c1-120)
  sudo -n grep -c "syntax error" /Library/Logs/DevnetDVPN/dvpnd.log > "$O/syntax-count.$cell.$n" 2>/dev/null
  # curl is not a chosen app: include -> it goes direct by design (pf must still be loaded); exclude -> it goes through the VPN.
  local v=PASS note=""
  [ "$rc" -eq 0 ] || { v=FAIL; note="connect failed: $(echo "$out" | grep -m1 '^Error' | cut -c1-100)"; }
  [ "$pf" -gt 0 ] || { v=FAIL; note="$note pf not loaded (fail-open)"; }
  [ "$mode" = exclude ] && [ "$e" = "$DIRECT" ] && { v=FAIL; note="$note exclude split: curl left direct"; }
  row "$cell" "$n" "$rc" "$pf" "$e" "$st" "$v" "$note"
  c disconnect; sleep 7
}

q0539() { # <try>
  local n=$1 cell=q0539-held-block-failed-connect
  echo "#### $(date -u +%T) $cell try $n" >> "$LOG"; reset; hold
  c daemon set --kill-switch persist --yes
  c connect "$WG" --basis per_gb --yes; sleep 6; hold
  # Kill the WireGuard userspace process: an unexpected end, so persist must keep the block.
  local wp; wp=$(pgrep -f 'wireguard-go' | head -1); echo "killing wireguard-go pid=${wp:-none}" >> "$LOG"
  [ -n "$wp" ] && sudo -n kill -9 "$wp"; sleep 12; hold
  local pf1; pf1=$(pfn); local e1; e1=$(egr)
  local held=yes; { [ "$pf1" -gt 0 ] && [ "$e1" = FAIL ]; } || held=no
  local out; out=$(devnet-dvpn connect "$DOWN" --basis per_gb --yes 2>&1); local rc=$?; echo "$out" >> "$LOG"; sleep 4; hold
  local pf2; pf2=$(pfn); local e2; e2=$(egr); local st; st=$(devnet-dvpn status 2>&1 | head -3 | tr '\n' ' ' | cut -c1-120)
  local v=PASS note="before: pf=$pf1 egress=$e1 held=$held; connect-to-down exit=$rc"
  [ "$held" = yes ] || { v=SETUP; note="$note (block not held after the kill: cell not exercised)"; }
  [ "$rc" -ne 0 ] || note="$note (the down node connected?)"
  if [ "$held" = yes ] && { [ "$pf2" -eq 0 ] || [ "$e2" != FAIL ]; }; then v=FAIL; note="$note -> block LOST after the failed connect"; fi
  row "$cell" "$n" "$rc" "$pf2" "$e2" "$st" "$v" "$note"
  sleep 7
}

for n in 1 2 3; do
  q0538 on include "$n"; q0538 persist include "$n"; q0538 persist exclude "$n"
  q0539 "$n"
done
reset; c daemon set --kill-switch off --yes
echo PF68_DONE >> "$LOG"
