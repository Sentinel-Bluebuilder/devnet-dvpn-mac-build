#!/bin/bash
# Guest chain 6 (detached): the RC build. Rebuild + upgrade (chain3.sh), Q0547 doctor check, T3/T4/T10 x3, then the
# UI grid resumes with a recorded build boundary. Usage: bash chain6.sh [run prefix, default r8]
set -u
P=${1:-r8}
L=$HOME/ksm/out/chain.log
say() { echo "$(date -u +%T) $*" >> "$L"; }
FINAL=final6.10 bash ~/ksm/chain3.sh
tail -1 "$L" | grep -q CHAIN3_DONE || { say "chain6: rebuild did not finish, stopping"; exit 1; }
BUILD=$(cd ~/rc-030 && git log --oneline -1 | cut -c1-9)
say "q0547 doctor check on $BUILD"; bash ~/ksm/q0547-doctor.sh ~/ksm/out/q0547-$P
say "q0547: $(tail -1 ~/ksm/out/q0547-$P/result.txt)"
for r in ${P}a ${P}b ${P}c; do
  say "transitions $r (t3|t4|t10) on $BUILD"; bash ~/ksm/transitions.sh "$r" 't3|t4|t10'
  say "$r: $(for v in ~/ksm/out/transitions-$r/t*/verdict.txt; do head -1 "$v" | cut -f1,2; grep takedown "$v"; done | tr '\t\n' ' ;')"
done
echo "# rows below: build $BUILD (RC, final6.10), $(date -u +%FT%TZ)" >> ~/ksm/out/ksm13-r1/build-boundary.txt
wc -l < ~/ksm/out/ksm13-r1/grid-ui.tsv >> ~/ksm/out/ksm13-r1/build-boundary.txt
say "UI grid resume ($BUILD)"; ARM=ui bash ~/ksm/ksm13-ui.sh r1; say "UI grid done"
echo CHAIN_DONE >> "$L"
