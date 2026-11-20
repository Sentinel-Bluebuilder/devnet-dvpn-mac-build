#!/bin/bash
# ─── cellrun adapter for prompt-proof.sh: feeds the guest login password on stdin, prints one verdict line ───
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
EV=${TMPDIR:-/tmp}/ddv-prompt-proof; mkdir -p "$EV"
PWF=$HOME/memory/ddv-vm-wallets/ddv-mac-1-guest-login.txt
[ -f "$PWF" ] || { echo "FAIL prompt-proof (no $PWF)"; exit 1; }
OUT=$(awk -F': ' 'NR==2{print $2}' "$PWF" | bash "$HERE/prompt-proof.sh" "$EV" 2>&1); RC=$?
printf '%s\n' "$OUT" | tail -30
if [ $RC -eq 0 ] && ! printf '%s\n' "$OUT" | grep -qE '^FAIL|failed +[1-9]'; then echo "PASS prompt-proof"; else echo "FAIL prompt-proof (exit $RC)"; exit 1; fi
