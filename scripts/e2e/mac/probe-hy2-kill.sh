#!/bin/bash
# ─── Q0304 data probe (Mac): the hysteria2 process dies under kill switch "persist" (run IN the guest) ───
# Not a cell. Records what the Mac does when dvpnd's hysteria2 child is killed with -9 while the kill
# switch is Always: does the tunnel interface survive, is traffic blocked (no leak), what does status /
# the app show. Restores the kill-switch mode, the session and the network after.
# Usage: bash probe-hy2-kill.sh   (from ~/devnet-dvpn-mac, DVPN_KEYFILE set, as cell-guest.sh does)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
case_init probe-hy2kill; case_reset; P=hysteria2
env_init >> "$LOG" 2>&1
hold # the guest dead-man stays off while the kill switch blocks traffic on purpose
ks_mode() { $CLI daemon settings --json 2>/dev/null | grep -oE '"killSwitch" *: *"[a-z]+"' | grep -oE '[a-z]+"$' | tr -d '"'; }
utuns() { ifconfig -l | tr ' ' '\n' | grep '^utun' | tr '\n' ' '; }
hy2() { pgrep -fl 'hysteria' | grep -v probe-hy2 | head -3; }
direct_ok() { curl -4 -s -m 8 -o /dev/null -w '%{http_code}' --interface en0 https://api.ipify.org 2>/dev/null; }
egress_now() { curl -4 -s -m 8 https://api.ipify.org 2>/dev/null; }
snap() { # <label>
  {
    echo "### $1 ($(date -u +%T)Z)"
    echo "hysteria procs: $(hy2 | tr '\n' ';')"
    echo "utun: $(utuns)"
    echo "pf anchor rules: $(anchor_rules)"
    echo "egress (default route): '$(egress_now)'"
    echo "direct via en0 http: '$(direct_ok)'"
    echo "status:"; $CLI status 2>&1 | sed 's/^/  /'
  } | tee -a "$LOG" >> "$OUT/probe-hy2kill.txt"
}
: > "$OUT/probe-hy2kill.txt"
ORIG_KS=$(ks_mode); info 'kill switch mode before' "${ORIG_KS:-unknown}"
utun0=$(utuns); info 'utun before connect' "$utun0"
run 0 '-' 'kill switch = persist (Always)' -- daemon set --kill-switch persist --yes
sleep 4
gap; run 0 'Connected|connected' 'connect hysteria2 (node-4)' -- connect "$(node_of hysteria2)" --units 1 --yes
sleep 6
snap 'connected, before the kill'
pid=$(hy2 | awk 'NR==1{print $1}')
info 'hysteria2 pid' "${pid:-none}"
T0=$(date +%FT%T)
if [ -n "$pid" ]; then sudo -n kill -9 "$pid"; note "killed hysteria2 pid $pid (-9) at $(date -u +%T)Z"; else record FAIL 'find the hysteria2 process' ''; fi
for s in 5 15 30 60; do sleep $(( s - ${prev:-0} )); prev=$s; snap "$s s after the kill"; done
# the app's own view: a screenshot of the main window while the condition holds
DVPN_UI_SCENARIO='sleep=4;shot=hy2-dead' bash "$HERE/ui-smoke.sh" dark "$OUT/probe-hy2kill-ui" >> "$LOG" 2>&1
info 'app screenshot' "$(ls "$OUT/probe-hy2kill-ui" 2>/dev/null | grep -i png | tr '\n' ' ')"
sudo -n grep -F '"time":"' /Library/Logs/DevnetDVPN/dvpnd.log | awk -v t="$T0" 'substr($0, index($0,"\"time\":\"")+8, 19) >= t' \
  | grep -vE '(started|finished) call|accepted (udp|tcp):' | sed -E 's/(api-key=)[^&" ]+/\1<redacted>/g' > "$OUT/probe-hy2kill-dvpnd.jsonl"
info 'dvpnd lines since the kill' "$(wc -l < "$OUT/probe-hy2kill-dvpnd.jsonl")"
# ─── restore ───
run 0 '-' 'disconnect' -- disconnect
sleep 4
[ "$(ks_mode)" = "$ORIG_KS" ] || $CLI daemon set --kill-switch "$ORIG_KS" --yes >> "$LOG" 2>&1
$CLI daemon restore-network >> "$LOG" 2>&1; sleep 5
check "restored: kill switch $ORIG_KS, no session, direct egress" bash -c \
  "[ \"\$($CLI daemon settings --json 2>/dev/null | grep -oE '\"killSwitch\" *: *\"[a-z]+\"' | grep -oE '[a-z]+\"\$' | tr -d '\"')\" = '$ORIG_KS' ] && $CLI status | grep -qE '^Session +Not connected' && for i in 1 2 3 4 5; do [ \"\$(curl -4 -s -m 10 https://api.ipify.org)\" = '$DIRECT' ] && exit 0; sleep 4; done; exit 1"
summary
