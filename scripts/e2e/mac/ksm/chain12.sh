#!/bin/bash
# Guest chain 12 (detached): rc.2 respin (window guard). One build (full install) + a dark smoke; the KS reboot proof
# runs after it from the laptop (it reboots the guest). Usage: BUNDLE=/tmp/<bundle> FINAL=final6.16 bash chain12.sh
set -u
L=$HOME/ksm/out/chain.log
say() { echo "$(date -u +%T) $*" >> "$L"; }
: "${BUNDLE:?BUNDLE=}" "${FINAL:?FINAL=}"
BUNDLE=$BUNDLE FINAL=$FINAL bash ~/ksm/chain3.sh
tail -1 "$L" | grep -q CHAIN3_DONE || { say "chain12: rebuild did not finish, stopping"; exit 1; }
BUILD=$(cd ~/rc-030 && git log --oneline -1 | cut -c1-9)
export DVPN_KEYFILE=$HOME/ksm/ksm-wallet.json DVPN_DATA_DIR=$HOME/ksm/profile
say "smoke dark on $BUILD"; UI_TIMEOUT=300 bash ~/rc-030/scripts/e2e/mac/ui-smoke.sh dark ~/ksm/out/smoke-$BUILD-dark > ~/ksm/out/smoke-$BUILD-dark.log 2>&1
say "smoke dark: $(grep -c '^click screen' ~/ksm/out/smoke-$BUILD-dark.log) screens; $(grep -E '^exit=|^errors.json' ~/ksm/out/smoke-$BUILD-dark.log | tr '\n' ' ' | cut -c1-200)"
echo CHAIN12_DONE >> "$L"
