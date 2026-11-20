#!/bin/bash
# ─── cellrun adapter: run a guest-side script IN the macOS guest and print one verdict line ───
#   bash scripts/e2e/mac/cell-guest.sh <cell> <script.sh|script.mjs> [args…]
# Syncs the tree once per 6 h, runs the script over ssh with the test wallet and /usr/local/bin on PATH,
# prints "PASS <cell>" when it exits 0 with no FAIL line and no "failed N>0" summary, else "FAIL <cell> …".
# CELLRUN_BROKEN=1 (negative control) hides the CLI from PATH, so the run MUST fail.
set -u
CELL=${1:?cell}; SCRIPT=${2:?script}; shift 2
H=${DDV_MAC_HOST:-ddv-mac}
HERE=$(cd "$(dirname "$0")" && pwd)
# cellrun's deadline kills THIS process on the host; the guest-side script would keep running and overlap the next
# cell (fuzz-full ran on 6 min past its kill and collided with installer-test). Stop it in the guest and restore.
on_kill() {
  echo "cell-guest: killed by the runner; stopping $SCRIPT in the guest" >&2
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$H" "pkill -f 'scripts/e2e/mac/$SCRIPT' ; sleep 2; export PATH=\"/Applications/Devnet dVPN.app/Contents/Resources/bin:/usr/local/bin:\$PATH\" DVPN_KEYFILE=\$HOME/.ddv/test-wallet.json DVPN_DATA_DIR=\$HOME/ddv-data; devnet-dvpn disconnect >/dev/null 2>&1; devnet-dvpn daemon restore-network >/dev/null 2>&1 || echo 'cell-guest: restore-network failed after kill' >&2" >&2
  echo "FAIL $CELL (killed by the runner deadline)"; exit 124
}
trap on_kill TERM INT HUP
STAMP=${TMPDIR:-/tmp}/ddv-mac-sync.stamp
if [ -z "$(find "$STAMP" -mmin -360 2>/dev/null)" ]; then
  bash "$HERE/sync.sh" "$H" >/tmp/ddv-mac-sync.log 2>&1 || { echo "FAIL $CELL (sync failed, see /tmp/ddv-mac-sync.log)"; exit 1; }
  : > "$STAMP"
fi
# installer-test ends with the product uninstalled; re-install from the already-built dmg (no rebuild) so CLI cells have the CLI
case $SCRIPT in installer-test.sh|prompt-proof.sh) ;; *)
  ssh -o BatchMode=yes "$H" 'test -x /usr/local/bin/devnet-dvpn' 2>/dev/null || ssh -o BatchMode=yes "$H" 'set -e
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
m=$(d=~/rc/current-x64.dmg; [ -e "$d" ] || d=~/devnet-dvpn-mac/dist/Devnet-dVPN-0.1.0-x64.dmg; hdiutil attach -nobrowse -noverify -readonly "$d" | awk -F"\t" "/\/Volumes\//{print \$NF}" | tail -1)
pkill -x "Devnet dVPN" || true
sudo rm -rf "/Applications/Devnet dVPN.app"; sudo ditto "$m/Devnet dVPN.app" "/Applications/Devnet dVPN.app"; hdiutil detach "$m" -quiet
export PATH="/Applications/Devnet dVPN.app/Contents/Resources/bin:$PATH" DVPN_KEYFILE=$HOME/.ddv/test-wallet.json DVPN_DATA_DIR=$HOME/ddv-data
devnet-dvpn daemon install --yes | tail -1' >&2 || { echo "FAIL $CELL (CLI re-install failed)"; exit 1; }
  # a cell cut mid-way (e.g. ssh dropped in a persist step) can leave the service unloaded: every later cell would read
  # "VPN service is not running". Bring it back before this cell starts so one broken cell cannot taint the next.
  ssh -o BatchMode=yes "$H" 'export PATH="/Applications/Devnet dVPN.app/Contents/Resources/bin:/usr/local/bin:$PATH" DVPN_KEYFILE=$HOME/.ddv/test-wallet.json DVPN_DATA_DIR=$HOME/ddv-data
devnet-dvpn status 2>&1 | grep -q "^Daemon *running" && exit 0
echo "cell-guest: VPN service was down before this cell; reinstalling" >&2
devnet-dvpn daemon restore-network >&2 2>&1 || echo "cell-guest: restore-network failed (continuing)" >&2
o=$(devnet-dvpn daemon install --yes 2>&1); echo "$o" | tail -1
for i in $(seq 1 30); do devnet-dvpn status 2>&1 | grep -q "^Daemon *running" && exit 0; sleep 2; done
echo "cell-guest: service still not running 60 s after install. install said:"; echo "$o" | tail -5
sudo -n launchctl print system/network.sentinel.devnet-dvpn.dvpnd 2>&1 | grep -E "state|last exit|runs" | head -4
exit 1' >&2 || { echo "FAIL $CELL (VPN service down before the cell and would not stay up after re-install)"; exit 1; } ;;
esac
PATHV='/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'
[ "${CELLRUN_BROKEN:-0}" = 1 ] && PATHV='/usr/bin:/bin:/usr/sbin:/sbin'
# Keychain unlock for the wallet cells: the guest login password lives ONLY in the guest (~/.ddv/rig-password, 0600, owner
# approved 2026-10-28 via DIR Q0143). It is read inside the guest; the host only ever sees the literal $(cat …), never the value.
GENV="RIG_PASSWORD=\$(cat ~/.ddv/rig-password 2>/dev/null)"
# The plan the cli tiers subscribe to (Q0416): without it cli-sweep spend skips plans subscribe/close and cli-cover
# reports "plans close" MISSING. Default = the rig's node-4 plan (#31 allows it); PLAN_ADDR on the host overrides.
PLAN_ADDR=${PLAN_ADDR:-55yEYsyUd87AFEhLg9PuL39cfaDMktjEg74CSw8PdRzc}
[[ $PLAN_ADDR =~ ^[1-9A-HJ-NP-Za-km-z]{32,44}$ ]] || { echo "cell-guest: PLAN_ADDR is not a base58 address: '$PLAN_ADDR'" >&2; exit 2; }
GENV="$GENV PLAN_ADDR=$PLAN_ADDR"
case $SCRIPT in
  *.mjs) RUN="node scripts/e2e/mac/$SCRIPT" ;;
  *) RUN="bash scripts/e2e/mac/$SCRIPT" ;;
esac
# installer-test needs the dmg under test: the release candidate in the guest (~/rc/current-x64.dmg, sha-checked on copy)
[ "$SCRIPT" = installer-test.sh ] && [ $# -eq 0 ] && set -- "\$HOME/rc/current-x64.dmg"
# ─── Save-sheet keys from the host (uifire): the guest has SIP on, so osascript gets no Accessibility.
# The guest cell writes ~/matrix/uifire-keys.req (a folder path) once its Save sheet is open; this host
# side types Go to folder + the path + Return twice on the VM's virtual keyboard (QMP sendkey), then
# answers with ~/matrix/uifire-keys.done. The guest still holds no credential for this host.
path_keys() { # <path>: HMP key names, one per character
  local s=$1 c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [a-z0-9]) printf '%s ' "$c" ;;
      [A-Z]) printf 'shift-%s ' "$(printf '%s' "$c" | tr 'A-Z' 'a-z')" ;;
      /) printf 'slash ' ;; -) printf 'minus ' ;; .) printf 'dot ' ;; _) printf 'shift-minus ' ;;
      *) return 1 ;;
    esac
  done
}
save_sheet_keys() {
  local p k
  for _ in $(seq 1 90); do
    sleep 3
    p=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$H" 'cat ~/matrix/uifire-keys.req 2>/dev/null' 2>/dev/null) || continue
    [ -n "$p" ] || continue
    [[ $p =~ ^/Users/[a-z0-9]+/matrix/[a-z0-9-]+$ ]] || { echo "cell-guest: refused key request path '$p'" >&2; return 1; }
    k=$(path_keys "$p") || return 1
    FC='sudo -n /usr/local/sbin/ddv-faultctl keys'
    # evidence of what had focus: the real framebuffer, before and after (webContents shots never show a sheet)
    shot() { python3 "$HOME/vmctl.py" hmp "screendump /tmp/uifire-keys-$1.ppm" >/dev/null 2>&1 \
      && pnmtopng "/tmp/uifire-keys-$1.ppm" > "$HOME/cr/uifire-keys-$CELL-$1.png" 2>/dev/null; rm -f "/tmp/uifire-keys-$1.ppm"; }
    shot before
    $FC meta_l-shift-g >&2 && sleep 1.5 && $FC $k >&2 && sleep 1 && $FC ret >&2 && sleep 1.5 && $FC ret >&2 \
      && ssh -o BatchMode=yes "$H" 'mv ~/matrix/uifire-keys.req ~/matrix/uifire-keys.done' && echo 'cell-guest: save sheet answered from the host' >&2
    sleep 2; shot after; echo "cell-guest: screen before/after the keys: ~/cr/uifire-keys-$CELL-{before,after}.png" >&2
    return 0
  done
}
KEYS_PID=''
[ "$SCRIPT" = uifire.sh ] && { save_sheet_keys & KEYS_PID=$!; }
if [ "$SCRIPT" = cli-sweep.sh ] && { [ "${1:-}" = ksdns ] || [ "${1:-}" = ledger ]; }; then
  # kill-switch tiers (ksdns; ledger's persist step) drop the ssh session on purpose: run detached on the guest, poll for the rc file
  ssh -o BatchMode=yes "$H" "rm -f ~/cell-$CELL.rc; cd ~/devnet-dvpn-mac && $GENV PATH=$PATHV DVPN_KEYFILE=\$HOME/.ddv/test-wallet.json nohup sh -c '$RUN $*; echo \$? > ~/cell-$CELL.rc' > ~/cell-$CELL.out 2>&1 < /dev/null &" >/dev/null 2>&1
  OUT=''; RC=255
  for _ in $(seq 1 ${KSDNS_POLLS:-180}); do
    sleep 20
    R=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$H" "cat ~/cell-$CELL.rc 2>/dev/null" 2>/dev/null) || continue
    [ -n "$R" ] && { RC=$R; OUT=$(ssh -o BatchMode=yes "$H" "cat ~/cell-$CELL.out" 2>&1); break; }
  done
else
  OUT=$(ssh -o BatchMode=yes "$H" "cd ~/devnet-dvpn-mac && $GENV PATH=$PATHV DVPN_KEYFILE=\$HOME/.ddv/test-wallet.json $RUN $*" 2>&1); RC=$?
fi
[ -n "$KEYS_PID" ] && { kill "$KEYS_PID" 2>/dev/null; wait "$KEYS_PID" 2>/dev/null; }
# the whole output: the effect lines (FINAL-PASS-EFFECT-SPEC.md) come from every step, not only the last 40 lines
printf '%s\n' "$OUT" | tail -3000
if [ $RC -eq 0 ] && ! printf '%s\n' "$OUT" | grep -qE '^FAIL|failed +[1-9]'; then
  echo "PASS $CELL"
else
  echo "FAIL $CELL (exit $RC)"; exit 1
fi
