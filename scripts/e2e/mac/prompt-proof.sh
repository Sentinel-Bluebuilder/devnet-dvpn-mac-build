#!/usr/bin/env bash
# ─── Proof of the macOS admin password prompt (osascript), driven from the laptop ───
# The rig user has passwordless sudo, so DVPN_ELEVATOR=osascript forces the path a real user gets:
# a root step from the GUI session shows the system password dialog. Two runs:
#   answer  the password is typed into the dialog through QMP → the step applies (exit 0)
#   cancel  Escape dismisses the dialog → the CLI says the step was cancelled (non-zero, plain words)
# Usage (laptop): awk -F': ' 'NR==2{print $2}' ~/memory/ddv-vm-wallets/ddv-mac-1-guest-login.txt \
#                   | MAC=ddv-mac-2 MHOST=ddv-mac-host-2 bash scripts/e2e/mac/prompt-proof.sh <evidence-dir>
# The password arrives on stdin only and goes to the host's vmctl.py type-stdin (never argv, never a log).
set -uo pipefail
MAC=${MAC:-ddv-mac-dv}; MHOST=${MHOST:-ddv-mac-host-dv}
OUT=${1:?evidence dir}; mkdir -p "$OUT"
IFS= read -r PW || { echo 'no password on stdin' >&2; exit 2; }
[ -n "$PW" ] || { echo 'no password on stdin' >&2; exit 2; }
PASS=0; FAIL=0
rec() { if [ "$1" = PASS ]; then PASS=$((PASS + 1)); echo "ok   $2"; else FAIL=$((FAIL + 1)); echo "FAIL $2 :: ${3:-}"; fi; printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$OUT/prompt.tsv"; }
: > "$OUT/prompt.tsv"

# start <tag>: the CLI root step in the GUI session (launchctl asuser), detached; output to ~/prompt-<tag>.txt
start() {
  ssh "$MAC" "U=\$(id -u); rm -f ~/prompt-$1.txt ~/prompt-$1.code
sudo launchctl asuser \$U sudo -u \$(id -un) /bin/bash -c 'export DVPN_ELEVATOR=osascript PATH=\"/Applications/Devnet dVPN.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin\" DVPN_KEYFILE=\$HOME/.ddv/test-wallet.json DVPN_DATA_DIR=\$HOME/ddv-data
devnet-dvpn daemon set --dns cloudflare --yes > ~/prompt-$1.txt 2>&1; echo \$? > ~/prompt-$1.code' > /dev/null 2>&1 &
echo started"
}
shot() { ssh "$MHOST" "python3 ~/vmctl.py shot /tmp/prompt-$1.png >/dev/null && cat /tmp/prompt-$1.png" > "$OUT/prompt-$1.png"; }
wait_code() { # <tag> → exit code of the CLI (or 'timeout')
  local i
  for i in $(seq 1 60); do
    c=$(ssh "$MAC" "cat ~/prompt-$1.code 2>/dev/null") && [ -n "$c" ] && { echo "$c"; return; }
    sleep 3
  done
  echo timeout
}
dialog_up() { ssh "$MAC" 'pgrep -x SecurityAgent >/dev/null || pgrep -f "osascript.*administrator" >/dev/null' ; }

# ─── answer ───
start answer >/dev/null; sleep 8
if dialog_up; then rec PASS 'answer: the password dialog is up (SecurityAgent)'; else rec FAIL 'answer: the password dialog is up (SecurityAgent)'; fi
shot answer-dialog
printf '%s\n' "$PW" | ssh "$MHOST" 'python3 ~/vmctl.py type-stdin'
ssh "$MHOST" 'python3 ~/vmctl.py key ret' >/dev/null
code=$(wait_code answer); txt=$(ssh "$MAC" 'cat ~/prompt-answer.txt' | grep -v '^\[rpc\]')
printf '%s\n(exit %s)\n' "$txt" "$code" > "$OUT/prompt-answer.txt"
echo "FIRED: answer, the admin dialog got the password + Return from the host keyboard; root step exit $code"
[ "$code" = 0 ] && rec PASS 'answer: the root step applied after the password (exit 0)' || rec FAIL 'answer: the root step applied after the password (exit 0)' "exit $code: $txt"
sleep 25 # the service restarts after a settings change

# ─── cancel ───
start cancel >/dev/null; sleep 8
if dialog_up; then rec PASS 'cancel: the password dialog is up'; else rec FAIL 'cancel: the password dialog is up'; fi
shot cancel-dialog
ssh "$MHOST" 'python3 ~/vmctl.py key esc' >/dev/null
code=$(wait_code cancel); txt=$(ssh "$MAC" 'cat ~/prompt-cancel.txt' | grep -v '^\[rpc\]')
printf '%s\n(exit %s)\n' "$txt" "$code" > "$OUT/prompt-cancel.txt"
echo "FIRED: cancel, the admin dialog got Esc from the host keyboard; root step exit $code"
[ "$code" != 0 ] && [ "$code" != timeout ] && rec PASS 'cancel: the step did not run (non-zero exit)' || rec FAIL 'cancel: the step did not run (non-zero exit)' "exit $code"
printf '%s' "$txt" | grep -qiE 'declined or closed|cancel' && rec PASS 'cancel: says it was cancelled, in plain words' || rec FAIL 'cancel: says it was cancelled, in plain words' "$txt"
printf '%s' "$txt" | grep -qE 'Error -128|User canceled|osascript' && rec FAIL 'cancel: no raw osascript text' "$txt" || rec PASS 'cancel: no raw osascript text'
# SecurityAgent outlives a dismissed dialog by a few seconds: poll up to 20 s, then keep a screenshot as evidence
gone=''; for i in $(seq 1 10); do dialog_up || { gone=1; break; }; sleep 2; done
shot cancel-after
[ -n "$gone" ] && rec PASS 'cancel: no dialog left on screen' || rec FAIL 'cancel: no dialog left on screen' "SecurityAgent/osascript still running 20 s after Esc (see prompt-cancel-after.png)"
echo "prompt-proof: passed $PASS  failed $FAIL"
