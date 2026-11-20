#!/bin/bash
# Guest chain 8 (detached), after chain 7: the final RC build (#31 ddc4bc8 + 68ff53c), the xrp held regression, then
# the KSM13 UI grid FAIL reruns.
# r1 had 13 FAILs on earlier builds (none on the 6.10 RC rows):
#   - appA_on x6 and ks_persist x5 were harness bugs (fixed in #33 5703bb8): rerun once each, every state;
#   - v2p split_mode and xrp wd_toggle were node-side ("the server had a problem starting your session"): x3 each.
set -u
L=$HOME/ksm/out/chain.log
say() { echo "$(date -u +%T) $*" >> "$L"; }
for i in $(seq 1 480); do grep -q '^CHAIN7_DONE' "$L" && break; sleep 30; done
grep -q '^CHAIN7_DONE' "$L" || { say "chain8: chain 7 never ended, stopping"; exit 1; }
# DIR: dvpnd final6.12 (f99ca49) + #31 ddc4bc8 (Q0540 branch only without a session) + 68ff53c (Q0544 words) came after chain 7 began its
# rebuild: the final build is this one (full install, service included).
BUNDLE=/tmp/mac33k.bundle FINAL=final6.12 bash ~/ksm/chain3.sh
tail -1 "$L" | grep -q CHAIN3_DONE || { say "chain8: rebuild did not finish, stopping"; exit 1; }
BUILD=$(cd ~/rc-030 && git log --oneline -1 | cut -c1-9)
say "xrp held regression on $BUILD (x3)"; bash ~/ksm/q-xrp-held.sh ~/ksm/out/q-xrp-held-r1 3
say "xrp held: $(tail -1 ~/ksm/out/q-xrp-held-r1/result.txt)"
say "q0547 doctor on $BUILD (final)"; bash ~/ksm/q0547-doctor.sh ~/ksm/out/q0547-r10
say "q0547: $(tail -1 ~/ksm/out/q0547-r10/result.txt)"
say "transitions r10 (t4) on $BUILD (final)"; bash ~/ksm/transitions.sh r10 't4'
say "r10: $(head -1 ~/ksm/out/transitions-r10/t4-dvpnd-kill/verdict.txt | cut -f1-4)"
say "grid reruns on $BUILD: ks_persist + appA_on, every state (r2)"
ARM=ui bash ~/ksm/ksm13-ui.sh r2 . 'ks_persist|appA_on'
for n in 3 4 5; do
  say "grid rerun r$n: v2p split_mode, xrp wd_toggle"
  ARM=ui bash ~/ksm/ksm13-ui.sh "r$n" '^v2p$' '^split_mode$'
  ARM=ui bash ~/ksm/ksm13-ui.sh "r$n" '^xrp$' '^wd_toggle$'
done
for n in 2 3 4 5; do
  say "r$n: $(tail -n +2 ~/ksm/out/ksm13-r$n/grid-ui.tsv | awk -F'\t' '{printf "%s/%s=%s ", $2, $3, $15}')"
done
echo CHAIN8_DONE >> "$L"
