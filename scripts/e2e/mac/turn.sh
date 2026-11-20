#!/usr/bin/env bash
# ─── One node turn: matrix cases in order, 60 s apart, inside a fixed time box ───
#   bash scripts/e2e/mac/turn.sh <minutes> <case> [case…]
#   e.g. bash scripts/e2e/mac/turn.sh 90 ks-on ks-persist ks-rpcdown udpblock tcp443 lan
# A case is never started in the last 15 minutes of the box (cases are not cut mid-run, and the
# node must be released on time). Prints one line per case and a summary; matrix.sh writes the
# evidence. Cases not started are listed so they go first in the next turn.
set -uo pipefail
MIN=${1:?minutes}; shift
[ "$#" -gt 0 ] || { echo 'turn: no cases given' >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"
# Preflight: a guest without its VPN drivers voids every WireGuard/AmneziaWG/OpenVPN cell (10-24).
MAC=${MAC:-ddv-mac}
miss=$(ssh "$MAC" 'PATH="/Applications/Devnet dVPN.app/Contents/Resources/bin:$PATH" devnet-dvpn daemon drivers 2>&1' | grep '^miss' || true)
[ -z "$miss" ] || { echo "turn: drivers missing on $MAC, not starting:"; echo "$miss"; exit 3; }
start=$(date +%s); stop_new=$(( start + (MIN - 15) * 60 ))
done_list=(); skipped=()
echo "turn start $(date -u +%H:%M:%SZ), box ${MIN} min, last case start by $(date -u -d "@$stop_new" +%H:%MZ)"
first=1
for c in "$@"; do
  if [ "$(date +%s)" -ge "$stop_new" ]; then skipped+=("$c"); continue; fi
  [ "$first" = 1 ] || sleep "${PACE_SUITE:-60}" # 60 s between suites
  first=0
  t0=$(date +%s)
  bash "$here/matrix.sh" "$c"; rc=$?
  echo "turn case $c rc=$rc $(( ($(date +%s) - t0) / 60 )) min"
  done_list+=("$c:rc$rc")
done
echo "turn end $(date -u +%H:%M:%SZ) ($(( ($(date +%s) - start) / 60 )) min) ran: ${done_list[*]:-none} not started: ${skipped[*]:-none}"
