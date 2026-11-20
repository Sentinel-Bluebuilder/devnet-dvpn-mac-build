#!/bin/bash
# Guest chain 9 (detached), after chain 8 on the same final build: Q0549 AmneziaWG x1 under persist (DIR 11-13: expect
# the Mac WireGuard FAIL shape, amneziawg-go backgrounds itself like wireguard-go). CELLS=wg3 later proves fork 6.13.
set -u
L=$HOME/ksm/out/chain.log
say() { echo "$(date -u +%T) $*" >> "$L"; }
for i in $(seq 1 600); do grep -q '^CHAIN8_DONE' "$L" && break; sleep 30; done
grep -q '^CHAIN8_DONE' "$L" || { say "chain9: chain 8 never ended, stopping"; exit 1; }
BUILD=$(cd ~/rc-030 && git log --oneline -1 | cut -c1-9)
say "q0549 AmneziaWG persist x1 on $BUILD ($(/usr/local/bin/devnet-dvpn status 2>&1 | grep Daemon | tr -s ' '))"
CELLS=awg bash ~/ksm/q0549.sh ~/ksm/out/q0549-awg-r1
say "q0549 awg: $(tail -n +2 ~/ksm/out/q0549-awg-r1/cells.tsv | awk -F'\t' '{printf "%s=%s ", $1, $NF}')"
echo CHAIN9_DONE >> "$L"
