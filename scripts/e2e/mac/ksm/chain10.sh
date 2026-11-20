#!/bin/bash
# Guest chain 10 (detached), after chain 9: the final RC on dvpnd final6.13 (Q0555: Mac userspace WireGuard/AmneziaWG
# engine exit -> redial). One build (full install), then Q0549 CELLS=wg3 (WireGuard x3 + AmneziaWG x1 persist + WG
# KS-off control + a requested disconnect and a server switch under persist: never a redial), then doctor, T4 and the
# dark/light smoke so the signed build carries its own evidence.
set -u
L=$HOME/ksm/out/chain.log
say() { echo "$(date -u +%T) $*" >> "$L"; }
for i in $(seq 1 600); do grep -q '^CHAIN9_DONE' "$L" && break; sleep 30; done
grep -q '^CHAIN9_DONE' "$L" || { say "chain10: chain 9 never ended, stopping"; exit 1; }
BUNDLE=/tmp/mac33l.bundle FINAL=final6.13 bash ~/ksm/chain3.sh
tail -1 "$L" | grep -q CHAIN3_DONE || { say "chain10: rebuild did not finish, stopping"; exit 1; }
BUILD=$(cd ~/rc-030 && git log --oneline -1 | cut -c1-9)
say "q0549 wg3 on $BUILD"; CELLS=wg3 bash ~/ksm/q0549.sh ~/ksm/out/q0549-wg3-r1
say "q0549 wg3: $(tail -n +2 ~/ksm/out/q0549-wg3-r1/cells.tsv | awk -F'\t' '{printf "%s=%s ", $1, $NF}')"
say "q0547 doctor on $BUILD (6.13)"; bash ~/ksm/q0547-doctor.sh ~/ksm/out/q0547-r11
say "q0547: $(tail -1 ~/ksm/out/q0547-r11/result.txt)"
# DIR Q0547 part 2 / Q0550: the user doctor with a PERSISTED kill switch (r10 ran with it off: "no persisted kill switch")
export DVPN_KEYFILE=$HOME/ksm/ksm-wallet.json DVPN_DATA_DIR=$HOME/ksm/profile
/usr/local/bin/devnet-dvpn daemon set --kill-switch persist --yes >> "$L" 2>&1; sleep 5
mkdir -p ~/ksm/out/q0547-r11-persist
/usr/local/bin/devnet-dvpn daemon doctor --json > ~/ksm/out/q0547-r11-persist/user.json 2>&1
/usr/local/bin/devnet-dvpn daemon doctor > ~/ksm/out/q0547-r11-persist/user.txt 2>&1
sudo -n /usr/local/bin/devnet-dvpn daemon doctor > ~/ksm/out/q0547-r11-persist/root.txt 2>&1
/usr/local/bin/devnet-dvpn daemon set --kill-switch off --yes >> "$L" 2>&1; /usr/local/bin/devnet-dvpn daemon restore-network >> "$L" 2>&1
say "doctor with KS persist: user $(grep -iE "kill.?switch" ~/ksm/out/q0547-r11-persist/user.txt | head -1 | tr -s " " | cut -c1-140) | root $(grep -iE "kill.?switch" ~/ksm/out/q0547-r11-persist/root.txt | head -1 | tr -s " " | cut -c1-140)"
say "transitions r11 (t4) on $BUILD (6.13)"; bash ~/ksm/transitions.sh r11 't4'
say "r11: $(head -1 ~/ksm/out/transitions-r11/t4-dvpnd-kill/verdict.txt | cut -f1-4)"
export DVPN_KEYFILE=$HOME/ksm/ksm-wallet.json DVPN_DATA_DIR=$HOME/ksm/profile
for th in dark light; do
  say "smoke $th on $BUILD"; UI_TIMEOUT=300 bash ~/rc-030/scripts/e2e/mac/ui-smoke.sh "$th" ~/ksm/out/smoke-613-$th > ~/ksm/out/smoke-613-$th.log 2>&1
  say "smoke $th: $(grep -c '^click screen' ~/ksm/out/smoke-613-$th.log) screens; $(grep -E '^exit=|^errors.json' ~/ksm/out/smoke-613-$th.log | tr '\n' ' ' | cut -c1-200)"
done
echo CHAIN10_DONE >> "$L"
