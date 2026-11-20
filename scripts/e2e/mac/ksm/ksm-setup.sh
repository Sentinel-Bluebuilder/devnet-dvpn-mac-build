#!/bin/bash
# Q0508 KSM wallet + device + service (guest). stdin line 1 = login password.
IFS= read -r PW; security unlock-keychain -p "$PW" ~/Library/Keychains/login.keychain-db; unset PW
CLI="/Applications/Devnet dVPN.app/Contents/Resources/bin/devnet-dvpn"
export DVPN_DATA_DIR=$HOME/ksm/profile
OLDMASK=$(umask); umask 077
if [ ! -s ~/ksm/ksm-wallet.json ]; then
  "$CLI" wallet create --keyfile ~/ksm/ksm-wallet.json --yes > ~/ksm/ksm-wallet-create.txt 2>&1; echo "create exit=$?"
fi
umask "$OLDMASK"
export DVPN_KEYFILE=$HOME/ksm/ksm-wallet.json
ADDR=$("$CLI" wallet show | awk '/^Address/{print $2}'); echo "KSM wallet $ADDR"
fund() { DVPN_KEYFILE=$HOME/.ddv/test-wallet.json DVPN_DATA_DIR=$HOME/rc1/funder "$CLI" "$@"; }
fund wallet send --to "$ADDR" --sol 0.09 --yes; sleep 8
fund wallet send --to "$ADDR" --tdvpn 40 --yes; sleep 8
"$CLI" wallet show | head -3
"$CLI" daemon init; echo "init exit=$?"
"$CLI" device setup --allowance 30 --yes; echo "setup exit=$?"; sleep 8
"$CLI" daemon install --yes; echo "install exit=$?"; sleep 5
"$CLI" status
"$CLI" daemon settings | head -3
