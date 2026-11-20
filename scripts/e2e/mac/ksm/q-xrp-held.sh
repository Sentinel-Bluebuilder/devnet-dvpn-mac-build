#!/bin/bash
# Regression for #31 ddc4bc8 (Agent M grid r1, xrp x ks_persist): an Xray PROXY session under kill switch persist,
# then a second CLI connect. The daemon's answer "Disconnect the current session first" must reach the user; never
# the Q0540 "kill switch is still blocking ... press Restore network" (that advice would lift the block under a
# live session). Usage: bash q-xrp-held.sh <out dir> [runs]
set -u
O=$1; N=${2:-3}; rm -rf "$O"; mkdir -p "$O"
export DVPN_KEYFILE=$HOME/ksm/ksm-wallet.json DVPN_DATA_DIR=$HOME/ksm/profile PATH=/usr/local/bin:$PATH
XR=E9RG1iZJjsLfEuLfDYTHM4yXCjyFE21jBbJLFvGoL2FD
APPLOG=$DVPN_DATA_DIR/logs/app.log
LOG=$O/run.log
v=PASS
for r in $(seq 1 "$N"); do
  echo "##### run $r $(date -u +%T)" >> "$LOG"
  devnet-dvpn disconnect >> "$LOG" 2>&1; devnet-dvpn daemon restore-network >> "$LOG" 2>&1
  devnet-dvpn daemon set --kill-switch persist --split-mode off --split-apps none --allow-lan true --dns cloudflare --whole-device false --yes >> "$LOG" 2>&1
  devnet-dvpn connect "$XR" --basis per_gb --yes >> "$LOG" 2>&1; ce=$?; sleep 8
  st=$(devnet-dvpn status 2>&1 | grep -E '^ *(Session|Connection|State)' | head -2 | tr '\n' ' ')
  M=$(wc -l < "$APPLOG")
  out=$(devnet-dvpn connect "$XR" --basis per_gb --yes 2>&1); e2=$?
  echo "$out" >> "$LOG"
  new=$(tail -n +$((M + 1)) "$APPLOG")
  echo "$new" | sed -E 's/api-key=[^"& ]+/api-key=REDACTED/g' > "$O/app-run$r.log"
  rv=PASS; why=""
  [ "$ce" = 0 ] || { rv=FAIL; why="$why first connect exit=$ce;"; }
  echo "$out" | grep -q 'Disconnect the current session first' || { rv=FAIL; why="$why daemon words not shown;"; }
  echo "$out" | grep -qi 'Restore network' && { rv=FAIL; why="$why Restore network advised;"; }
  echo "$new" | grep -qE 'kill-switch-held|"restoreNetwork":true' && { rv=FAIL; why="$why app screen offers Restore network;"; }
  devnet-dvpn status 2>&1 | grep -q 'Protected' || { rv=FAIL; why="$why session not kept;"; }
  printf 'run%s\t%s\tfirst=%s second=%s\t%s\t%s\n' "$r" "$rv" "$ce" "$e2" "$st" "$why" >> "$O/result.txt"
  [ "$rv" = PASS ] || v=FAIL
  devnet-dvpn disconnect >> "$LOG" 2>&1; devnet-dvpn daemon restore-network >> "$LOG" 2>&1; sleep 7
done
devnet-dvpn daemon set --kill-switch off --yes >> "$LOG" 2>&1
echo "VERDICT $v" >> "$O/result.txt"
