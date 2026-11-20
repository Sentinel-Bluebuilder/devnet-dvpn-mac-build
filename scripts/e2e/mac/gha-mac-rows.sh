#!/bin/bash
# ─── gha-mac-rows.sh: macOS-only rows for gha-live.sh (#38 rc.8, owner AC-MAC-3) ───
# Sourced by gha-live.sh through EXTRA_ROWS_FILE (set it on the live step). Uses its helpers: run, record, expect,
# get, put, gap, $CLI, $EV. Apple's /bin/bash 3.2 compatible. Every row puts back what it changes (service, clock,
# app) before it returns; gha-live.sh's trap still ends with agent down + restore-network.
# Order: after `down` (no session open), so stopping the service or moving the clock never touches a live tunnel.

LD_LABEL=${LD_LABEL:-co.sentinel.sentinel-dvpnd.c0}
LD_PLIST=${LD_PLIST:-/Library/LaunchDaemons/$LD_LABEL.plist}
APP=${APP:-/Applications/Devnet dVPN.app}

# wait_service <secs>: until the CLI reaches the VPN service (agent status .service == true)
wait_service() {
  local i=0 n=$1
  while [ "$i" -lt "$n" ]; do
    "$CLI" agent status --json 2>/dev/null | jq -e '.service == true' >/dev/null 2>&1 && return 0
    sleep 2; i=$((i + 2))
  done
  return 1
}

# doctor_level <name>: the level of one doctor row ('' if absent)
doctor_level() { echo "$OUT" | jq -r --arg n "$1" '[.. | objects | select(.name? == $n) | .level] | .[0] // empty' 2>/dev/null; }

# ─── daemon doctor: every row, and the macOS service + clock rows ───
row_doctor_rows() {
  run doctor_rows daemon doctor
  echo "$OUT" | jq -r '.. | objects | select(.name? and .level?) | "\(.level)\t\(.name)\t\(.detail)"' >"$EV/doctor_rows.tsv" 2>/dev/null
  local svc clk fails
  svc=$(doctor_level service); clk=$(doctor_level clock)
  fails=$(awk -F'\t' '$1=="fail"{print $2}' "$EV/doctor_rows.tsv" | tr '\n' ' ')
  if [ "$svc" = ok ] && [ "$clk" = ok ] && [ -z "$fails" ]; then record doctor_rows PASS "$(wc -l <"$EV/doctor_rows.tsv" | tr -d ' ') rows, service ok, clock ok, no fail"
  else record doctor_rows DIFFERS "service='$svc' clock='$clk' fail rows: ${fails:-none}"; fi
}

# ─── launchctl print of the LaunchDaemon ───
row_launchd_print() {
  OUT=$(launchctl print "system/$LD_LABEL" 2>&1); RC=$?
  echo "$OUT" >"$EV/launchd_print.out"
  if [ "$RC" = 0 ] && echo "$OUT" | grep -Eq '^[[:space:]]*state = running'; then record launchd_print PASS "system/$LD_LABEL state = running"
  else record launchd_print DIFFERS "not running: $(echo "$OUT" | grep -E 'state =|Could not' | head -2 | tr '\n' ' ')"; fi
}

# ─── stopped service (macOS twin of Linux W47, T-C rows 16/17): next + doctor name the launchctl line, which works ───
row_launchd_stopped() {
  sudo launchctl bootout "system/$LD_LABEL" >"$EV/launchd_bootout.out" 2>&1
  sleep 3
  run launchd_stopped_status agent status
  local nx; nx=$(echo "$OUT" | jq -r '.next // empty' 2>/dev/null)
  run launchd_stopped_doctor daemon doctor
  local dsvc; dsvc=$(echo "$OUT" | jq -r '[.. | objects | select(.name? == "service") | "\(.level): \(.detail)"] | .[0] // empty' 2>/dev/null)
  # Run the printed next verbatim (that is the claim), then the service must answer again.
  local ran=no
  if [ "$nx" = "sudo launchctl bootstrap system $LD_PLIST" ]; then eval "$nx" >"$EV/launchd_restart.out" 2>&1 && ran=yes; fi
  if [ "$ran" != yes ]; then sudo launchctl bootstrap system "$LD_PLIST" >>"$EV/launchd_restart.out" 2>&1 || sudo launchctl kickstart -k "system/$LD_LABEL" >>"$EV/launchd_restart.out" 2>&1; fi
  local back=no; wait_service 60 && back=yes
  RC=0
  if [ "$ran" = yes ] && [ "$back" = yes ] && echo "$dsvc" | grep -q "^fail: .*sudo launchctl bootstrap system $LD_PLIST"; then
    record launchd_stopped PASS "next = '$nx' (ran verbatim, service back); doctor: $dsvc"
  else RC=1; record launchd_stopped DIFFERS "next='$nx' doctor='$dsvc' ran=$ran back=$back"; fi
}

# ─── clock +10 min: clock-skew refused before paying, next = the darwin command, which fixes it ───
row_clock_skew() {
  local t0 mp nx code fixed=no
  t0=$(date -u +%s)
  sudo systemsetup -setusingnetworktime off >"$EV/clock_ntp_off.out" 2>&1   # else timed may step it back mid-row
  sudo date -u "$(date -u -v+10M +%m%d%H%M%Y.%S)" >"$EV/clock_set.out" 2>&1
  mp=$(get max_price)
  if [ -n "$mp" ]; then run clock_skew agent up --max-price "$mp" --yes; else run clock_skew agent up --yes; fi
  # error-out.ts:44 shape is flat ({ok,error:<string>,code,action,next}); never index .error (a string).
  code=$(echo "$OUT" | jq -r '.code // empty' 2>>"$EV/clock_skew.jq.err")
  nx=$(echo "$OUT" | jq -r '.next // .action // empty' 2>>"$EV/clock_skew.jq.err")
  local rc_up=$RC
  run clock_skew_doctor daemon doctor
  local dclk; dclk=$(doctor_level clock)
  # Put the clock back with the printed command itself; fall back to the saved time if it did not.
  sudo sntp -sS time.apple.com >"$EV/clock_fix.out" 2>&1
  run clock_fixed_doctor daemon doctor
  [ "$(doctor_level clock)" = ok ] && fixed=yes
  if [ "$fixed" != yes ]; then sudo date -u "$(date -u -r $((t0 + 60)) +%m%d%H%M%Y.%S)" >>"$EV/clock_fix.out" 2>&1; fi
  sudo systemsetup -setusingnetworktime on >>"$EV/clock_ntp_off.out" 2>&1
  RC=$rc_up
  if [ "$code" = clock-skew ] && echo "$nx" | grep -q '^sudo sntp -sS time.apple.com, then' && [ "$dclk" = fail ] && [ "$fixed" = yes ]; then
    record clock_skew PASS "+10 min: code clock-skew (exit $rc_up), next = '$nx', doctor clock fail; sntp line fixed it (doctor clock ok)"
  else record clock_skew DIFFERS "code='$code' next='$nx' doctor clock='$dclk' sntp fixed=$fixed"; fi
}

# ─── pf restore (AUDIT-FINAL-MACOS M5, fc3842e44): KS on, connect, kill -9 dvpnd, restore-network, KS connect again ───
# Claim: after a dead daemon + Restore network no `anchor "sentinel-dvpn-…"` attach line and no anchor rules are left,
# and the next kill-switch connect works (before M5 it failed closed: "conflicting pf anchor attachment").
# Two paid connects (two deposits, closed by agent down). The block after the kill lasts only until restore-network.
pf_attach_lines() { sudo pfctl -sr 2>/dev/null | grep -E '^anchor "(dvpnd|sentinel-dvpn-)' ; }
pf_anchor_rules() { sudo pfctl -a sentinel-dvpn-c0 -s rules 2>/dev/null; }
row_pf_restore() {
  local mp ks0 up1 up2 att_up att_after anc_after att_end anc_end net
  [ "$(get up_rc)" = 0 ] || { RC=1; record pf_restore DIFFERS "skipped: the plain agent up failed, so a KS connect would too"; return; }
  ks0=$("$CLI" daemon settings --json 2>/dev/null | jq -r '[.. | objects | .killSwitch? // empty] | .[0] // "off"' 2>/dev/null)
  run pf_ks_on daemon set --kill-switch on --yes
  mp=$(get max_price)
  gap
  if [ -n "$mp" ]; then run pf_up1 agent up --max-price "$mp" --yes; else run pf_up1 agent up --yes; fi; up1=$RC
  att_up=$(pf_attach_lines | head -1)
  if [ "$up1" = 0 ]; then
    sudo pkill -9 -x sentinel-dvpnd >"$EV/pf_kill.out" 2>&1 || sudo killall -9 sentinel-dvpnd >>"$EV/pf_kill.out" 2>&1
    sleep 3
    run pf_restore1 daemon restore-network
    wait_service 60 >/dev/null
    att_after=$(pf_attach_lines); anc_after=$(pf_anchor_rules)
    curl -s --max-time 20 https://api.ipify.org >/dev/null && net=yes || net=no
    gap
    if [ -n "$mp" ]; then run pf_up2 agent up --max-price "$mp" --yes; else run pf_up2 agent up --yes; fi; up2=$RC
    gap
    run pf_down agent down --yes
  fi
  run pf_restore2 daemon restore-network
  att_end=$(pf_attach_lines); anc_end=$(pf_anchor_rules)
  run pf_ks_back daemon set --kill-switch "${ks0:-off}" --yes
  { echo "ks0=$ks0 up1=$up1 up2=${up2:-} net_after_restore=${net:-}"; echo "attach while up: $att_up";
    echo "after kill+restore attach: [$att_after] anchor rules: [$anc_after]"; echo "end attach: [$att_end] anchor rules: [$anc_end]";
    echo '--- pfctl -sr (end) ---'; sudo pfctl -sr 2>&1; } >"$EV/pf_restore.out"
  RC=${up2:-$up1}
  if [ "$up1" = 0 ] && [ -z "$att_after" ] && [ -z "$anc_after" ] && [ "$net" = yes ] && [ "${up2:-1}" = 0 ] && [ -z "$att_end" ] && [ -z "$anc_end" ]; then
    record pf_restore PASS "KS connect, kill -9 dvpnd, restore-network: no attach line/anchor rules left, internet back; KS connect again ok; clean at the end"
  else record pf_restore DIFFERS "up1=$up1 attach_after='$att_after' anchor_after='$(echo "$anc_after" | head -1)' net=${net:-} up2=${up2:-none} attach_end='$att_end' (see pf_restore.out)"; fi
}

# ─── GUI smoke: the app opens, a window with its title, a screenshot ───
row_gui_smoke() {
  open "$APP" >"$EV/gui_open.out" 2>&1; RC=$?
  sleep 15
  screencapture -x "$EV/gui.png" >>"$EV/gui_open.out" 2>&1
  local pname title alive
  pname=$(osascript -e 'tell application "System Events" to get name of first process whose bundle identifier contains "devnet"' 2>>"$EV/gui_open.out")
  title=$(osascript -e "tell application \"System Events\" to get name of windows of process \"${pname:-Devnet dVPN}\"" 2>>"$EV/gui_open.out")
  pgrep -f "$APP/Contents/MacOS/" >/dev/null && alive=yes || alive=no
  echo "process='$pname' windows='$title' alive=$alive" >>"$EV/gui_open.out"
  osascript -e "tell application \"${pname:-Devnet dVPN}\" to quit" >>"$EV/gui_open.out" 2>&1 || pkill -f "$APP/Contents/MacOS/" || true
  local png=0; [ -s "$EV/gui.png" ] && png=$(wc -c <"$EV/gui.png" | tr -d ' ')
  if [ "$RC" = 0 ] && [ "$alive" = yes ] && echo "$title" | grep -qi 'dvpn' && [ "$png" -gt 10000 ]; then
    record gui_smoke PASS "window '$title', screenshot gui.png ($png bytes)"
  else record gui_smoke DIFFERS "open rc=$RC alive=$alive windows='$title' png=$png bytes (see gui_open.out)"; fi
}

ROWS="$ROWS doctor_rows launchd_print launchd_stopped clock_skew pf_restore gui_smoke"
