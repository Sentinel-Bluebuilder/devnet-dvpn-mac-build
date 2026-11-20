#!/bin/bash
# Guest chain (detached): CLI grid done -> RC rebuild from the new bundle -> upgrade -> transitions -> UI grid.
set -u
L=$HOME/ksm/out/chain.log
say() { echo "$(date -u +%T) $*" >> "$L"; }
say "waiting for the CLI grid (restarted chain: grid already done skips straight through)"
until grep -q GRID_DONE ~/ksm/out/ksm13-r1/cli.log 2>/dev/null; do sleep 30; done
say "CLI grid done; building from /tmp/mac33h.bundle"
cd ~/rc-030 && git checkout -q -- . && git pull -q /tmp/mac33h.bundle main && say "at $(git log --oneline -1 | cut -c1-12)"
./build2.sh > build8.log 2>&1
grep -q ALL_DONE build8.log || { say "BUILD FAILED, stopping"; exit 1; }
say "built: $(grep x64.dmg dist/SHA256SUMS.txt | cut -c1-16)"
grep -q "final6.8" build8.log || say "WARNING: build log does not name final6.8"
export DVPN_KEYFILE=$HOME/ksm/ksm-wallet.json DVPN_DATA_DIR=$HOME/ksm/profile
/usr/local/bin/devnet-dvpn disconnect >> "$L" 2>&1; pkill -x "Devnet dVPN"
M=$(hdiutil attach -nobrowse -readonly ~/rc-030/dist/Devnet-dVPN-0.3.0-rc.1-x64.dmg | tail -1 | cut -f3-)
sudo -n rm -rf "/Applications/Devnet dVPN.app" && sudo -n ditto "$M/Devnet dVPN.app" "/Applications/Devnet dVPN.app"; hdiutil detach -quiet "$M"
/usr/local/bin/devnet-dvpn daemon install --yes >> "$L" 2>&1; sleep 5
say "upgraded: $(/usr/local/bin/devnet-dvpn status 2>&1 | grep Daemon)"
say "final6.8 proof cells (Q0538 x3, Q0539 x3)"; bash ~/ksm/ksm-pf68.sh; say "pf68 done: $(tail -n +2 ~/ksm/out/pf68/cells.tsv | awk -F'\t' '{n[$7]++} END{for(k in n) printf "%s=%d ", k, n[k]}')"
say "repeat V2Ray-node reconnects x3"; bash ~/ksm/repeat-v2.sh; say "repeat done: $(tail -n +2 ~/ksm/out/repeat-v2/repeat.tsv | awk -F'\t' '{n[$3==0?"ok":"fail"]++} END{for(k in n) printf "%s=%d ", k, n[k]}')"
say "transitions start"; bash ~/ksm/transitions.sh r1; say "transitions done"
say "UI grid start"; ARM=ui bash ~/ksm/ksm13-ui.sh r1; say "UI grid done"
echo CHAIN_DONE >> "$L"
