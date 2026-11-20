#!/usr/bin/env bash
# ─── Build this tree's x64 release in a guest, install it and update the service ───
# Usage: bash scripts/e2e/mac/guest-update.sh <guest ssh host>   (e.g. ddv-mac-3)
# Runs the guest's unit tests + typecheck (release-mac.mjs), replaces /Applications/Devnet dVPN.app
# from the dmg, then `daemon install --yes` with the rig's key file + data folder (lib.sh).
set -euo pipefail
H="${1:?guest ssh host}"
cd "$(dirname "$0")/../../.."
# Never under a running matrix: replacing the app mid-case voids that case (rig 1 r5 ks-rpcdown)
if owner=$(ssh "$H" 'cat ~/matrix-driver.lock/owner 2>/dev/null'); [ -n "$owner" ]; then
  echo "a matrix driver ($owner) holds $H: wait for it to end (or remove ~/matrix-driver.lock if it is dead)" >&2
  exit 2
fi
bash scripts/e2e/mac/sync.sh "$H" | tail -1
ssh "$H" 'set -e
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd ~/devnet-dvpn-mac
npm ci --silent > /tmp/ci.log 2>&1
node scripts/release-mac.mjs --arch x64 > /tmp/rel.log 2>&1 || { tail -20 /tmp/rel.log; exit 1; }
m=$(hdiutil attach -nobrowse -noverify -readonly dist/Devnet-dVPN-0.1.0-x64.dmg | awk -F"\t" "/\/Volumes\//{print \$NF}" | tail -1)
pkill -x "Devnet dVPN" || true
sudo rm -rf "/Applications/Devnet dVPN.app"
sudo ditto "$m/Devnet dVPN.app" "/Applications/Devnet dVPN.app"
hdiutil detach "$m" -quiet
export PATH="/Applications/Devnet dVPN.app/Contents/Resources/bin:$PATH" DVPN_KEYFILE=$HOME/.ddv/test-wallet.json DVPN_DATA_DIR=$HOME/ddv-data
devnet-dvpn daemon install --yes | tail -1
devnet-dvpn daemon version | tail -1 | cut -d" " -f1'
