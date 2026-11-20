#!/bin/bash
# ─── UI smoke on macOS: the INSTALLED app in the console GUI session (run IN the guest) ───
# Clicks every screen, screenshots each one (webContents capture: no Screen Recording permission
# needed), records renderer errors (src/main/dev/ui-smoke.ts). Over SSH the app has no
# WindowServer access, so it is started inside the logged-in console session with
# `launchctl asuser` (then dropped back to the test user). Test wallet read-only via
# DVPN_KEYFILE. Extra env is passed through (DVPN_UI_SCENARIO, DVPN_UI_SMOKE_CONNECT …).
# Usage: bash ui-smoke.sh dark|light [out-dir]
set -u
THEME=${1:-dark}
OUT=${2:-$HOME/ui/$THEME}
APP_BIN='/Applications/Devnet dVPN.app/Contents/MacOS/Devnet dVPN'
: "${DVPN_KEYFILE:?set DVPN_KEYFILE to the test wallet key file}"
[ -x "$APP_BIN" ] || { echo "app not installed at $APP_BIN" >&2; exit 1; }
stat -f %Su /dev/console | grep -qx "$(id -un)" || { echo "$(id -un) is not logged in at the console" >&2; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"
ENVV=(DVPN_UI_SMOKE="$OUT" DVPN_UI_SMOKE_THEME="$THEME" DVPN_DATA_DIR="${DVPN_DATA_DIR:-$HOME/ddv-data}" HOME="$HOME" USER="$(id -un)" LOGNAME="$(id -un)" PATH="$PATH")
# DVPN_KEYFILE=none: a fresh profile with no test wallet (uifire onboarding cells: the app's own wallet, created in the UI)
[ "$DVPN_KEYFILE" = none ] || ENVV+=(DVPN_KEYFILE="$DVPN_KEYFILE")
for v in DVPN_UI_SCENARIO DVPN_UI_SMOKE_CONNECT DVPN_UI_SMOKE_DIALOGS DVPN_UI_DIRECT_IP DVPN_UI_EXPECT_NODE_IP DVPN_UI_ONBOARD DVPN_UI_SMOKE_FOCUS DVPN_UI_SIG_DIR; do
  [ -n "${!v:-}" ] && ENVV+=("$v=${!v}")
done
UIDN=$(id -u)
sudo -n launchctl asuser "$UIDN" sudo -n -u "$(id -un)" env "${ENVV[@]}" "$APP_BIN" > "$OUT/app.log" 2>&1 &
PID=$!
# ui-smoke.ts quits the app when it is done; give up after UI_TIMEOUT seconds
T=${UI_TIMEOUT:-600}
while kill -0 "$PID" 2>/dev/null && [ "$T" -gt 0 ]; do sleep 2; T=$((T - 2)); done
if kill -0 "$PID" 2>/dev/null; then echo 'timed out: stopping the app'; pkill -f "$APP_BIN"; fi
wait "$PID"; echo "exit=$?"
grep -v '^\[rpc\]' "$OUT/app.log" > "$OUT/app.log.tmp" && mv "$OUT/app.log.tmp" "$OUT/app.log"
ls "$OUT"
# effect lines (FINAL-PASS-EFFECT-SPEC.md PURE-UI): one per screen the walker clicked to and captured
for f in "$OUT"/*.png; do
  [ -s "$f" ] && echo "click screen $(basename "$f" .png): clicked, screenshot $(wc -c < "$f" | tr -d ' ') B"
done
echo "errors.json: $(cat "$OUT/errors.json" 2>/dev/null || echo missing)"
