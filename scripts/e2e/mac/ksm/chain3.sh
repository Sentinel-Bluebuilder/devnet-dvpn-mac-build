#!/bin/bash
# Guest chain 3 (detached): RC rebuild from the bundle (final6.9 + Q0543 guard) -> upgrade. The Q0542 proof is driven
# from the laptop afterwards (framebuffer screenshots come from the QEMU host).
set -u
L=$HOME/ksm/out/chain.log
say() { echo "$(date -u +%T) $*" >> "$L"; }
say "chain3: building from ${BUNDLE:-/tmp/mac33h.bundle}"
cd ~/rc-030 && git checkout -q -- . && git pull -q ${BUNDLE:-/tmp/mac33h.bundle} main && say "at $(git log --oneline -1 | cut -c1-12)"
./build2.sh > build9.log 2>&1
grep -q ALL_DONE build9.log || { say "BUILD FAILED, stopping"; exit 1; }
F=${FINAL:-final6.10}; grep -q "$F" build9.log || say "WARNING: build log does not name $F"
say "built: $(grep x64.dmg dist/SHA256SUMS.txt | cut -c1-16)"
export DVPN_KEYFILE=$HOME/ksm/ksm-wallet.json DVPN_DATA_DIR=$HOME/ksm/profile
/usr/local/bin/devnet-dvpn disconnect >> "$L" 2>&1
# The app ignores SIGTERM (rc.2 finding): quit it with the AppleEvent logout uses, then kill only its exact PIDs.
osascript -e 'with timeout of 20 seconds' -e 'tell application "Devnet dVPN" to quit' -e 'end timeout' >/dev/null 2>&1; sleep 5
for p in $(pgrep -x "Devnet dVPN"); do say "app $p did not quit: kill -9"; kill -9 "$p"; done
M=$(hdiutil attach -nobrowse -readonly "$(ls -t ~/rc-030/dist/Devnet-dVPN-*-x64.dmg | head -1)" | tail -1 | cut -f3-)
sudo -n rm -rf "/Applications/Devnet dVPN.app" && sudo -n ditto "$M/Devnet dVPN.app" "/Applications/Devnet dVPN.app"; hdiutil detach -quiet "$M"
if [ "${APP_ONLY:-0}" = 1 ]; then say "app only (no daemon install): the service keeps its old copies"; else /usr/local/bin/devnet-dvpn daemon install --yes >> "$L" 2>&1; sleep 5; fi
say "upgraded: $(/usr/local/bin/devnet-dvpn status 2>&1 | grep Daemon)"
echo CHAIN3_DONE >> "$L"
