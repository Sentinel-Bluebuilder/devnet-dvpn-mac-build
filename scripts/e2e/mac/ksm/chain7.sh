#!/bin/bash
# Guest chain 7 (detached): the final RC step on fork final6.11 (DIR). Waits for chain 6 (6.10 RC evidence + grid) to
# end, then rebuild + upgrade (chain3.sh, FINAL=final6.11), Q0549 cells (q0549.sh), Q0547 doctor check, T4 once, UI smoke
# dark + light (every screen, renderer errors). Usage: bash chain7.sh
set -u
L=$HOME/ksm/out/chain.log
say() { echo "$(date -u +%T) $*" >> "$L"; }
for i in $(seq 1 360); do grep -q '^CHAIN_DONE' "$L" && break; sleep 30; done
grep -q '^CHAIN_DONE' "$L" || { say "chain7: chain 6 never ended, stopping"; exit 1; }
# app only first: the 6.10 service stays, so the outdated-service banner (#31 470bac7) is provable, then its own
# Update button updates the service. If that did not take, a CLI install so the rest runs on 6.11.
APP_ONLY=1 BUNDLE=/tmp/mac33j.bundle FINAL=final6.11 bash ~/ksm/chain3.sh
tail -1 "$L" | grep -q CHAIN3_DONE || { say "chain7: rebuild did not finish, stopping"; exit 1; }
BUILD=$(cd ~/rc-030 && git log --oneline -1 | cut -c1-9)
say "banner proof on $BUILD (new app, old service)"; bash ~/ksm/q-banner.sh ~/ksm/out/q-banner-r1
say "banner: $(grep -E '^(banner_|update_click|VERDICT)' ~/ksm/out/q-banner-r1/result.txt | tr '\n' ' ')"
if ! grep -q 'VERDICT PASS' ~/ksm/out/q-banner-r1/result.txt; then
  say "banner proof did not update the service: CLI daemon install"; /usr/local/bin/devnet-dvpn daemon install --yes >> "$L" 2>&1; sleep 5
fi
say "service now: $(/usr/local/bin/devnet-dvpn status 2>&1 | grep Daemon)"
say "q0549 cells on $BUILD"; bash ~/ksm/q0549.sh ~/ksm/out/q0549-r1
say "q0549: $(tail -n +2 ~/ksm/out/q0549-r1/cells.tsv | awk -F'\t' '{printf "%s=%s ", $1, $NF}')"
say "q0547 doctor on $BUILD"; bash ~/ksm/q0547-doctor.sh ~/ksm/out/q0547-r9
say "q0547: $(tail -1 ~/ksm/out/q0547-r9/result.txt)"
say "transitions r9 (t4) on $BUILD"; bash ~/ksm/transitions.sh r9 't4'
say "r9: $(head -1 ~/ksm/out/transitions-r9/t4-dvpnd-kill/verdict.txt | cut -f1-4)"
export DVPN_KEYFILE=$HOME/ksm/ksm-wallet.json DVPN_DATA_DIR=$HOME/ksm/profile
for th in dark light; do
  say "smoke $th on $BUILD"; UI_TIMEOUT=300 bash ~/rc-030/scripts/e2e/mac/ui-smoke.sh "$th" ~/ksm/out/smoke-611-$th > ~/ksm/out/smoke-611-$th.log 2>&1
  say "smoke $th: $(grep -c '^click screen' ~/ksm/out/smoke-611-$th.log) screens; $(grep -E '^exit=|^errors.json' ~/ksm/out/smoke-611-$th.log | tr '\n' ' ' | cut -c1-200)"
done
echo CHAIN7_DONE >> "$L"
