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
  # Evidence only (W31 P1, rc.10): modes + ACLs of the service home and the log, no verdict. Names and modes only.
  { sudo ls -le "/Library/Application Support/sentinel-dvpn/c0"; sudo ls -le /Library/Logs/DevnetDVPN; } >"$EV/home_perms.out" 2>&1
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
  # Runner limit (run 44808199308): GitHub's macOS runners block NTP (sntp: "Exchange failed: Timeout" to
  # time.apple.com:123), so the sntp line cannot be proven here; the clock goes back from the saved time instead.
  local ntp_blocked=no; grep -q 'Exchange failed: Timeout' "$EV/clock_fix.out" && ntp_blocked=yes
  local back=$fixed
  if [ "$fixed" != yes ]; then
    sudo date -u "$(date -u -r $(( $(date -u +%s) - 600 )) +%m%d%H%M%Y.%S)" >>"$EV/clock_fix.out" 2>&1   # undo the +10 min
    run clock_restored_doctor daemon doctor
    [ "$(doctor_level clock)" = ok ] && back=yes
  fi
  sudo systemsetup -setusingnetworktime on >>"$EV/clock_ntp_off.out" 2>&1
  RC=$rc_up
  if [ "$code" = clock-skew ] && echo "$nx" | grep -q '^sudo sntp -sS time.apple.com, then' && [ "$dclk" = fail ] && [ "$fixed" = yes ]; then
    record clock_skew PASS "+10 min: code clock-skew (exit $rc_up), next = '$nx', doctor clock fail; sntp line fixed it (doctor clock ok)"
  elif [ "$code" = clock-skew ] && echo "$nx" | grep -q '^sudo sntp -sS time.apple.com, then' && [ "$dclk" = fail ] && [ "$ntp_blocked" = yes ] && [ "$back" = yes ]; then
    record clock_skew PASS "+10 min: code clock-skew (exit $rc_up), next = '$nx', doctor clock fail. RUNNER LIMIT: NTP blocked (sntp timeout), so the sntp fix is not provable here; clock put back by hand, doctor clock ok"
  else record clock_skew DIFFERS "code='$code' next='$nx' doctor clock='$dclk' sntp fixed=$fixed ntp_blocked=$ntp_blocked back=$back"; fi
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
    # PF-DEAD-3 evidence: launchd's view of the killed service (state, runs, last exit, any throttled spawn) and when
    { date -u +%T; sudo launchctl print "system/$LD_LABEL" 2>&1 | grep -E "state =|runs =|last exit|spawn|throttle" ; } >"$EV/pf_launchd.out"
    run pf_restore1 daemon restore-network
    { date -u +%T; sudo launchctl print "system/$LD_LABEL" 2>&1 | grep -E "state =|runs =|last exit|spawn|throttle" ; } >>"$EV/pf_launchd.out"
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

# ─── E-ST owner (#38 rc.9): owner A's service, a fresh data dir + wallet B, the same device key ───
# Claim: agent up as wallet B in a NEW data dir adopts the installed device key (no new key), the install step sets
# the service owner to B, and B connects; back in A's data dir, daemon install sets it to A again and A connects.
# Before b1750da48 the service kept owner = A and B never connected. Spend: A sends B SWITCH_SOL + SWITCH_TDVPN; B
# opens one deposit; at the end B sends its tDVPN and spare SOL back to A. B's key never leaves the runner and is
# deleted at the end; only its ADDRESS is kept in switch.out (its closing deposit's refund is lost with it).
SWITCH_SOL=${SWITCH_SOL:-0.08}; SWITCH_TDVPN=${SWITCH_TDVPN:-2}
runb() { # runb <row> <cli args…>: like run, as wallet B in its own data dir
  local row=$1; shift
  OUT=$(DVPN_KEYFILE="$SW_KEY" DVPN_DATA_DIR="$SW_DATA" "$CLI" "$@" --json 2>"$EV/$row.err"); RC=$?
  { echo "\$ [wallet B] $CLI $* --json   (exit $RC)"; echo "$OUT"; echo '--- stderr ---'; cat "$EV/$row.err"; } >"$EV/$row.out"
  rm -f "$EV/$row.err"
}
row_wallet_switch() {
  local a b dev0 devb mp upb downb upa back tdv sol keep rc_final nb na
  [ "$(get up_rc)" = 0 ] || { RC=1; record wallet_switch DIFFERS "skipped: the plain agent up failed"; return; }
  a=$("$CLI" agent status --json 2>/dev/null | jq -r '.address // empty')
  dev0=$("$CLI" agent status --json 2>/dev/null | jq -r '.device // empty')
  SW_DATA="$HOME/ddv-data-b"; SW_KEY="$HOME/ddv-key-b/b.json"
  rm -rf "$SW_DATA" "$HOME/ddv-key-b"; mkdir -p "$SW_DATA"; (umask 077; mkdir -p "$HOME/ddv-key-b")
  runb sw_create wallet create --keyfile "$SW_KEY" --yes
  b=$(echo "$OUT" | jq -r '[.. | objects | .address? // empty] | .[0] // empty' 2>/dev/null)
  if [ -z "$b" ] || [ ! -f "$SW_KEY" ]; then RC=1; record wallet_switch DIFFERS "wallet B could not be created (see sw_create.out)"; rm -rf "$SW_DATA" "$HOME/ddv-key-b"; return; fi
  chmod 600 "$SW_KEY"
  # until its funds are back with A, a copy waits in $LEFTOVER (the EXIT trap / if: always() step empties it, then deletes)
  (umask 077; cp -p "$SW_KEY" "$LEFTOVER/b-$b.json")
  gap; run sw_fund_sol wallet send --to "$b" --sol "$SWITCH_SOL" --yes
  gap; run sw_fund_tdvpn wallet send --to "$b" --tdvpn "$SWITCH_TDVPN" --yes
  mp=$(get max_price)
  # rc9-d (lead): start from agent status and follow its printed next (setup steps only), as a user or an agent would.
  # The service runs for A, so B's status names `device switch --yes` (wallet-switch-needed); it points the service at B.
  gap; follow_nexts runb sw_b; nb=$FOLLOWED
  wait_service 90 >/dev/null
  gap
  if [ -n "$mp" ]; then runb sw_up_b agent up --max-price "$mp" --yes; else runb sw_up_b agent up --yes; fi; upb=$RC
  devb=$(DVPN_KEYFILE="$SW_KEY" DVPN_DATA_DIR="$SW_DATA" "$CLI" agent status --json 2>/dev/null | jq -r '.device // empty')
  gap; runb sw_down_b agent down --yes; downb=$RC
  # back to A: now the service runs for B, so A's status names the switch back; follow it the same way
  gap; follow_nexts run sw_a; na=$FOLLOWED; back=$FOLLOW_RC
  wait_service 90 >/dev/null
  gap
  if [ -n "$mp" ]; then run sw_up_a agent up --max-price "$mp" --yes; else run sw_up_a agent up --yes; fi; upa=$RC
  gap; run sw_down_a agent down --yes
  # B's funds back to A: all its tDVPN, then all its SOL less the fee (--allow-empty: runs 44843609674 + 44846196847 were
  # refused low-sol-after and stranded the SOL). sweep_leftovers re-checks the balance before the key is deleted.
  tdv=$(DVPN_KEYFILE="$SW_KEY" DVPN_DATA_DIR="$SW_DATA" "$CLI" agent status --json 2>/dev/null | jq -r '.tdvpn // "0"')
  if [ -n "$tdv" ] && [ "$tdv" != 0 ]; then gap; runb sw_back_tdvpn wallet send --to "$a" --tdvpn "$tdv" --yes; fi
  sol=$(DVPN_KEYFILE="$SW_KEY" DVPN_DATA_DIR="$SW_DATA" "$CLI" agent status --json 2>/dev/null | jq -r '.sol // "0"')
  keep=$(echo "$sol" | awk '{ v = $1 - 0.00001; if (v > 0) printf "%.9f", v; else print "" }')
  if [ -n "$keep" ]; then gap; runb sw_back_sol wallet send --to "$a" --sol "$keep" --allow-empty --yes; fi
  { echo "owner A=$a wallet B=$b"; echo "device before=$dev0 device as B=$devb"; echo "B followed: ${nb:-nothing}"; echo "A followed: ${na:-nothing}";
    echo "up_b=$upb down_b=$downb switch_back_a=$back up_a=$upa";
    echo "B left: tdvpn sent back=${tdv:-0} sol sent back=${keep:-0}"; } >"$EV/switch.out"
  rm -P "$SW_KEY" 2>/dev/null; rm -rf "$SW_DATA" "$HOME/ddv-key-b"
  rc_final=$upb; RC=$rc_final
  if [ "$upb" = 0 ] && [ -n "$dev0" ] && [ "$devb" = "$dev0" ] && [ "$back" = 0 ] && [ "$upa" = 0 ] && [[ "$nb" == *'device switch'* ]] && [[ "$na" == *'device switch'* ]]; then
    record wallet_switch PASS "fresh data dir + wallet $b on owner $a's service, following agent status: B ${nb}then connected on the same device $dev0; A ${na}then connected"
  else record wallet_switch DIFFERS "B followed '${nb:-nothing}' up_b=$upb device_b='$devb' (was '$dev0'); A followed '${na:-nothing}' back=$back up_a=$upa (see switch.out)"; fi
}

# follow_nexts <run|runb> <prefix>: from agent status, run each printed next while it is a setup step (the next of a
# step that failed too, e.g. no-device -> device setup), at most 6 steps and never the same step twice in a row;
# sets FOLLOWED ("[step -> exit] ...") and FOLLOW_RC (the last step's exit, 0 when none was needed).
setup_step() { local c=${1%%, then *}; c=${c#"$CLI "}; c=${c#devnet-dvpn }
  case "$c" in 'device switch --yes'|'daemon install --yes'|'device setup --yes') printf '%s' "$c" ;; esac; }
follow_nexts() {
  local runner=$1 p=$2 i cmd prev=''
  FOLLOWED=''; FOLLOW_RC=0
  "$runner" "${p}_status0" agent status
  for i in 1 2 3 4 5 6; do
    cmd=$(setup_step "$(echo "$OUT" | jq -r '.next // .action // empty' 2>/dev/null)")
    [ -n "$cmd" ] || return 0
    [ "$cmd" != "$prev" ] || { FOLLOW_RC=1; FOLLOWED="$FOLLOWED[loop: $cmd again] "; return 0; }
    gap; "$runner" "${p}_next$i" $cmd; FOLLOW_RC=$RC; FOLLOWED="$FOLLOWED[$cmd -> $RC] "; prev=$cmd
    # a failed step's own next is followed; after a step that worked, status says what comes next
    if [ "$RC" = 0 ]; then "$runner" "${p}_status$i" agent status; prev=''; fi
  done
  FOLLOW_RC=1; FOLLOWED="$FOLLOWED[stopped after 6] "
}

# ─── C1 / C2 (AC-MAC-1 P2-1 / P2-2) by behaviour, as root: a planted link is refused, its target untouched ───
# The darwin unit tests only grep the script text (AC-BLIND). Here the SHIPPED scripts run as root against a test
# instance home "$SVC_ROOT/c9" (never c0: both refusals come before any service stop or write to the real home).
SVC_ROOT=${SVC_ROOT:-/Library/Application Support/sentinel-dvpn}
SCRIPTS=${SCRIPTS:-$APP/Contents/Resources/resources/scripts}
sha_of() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
# write_result (_lib.sh) writes only to a .../devnet-dvpn-<x>/result.json path (run 44843609674: "refusing result path"), so the
# rows use that shape; the script's own stderr line is the fallback (it says the same thing).
result_detail() { local d; d=$(sudo -n cat "$1" 2>/dev/null | jq -r '.error // .detail // .status // empty' 2>/dev/null); [ -n "$d" ] || d=$(grep -v '^refusing result path' "$2" 2>/dev/null | tail -1); printf '%s' "$d"; }
row_c1_setup_links() {
  local dvpnd w tgt t0 t1 res1 res2 rc1 rc2 d1 d2 home="$SVC_ROOT/c9"
  dvpnd=$(find "$APP/Contents/Resources/resources" -name sentinel-dvpnd -type f 2>/dev/null | head -1)
  [ -n "$dvpnd" ] || { RC=1; record c1_setup_links DIFFERS "no sentinel-dvpnd in $APP"; return; }
  sudo -n test -e "$home" && { RC=1; record c1_setup_links DIFFERS "test home $home already exists; not touching it"; return; }
  w=$(mktemp -d "$HOME/c1.XXXXXX"); tgt="$w/target.txt"; echo "root must never write here" >"$tgt"; t0=$(sha_of "$tgt")
  # (a) a link INSIDE the staged home (device.pub -> the target)
  mkdir -p "$w/a/daemon-staging"; echo 'owner = "x"' >"$w/a/daemon-staging/config.toml"; ln -s "$tgt" "$w/a/daemon-staging/device.pub"
  mkdir -p "$w/devnet-dvpn-c1a"; res1="$w/devnet-dvpn-c1a/result.json"
  sudo -n /bin/bash "$SCRIPTS/setup-daemon.sh" --Dvpnd "$dvpnd" --Staging "$w/a/daemon-staging" --DaemonHome "$home" \
    --BinRoot "$(dirname "$dvpnd")" --Group sentinel-dvpn --Service sentinel-dvpnd --Instance c9 --User "$(id -un)" --Result "$res1" >"$EV/c1_a.out" 2>&1; rc1=$?
  d1=$(result_detail "$res1" "$EV/c1_a.out")
  # (b) the staging folder itself is a link (to a folder holding a config)
  mkdir -p "$w/real/daemon-staging"; echo 'owner = "x"' >"$w/real/daemon-staging/config.toml"; mkdir -p "$w/b"; ln -s "$w/real/daemon-staging" "$w/b/daemon-staging"
  mkdir -p "$w/devnet-dvpn-c1b"; res2="$w/devnet-dvpn-c1b/result.json"
  sudo -n /bin/bash "$SCRIPTS/setup-daemon.sh" --Dvpnd "$dvpnd" --Staging "$w/b/daemon-staging" --DaemonHome "$home" \
    --BinRoot "$(dirname "$dvpnd")" --Group sentinel-dvpn --Service sentinel-dvpnd --Instance c9 --User "$(id -un)" --Result "$res2" >"$EV/c1_b.out" 2>&1; rc2=$?
  d2=$(result_detail "$res2" "$EV/c1_b.out")
  t1=$(sha_of "$tgt")
  sudo -n rm -rf -- "$home"; rm -rf -- "$w"
  { echo "a: rc=$rc1 detail=$d1"; echo "b: rc=$rc2 detail=$d2"; echo "target sha before=$t0 after=$t1"; } >>"$EV/c1_setup_links.out"
  RC=$rc1
  if [ "$rc1" != 0 ] && echo "$d1" | grep -q 'holds a symbolic link' && [ "$rc2" != 0 ] && echo "$d2" | grep -q 'unsafe staging folder' && [ "$t0" = "$t1" ]; then
    record c1_setup_links PASS "link in the staged home refused ('$d1'); linked staging folder refused ('$d2'); target sha256 unchanged"
  else record c1_setup_links DIFFERS "a rc=$rc1 '$d1'; b rc=$rc2 '$d2'; target before=$t0 after=$t1 (see c1_setup_links.out)"; fi
}
row_c2_apply_link() {
  local w tgt t0 t1 c0 c1 res rc d home="$SVC_ROOT/c9"
  sudo -n test -e "$home" && { RC=1; record c2_apply_link DIFFERS "test home $home already exists; not touching it"; return; }
  sudo -n mkdir -p "$home" && echo 'owner = "test-home"' | sudo -n tee "$home/config.toml" >/dev/null
  c0=$(sudo -n shasum -a 256 "$home/config.toml" | cut -d' ' -f1)
  w=$(mktemp -d "$HOME/c2.XXXXXX"); tgt="$w/target.txt"; echo "root must never read this into a config" >"$tgt"; t0=$(sha_of "$tgt")
  mkdir -p "$w/staged"; ln -s "$tgt" "$w/staged/config.toml"
  mkdir -p "$w/devnet-dvpn-c2"; res="$w/devnet-dvpn-c2/result.json"
  sudo -n /bin/bash "$SCRIPTS/apply-daemon-config.sh" --Staged "$w/staged" --DaemonHome "$home" --Result "$res" >"$EV/c2.out" 2>&1; rc=$?
  d=$(result_detail "$res" "$EV/c2.out"); t1=$(sha_of "$tgt"); c1=$(sudo -n shasum -a 256 "$home/config.toml" | cut -d' ' -f1)
  sudo -n rm -rf -- "$home"; rm -rf -- "$w"
  { echo "rc=$rc detail=$d"; echo "target sha before=$t0 after=$t1"; echo "test config sha before=$c0 after=$c1"; } >>"$EV/c2_apply_link.out"
  RC=$rc
  if [ "$rc" != 0 ] && echo "$d" | grep -q 'not a plain file' && [ "$t0" = "$t1" ] && [ "$c0" = "$c1" ]; then
    record c2_apply_link PASS "a linked staged config.toml refused ('$d'); link target and the home's config.toml unchanged (sha256)"
  else record c2_apply_link DIFFERS "rc=$rc '$d'; target $t0→$t1; config $c0→$c1 (see c2_apply_link.out)"; fi
}

# ─── A1 / A2: the hub's INSTALL-BY-HAND macOS block (docs/INSTALL-BY-HAND.md), checksum first, then install ───
# The block as published, word for word, except the destination: "$HB_APPS/Devnet dVPN.app" in place of
# /Applications (the CI-built rc.9 app there runs the other rows). Negative control: a tampered dmg from a local
# mirror must print "checksum mismatch: install nothing" and install nothing.
HB_RELEASE=${HB_RELEASE:-v0.3.0-rc8}
hand_block() { # hand_block <U> <apps dir>: lines 29-43 of the page, /Applications -> $2
  local U=$1 HB_APPS=$2 A F M
  A=x64; [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] && A=arm64
  curl -fsSLO "$U/SHA256SUMS"
  F=$(awk '{print $2}' SHA256SUMS | grep -E "^Devnet-dVPN-.*-$A\.dmg\$")
  if [ -z "$F" ]; then echo "no $A build in this release (Intel Macs: docs/OLDER-RELEASES.md)"
  elif ! curl -fsSLO "$U/$F"; then echo "download failed: install nothing"
  elif ! grep " $F\$" SHA256SUMS | shasum -a 256 -c -; then echo "checksum mismatch: install nothing"
  else
  M=$(hdiutil attach -nobrowse -readonly "./$F" | tail -1 | cut -f3-)
  sudo -n ditto "$M/Devnet dVPN.app" "$HB_APPS/Devnet dVPN.app"
  hdiutil detach -quiet "$M"
  sudo -n xattr -dr com.apple.quarantine "$HB_APPS/Devnet dVPN.app"
  export PATH="$HB_APPS/Devnet dVPN.app/Contents/Resources/bin:$PATH"
  brew install wireguard-tools wireguard-go openvpn bash
  fi
}
row_install_by_hand() {
  local w ok_out bad_out v f
  w=$(mktemp -d "$HOME/hb.XXXXXX"); mkdir -p "$w/good" "$w/apps" "$w/mirror" "$w/bad" "$w/apps-bad"
  (cd "$w/good" && hand_block "https://github.com/Sentinel-Bluebuilder/sentinel-solana-dvpn-macos/releases/download/$HB_RELEASE" "$w/apps") >"$EV/hand_good.out" 2>&1
  ok_out=$(cat "$EV/hand_good.out")
  v=$("$w/apps/Devnet dVPN.app/Contents/Resources/bin/devnet-dvpn" version --json 2>/dev/null | jq -r '.. | strings | select(test("^0\\.3\\.0"))' 2>/dev/null | head -1)
  # negative control: the same SHA256SUMS, a dmg with one byte appended
  f=$(ls "$w/good"/Devnet-dVPN-*.dmg 2>/dev/null | head -1)
  if [ -n "$f" ]; then cp "$w/good/SHA256SUMS" "$w/mirror/"; cp "$f" "$w/mirror/"; printf x >>"$w/mirror/$(basename "$f")"; fi
  (cd "$w/bad" && hand_block "file://$w/mirror" "$w/apps-bad") >"$EV/hand_bad.out" 2>&1
  bad_out=$(cat "$EV/hand_bad.out")
  RC=0
  if echo "$ok_out" | grep -q ': OK$' && [ -n "$v" ] && echo "$bad_out" | grep -q 'checksum mismatch: install nothing' && [ ! -e "$w/apps-bad/Devnet dVPN.app" ]; then
    record install_by_hand PASS "$HB_RELEASE: checksum OK then installed (devnet-dvpn version $v); tampered dmg: 'checksum mismatch: install nothing', nothing installed"
  else RC=1; record install_by_hand DIFFERS "good: $(echo "$ok_out" | grep -E ': OK$|mismatch|failed|no ' | head -1) version='$v'; tampered: $(echo "$bad_out" | grep -E 'mismatch|OK$' | head -1) (see hand_good.out, hand_bad.out)"; fi
  sudo -n rm -rf -- "$w"
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

ROWS="$ROWS doctor_rows c1_setup_links c2_apply_link launchd_print launchd_stopped clock_skew pf_restore wallet_switch gui_smoke install_by_hand"
