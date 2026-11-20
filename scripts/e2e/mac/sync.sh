#!/usr/bin/env bash
# ─── Copy this working tree to the macOS test guest (~/devnet-dvpn-mac) ───
# Sends tracked + new files (no node_modules/out/dist/.git) over ssh as a tar stream, then every
# local build build/deps.lock.json names (dvpnd, patched Xray) into the guest's mirror of
# ~/Desktop/devnet-dvpn-dvpnd-devnet/build, where scripts/fetch-deps.mjs looks for them.
# Usage: bash scripts/e2e/mac/sync.sh [host]    (default ddv-mac = ProxyJump via ddv-mac-host)
set -euo pipefail
H="${1:-ddv-mac}"
cd "$(dirname "$0")/../../.."
LIST="${TMPDIR:-/tmp}/ddvm-files.txt"
{ git ls-files; git ls-files --others --exclude-standard; } | sort -u | while read -r f; do [ -e "$f" ] && printf '%s\n' "$f"; done > "$LIST"
# COPYFILE_DISABLE: no AppleDouble files if this ever runs on a Mac; bsdtar on the guest reads it.
COPYFILE_DISABLE=1 tar -czf - -T "$LIST" | ssh "$H" 'mkdir -p ~/devnet-dvpn-mac && tar -xzf - -C ~/devnet-dvpn-mac'
BUILDS="$HOME/Desktop/devnet-dvpn-dvpnd-devnet/build"
sent=0
for src in $(node -e "for (const l of require('./build/deps.lock.json').local) console.log(l.src)" | sort -u); do
  [ -f "$BUILDS/$src" ] || { echo "missing local build $BUILDS/$src" >&2; exit 1; }
  if ! ssh "$H" "[ -f ~/Desktop/devnet-dvpn-dvpnd-devnet/build/$src ]"; then
    gzip -1c "$BUILDS/$src" | ssh "$H" "mkdir -p ~/Desktop/devnet-dvpn-dvpnd-devnet/build && gunzip > ~/Desktop/devnet-dvpn-dvpnd-devnet/build/$src"
    sent=$((sent + 1))
  fi
done
echo "synced $(wc -l < "$LIST") files to $H:~/devnet-dvpn-mac; $sent local build(s) sent"
