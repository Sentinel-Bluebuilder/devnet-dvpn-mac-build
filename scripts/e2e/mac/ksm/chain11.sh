#!/bin/bash
# Guest chain 11 (detached): the switch-fix proof (DIR 11-13: switching servers under the kill switch is RC-blocking).
# One build (full install), then Q0549 CELLS=switch (WG->WG and WG->V2Ray server switch under persist) and a quick
# smoke. Usage: BUNDLE=/tmp/<bundle> FINAL=final6.1x bash chain11.sh
set -u
L=$HOME/ksm/out/chain.log
say() { echo "$(date -u +%T) $*" >> "$L"; }
: "${BUNDLE:?BUNDLE=}" "${FINAL:?FINAL=}"
BUNDLE=$BUNDLE FINAL=$FINAL bash ~/ksm/chain3.sh
tail -1 "$L" | grep -q CHAIN3_DONE || { say "chain11: rebuild did not finish, stopping"; exit 1; }
BUILD=$(cd ~/rc-030 && git log --oneline -1 | cut -c1-9)
say "q0549 switch on $BUILD ($FINAL)"; CELLS=${CELLS:-switch} bash ~/ksm/q0549.sh ~/ksm/out/q0549-switch-$BUILD
say "q0549 switch: $(tail -n +2 ~/ksm/out/q0549-switch-$BUILD/cells.tsv | awk -F'\t' '{printf "%s=%s ", $1, $NF}')"
say "dvpnd redial after move: $(sudo -n grep -E "chain RPC connections redialled after the kill switch moved" /Library/Logs/DevnetDVPN/dvpnd.log | tail -3 | grep -oE "\"closed\":[0-9]+" | tr "
" " ")"
export DVPN_KEYFILE=$HOME/ksm/ksm-wallet.json DVPN_DATA_DIR=$HOME/ksm/profile
say "smoke dark on $BUILD"; UI_TIMEOUT=300 bash ~/rc-030/scripts/e2e/mac/ui-smoke.sh dark ~/ksm/out/smoke-$BUILD-dark > ~/ksm/out/smoke-$BUILD-dark.log 2>&1
say "smoke dark: $(grep -c '^click screen' ~/ksm/out/smoke-$BUILD-dark.log) screens; $(grep -E '^exit=|^errors.json' ~/ksm/out/smoke-$BUILD-dark.log | tr '\n' ' ' | cut -c1-200)"
echo CHAIN11_DONE >> "$L"
