#!/bin/bash
# Guest chain 5 (detached): rebuild + upgrade (chain3.sh), T3/T4 x3 (<prefix>a..c, default r3), then the UI grid resumes.
# Usage: bash chain5.sh [run prefix] [transition filter]
set -u
P=${1:-r3}; F=${2:-t3|t4}
L=$HOME/ksm/out/chain.log
say() { echo "$(date -u +%T) $*" >> "$L"; }
bash ~/ksm/chain3.sh
tail -1 "$L" | grep -q CHAIN3_DONE || { say "chain5: rebuild did not finish, stopping"; exit 1; }
BUILD=$(cd ~/rc-030 && git log --oneline -1 | cut -c1-9)
for r in ${P}a ${P}b ${P}c; do
  say "transitions $r ($F) on $BUILD"; bash ~/ksm/transitions.sh "$r" "$F"
  say "$r: $(cat ~/ksm/out/transitions-$r/t*/verdict.txt 2>/dev/null | cut -f1,2 | tr '\t\n' ' ;')"
done
echo "# rows below: build $BUILD, $(date -u +%FT%TZ)" >> ~/ksm/out/ksm13-r1/build-boundary.txt
wc -l < ~/ksm/out/ksm13-r1/grid-ui.tsv >> ~/ksm/out/ksm13-r1/build-boundary.txt
say "UI grid resume ($BUILD)"; ARM=ui bash ~/ksm/ksm13-ui.sh r1; say "UI grid done"
echo CHAIN_DONE >> "$L"
