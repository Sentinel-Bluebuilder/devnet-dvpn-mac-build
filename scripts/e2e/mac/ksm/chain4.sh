#!/bin/bash
# Guest chain 4 (detached), on the final6.9 + Q0543 build: T3/T4 x3 (guard fix proof), then the UI grid resumes.
set -u
L=$HOME/ksm/out/chain.log
say() { echo "$(date -u +%T) $*" >> "$L"; }
for r in r2a r2b r2c; do
  say "transitions $r (t3|t4)"; bash ~/ksm/transitions.sh "$r" 't3|t4'
  say "$r: $(cat ~/ksm/out/transitions-$r/t*/verdict.txt 2>/dev/null | cut -f1,2 | tr '\t\n' ' ;')"
done
# Rows already in grid-ui.tsv ran on the final6.8 build (3ef1614); every row after this line runs on the final6.9 build.
echo "# rows above: build 3ef1614 (final6.8); rows below: build 4388b2e (final6.9 + Q0543), $(date -u +%FT%TZ)" >> ~/ksm/out/ksm13-r1/build-boundary.txt
wc -l < ~/ksm/out/ksm13-r1/grid-ui.tsv >> ~/ksm/out/ksm13-r1/build-boundary.txt
say "UI grid resume (final6.9 build)"; ARM=ui bash ~/ksm/ksm13-ui.sh r1; say "UI grid done"
echo CHAIN_DONE >> "$L"
