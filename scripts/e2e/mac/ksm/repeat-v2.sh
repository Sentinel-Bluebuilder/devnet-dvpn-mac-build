#!/bin/bash
# Repeat the two V2Ray-node reconnect FAILs from KSM13 r1 three times each (DIR: x3 before calling them app bugs).
# v2p ks_off: V2Ray proxy, kill switch on -> off, reconnect. v2p dns: V2Ray proxy, DNS change, reconnect.
set -u
export DVPN_KEYFILE=$HOME/ksm/ksm-wallet.json DVPN_DATA_DIR=$HOME/ksm/profile PATH=/usr/local/bin:$PATH
V2=Di5V9K2Vt5uptJUk7oVVnkDRXt9qWy5HhLbkEJMxEuM2
O=$HOME/ksm/out/repeat-v2; mkdir -p "$O"; LOG=$O/run.log; TSV=$O/repeat.tsv
printf 'cell\ttry\tconnect_exit\tsecs\terror\n' > "$TSV"
c() { echo "> $*" >> "$LOG"; devnet-dvpn "$@" >> "$LOG" 2>&1; }
try() { # <cell> <n> <change...>
  local cell=$1 n=$2; shift 2
  echo "#### $(date -u +%T) $cell try $n" >> "$LOG"
  c disconnect; c daemon restore-network
  c daemon set --kill-switch on --split-mode off --split-apps none --allow-lan true --dns cloudflare --whole-device false --yes
  c connect "$V2" --basis per_gb --yes; sleep 5
  c daemon set "$@" --yes
  c disconnect; sleep 7
  local t0; t0=$(date +%s)
  local out; out=$(devnet-dvpn connect "$V2" --basis per_gb --yes 2>&1); local rc=$?
  echo "$out" >> "$LOG"
  printf '%s\t%s\t%s\t%s\t%s\n' "$cell" "$n" "$rc" "$(( $(date +%s) - t0 ))" "$(echo "$out" | grep -m1 '^Error' | cut -c1-160)" >> "$TSV"
  sudo -n touch /var/run/ddv-deadman.hold
  sleep 7
}
for n in 1 2 3; do
  try v2p-ks_off "$n" --kill-switch off
  try v2p-dns "$n" --dns quad9
done
c disconnect; c daemon restore-network; c daemon set --kill-switch off --dns cloudflare --yes
echo REPEAT_DONE >> "$LOG"
