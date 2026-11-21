#!/bin/bash
# ─── leftover-recover.sh <run evidence dir> <owner address>: sweep the escrowed throwaway wallets of one live run (ctl only) ───
# M33-15: when gha-live.sh could not empty a throwaway wallet, it put the key, RSA-OAEP(SHA-256) encrypted to
# scripts/e2e/mac/leftover-escrow-pub.txt, in the uploaded evidence (leftover-escrow/b-<address>.json.enc). Only ctl
# holds the private half (ESCROW_KEY, default ~/mac-escrow/escrow.key, 0600). This opens each one into a 0600 folder
# and runs gha-live.sh's own sweep on it (CLEANUP_ONLY=1): all tDVPN by the CLI, then one exact SOL transfer to 0; a
# key is deleted only once its balance reads back empty.
#   CLI=<a devnet-dvpn CLI on this box>  (e.g. "node ~/l32-rc9/out/cli/devnet-dvpn.cjs" wrapped in a script)
set -euo pipefail
EVD=${1:?usage: leftover-recover.sh <run evidence dir> <owner address>}; OWNER=${2:?owner address}
ESCROW_KEY=${ESCROW_KEY:-$HOME/mac-escrow/escrow.key}
HERE=$(cd "$(dirname "$0")/../e2e/mac" && pwd)
[ -n "${CLI:-}" ] || { echo 'set CLI to a devnet-dvpn CLI' >&2; exit 2; }
[ -r "$ESCROW_KEY" ] || { echo "no escrow private key at $ESCROW_KEY" >&2; exit 2; }
W=$(umask 077; mktemp -d "$HOME/leftover-recover.XXXXXX")
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/lo" "$W/ev"; printf 'owner=%s\ncleaned=1\n' "$OWNER" >"$W/ev/.state"
n=0
for f in "$EVD"/leftover-escrow/b-*.json.enc; do
  [ -f "$f" ] || continue
  out="$W/lo/$(basename "$f" .enc)"
  (umask 077; openssl pkeyutl -decrypt -inkey "$ESCROW_KEY" -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 -in "$f" -out "$out")
  n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "no escrowed keys under $EVD/leftover-escrow"; exit 0; }
echo "recovering $n escrowed wallet(s) to $OWNER"
CLEANUP_ONLY=1 LEFTOVER_DIR="$W/lo" EVIDENCE_DIR="$W/ev" DVPN_KEYFILE=/dev/null CLI="$CLI" bash "$HERE/gha-live.sh" || true
cat "$W/ev/leftover.out"
left=$(find "$W/lo" -name 'b-*.json' | wc -l)
[ "$left" = 0 ] || { echo "$left wallet(s) still not empty: keys copied to $HOME/mac-escrow/unswept/" >&2; mkdir -p "$HOME/mac-escrow/unswept"; (umask 077; cp "$W"/lo/b-*.json "$HOME/mac-escrow/unswept/"); exit 1; }
echo "all $n escrowed wallet(s) emptied; keys deleted"
