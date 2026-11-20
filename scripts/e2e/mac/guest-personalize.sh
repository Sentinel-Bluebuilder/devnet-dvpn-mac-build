#!/bin/bash
# ─── Make a cloned macOS guest its own test rig: new wallet, new device, fresh service ───
# Run IN the clone (second rig), never in the original guest. Two guests sharing a device key
# would fight over the same channels on chain, so the clone gets:
#   - a new wallet key file at ~/.ddv/test-wallet.json, funded from the original wallet
#     (kept as ~/.ddv/test-wallet-src.json): SOL_FUND SOL + TDVPN_FUND tDVPN
#   - a new device (dvpnd init), spending permission (device setup) and a reinstalled service
# Nothing is deleted: the old service home and app data are moved aside with a suffix.
# Usage: bash scripts/e2e/mac/guest-personalize.sh   (prints the new wallet address last)
set -euo pipefail
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
SOL_FUND=${SOL_FUND:-0.15}
TDVPN_FUND=${TDVPN_FUND:-1000}
L="/Applications/Devnet dVPN.app/Contents/Resources/bin/devnet-dvpn"
export DVPN_DATA_DIR=$HOME/ddv-data
SUFFIX=clone-$(date -u +%Y%m%dT%H%M%SZ)
cd "$(dirname "$0")/../../.."

[ -f "$HOME/.ddv/test-wallet-src.json" ] && { echo "already personalised (test-wallet-src.json exists)"; exit 1; }

# ─── 1. The old service and device go aside ───
DVPN_KEYFILE=$HOME/.ddv/test-wallet.json "$L" disconnect >/dev/null 2>&1 || echo 'no session to end'
DVPN_KEYFILE=$HOME/.ddv/test-wallet.json "$L" daemon uninstall --yes
sudo mv /var/db/dvpnd "/var/db/dvpnd.$SUFFIX"
mv "$DVPN_DATA_DIR" "$DVPN_DATA_DIR.$SUFFIX"

# ─── 2. New wallet, funded from the original ───
mv "$HOME/.ddv/test-wallet.json" "$HOME/.ddv/test-wallet-src.json"
NEW=$(node -e "
const { Keypair } = require('@solana/web3.js');
const fs = require('fs');
const k = Keypair.generate();
fs.writeFileSync(process.argv[1], JSON.stringify(Array.from(k.secretKey)), { mode: 0o600 });
console.log(k.publicKey.toBase58());" "$HOME/.ddv/test-wallet.json")
echo "new wallet $NEW"
DVPN_KEYFILE=$HOME/.ddv/test-wallet-src.json "$L" wallet send --to "$NEW" --sol "$SOL_FUND" --yes
sleep 7
DVPN_KEYFILE=$HOME/.ddv/test-wallet-src.json "$L" wallet send --to "$NEW" --tdvpn "$TDVPN_FUND" --yes
sleep 7

# ─── 3. New device, permission, service ───
export DVPN_KEYFILE=$HOME/.ddv/test-wallet.json
"$L" wallet
"$L" daemon init
sleep 7
"$L" device setup --yes
sleep 7
"$L" daemon install --yes
sleep 5
"$L" daemon version
echo "personalised: wallet $NEW (back up ~/.ddv/test-wallet.json off the guest)"
