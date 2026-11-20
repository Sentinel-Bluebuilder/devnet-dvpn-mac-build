#!/bin/bash
# ─── gha-live.sh: rc.8 live rows on a GitHub Actions macOS runner (#38 macOS test-score row) ───
# Owner of this file: AC-MAC-2. Runs ON the runner after the .dmg is installed (job `live`).
# Each row is ONE function `row_<name>`; it calls `record` once. Others (AC-MAC-3: clock, launchd,
# keychain, GUI smoke) add rows by defining `row_<name>` functions and listing them in ROWS, or in
# EXTRA_ROWS (env) / a sourced file EXTRA_ROWS_FILE — no edit of the existing rows needed.
# Output: evidence/<row>.out (raw CLI output), evidence/rows.jsonl (one JSON line per row),
# evidence/RESULT.md (PASS / DIFFERS table). The script never prints the key; DVPN_KEYFILE is a path.
# Always ends with `agent down --yes` + `daemon restore-network` (trap EXIT), key mode back to 600.
# Apple's /bin/bash 3.2 compatible: no associative arrays, no ${x,,}.
set -u

# ─── Setup ───
export PATH="/Applications/Devnet dVPN.app/Contents/Resources/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
CLI=${CLI:-devnet-dvpn}
: "${DVPN_KEYFILE:?DVPN_KEYFILE must name the 0600 key file written from the DVPN_TEST_KEY secret}"
export DVPN_KEYFILE
export DVPN_DATA_DIR=${DVPN_DATA_DIR:-$HOME/ddv-data}
EXPECT_VERSION=${EXPECT_VERSION:-0.3.0-rc.8}
SEND_TO=${SEND_TO:-9enW4xCJrmytnEC6VsJYPbcT2ng3QTUwUkAHSrKR9Xrj}   # #28 devnet wallet (previews only, nothing sent)
SYSTEM_PROGRAM=11111111111111111111111111111111
EV=${EVIDENCE_DIR:-evidence}
mkdir -p "$EV" "$DVPN_DATA_DIR"
: >"$EV/rows.jsonl"
STATE="$EV/.state"; : >"$STATE"   # key=value shared between rows (home ip, max price, …)
HOME_IP=''

# ─── Helpers ───
put() { echo "$1=$2" >>"$STATE"; }
get() { grep "^$1=" "$STATE" | tail -1 | cut -d= -f2-; }

# run <row> <cli args…>: run the CLI with --json, keep stdout+stderr in $EV/<row>.out, set RC and OUT
run() {
  local row=$1; shift
  OUT=$("$CLI" "$@" --json 2>"$EV/$row.err"); RC=$?
  { echo "\$ $CLI $* --json   (exit $RC)"; echo "$OUT"; echo '--- stderr ---'; cat "$EV/$row.err"; } >"$EV/$row.out"
  rm -f "$EV/$row.err"
}

# record <row> <PASS|DIFFERS> <detail>: one JSON line in rows.jsonl
record() {
  local row=$1 verdict=$2 detail=$3
  jq -cn --arg row "$row" --arg verdict "$verdict" --arg detail "$detail" --argjson rc "${RC:-0}" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{row:$row,verdict:$verdict,rc:$rc,detail:$detail,at:$at}' >>"$EV/rows.jsonl"
  echo "[$verdict] $row — $detail"
}

# expect <row> <cond-rc> <regex> <pass detail> <differs detail>: PASS when RC matches and OUT matches regex
expect() {
  local row=$1 want=$2 re=$3 okmsg=$4 badmsg=$5
  if { [ "$want" = any ] || [ "$RC" = "$want" ]; } && echo "$OUT" | grep -Eqi -- "$re"; then record "$row" PASS "$okmsg"
  else record "$row" DIFFERS "$badmsg (exit $RC): $(echo "$OUT" | head -c 300)"; fi
}

TX_GAP=${TX_GAP:-7}   # devnet rule: 7 s between transactions
gap() { sleep "$TX_GAP"; }

ipv4() { grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1; }

# ─── Rows: core flow ───
row_version() {
  run version version
  expect version 0 "$EXPECT_VERSION" "version $EXPECT_VERSION" "version is not $EXPECT_VERSION"
  echo "$OUT" | grep -qi devnet || record version_network DIFFERS "no devnet network/ids in version output"
}

row_home_ip() {
  HOME_IP=$(curl -s --max-time 20 https://api.ipify.org); RC=$?
  echo "$HOME_IP" >"$EV/home_ip.out"; put home_ip "$HOME_IP"
  if echo "$HOME_IP" | ipv4 >/dev/null && [ -n "$HOME_IP" ]; then record home_ip PASS "home IP $HOME_IP"
  else record home_ip DIFFERS "no home IP from api.ipify.org"; fi
}

row_init() { run init daemon init --yes; expect init 0 . "device key created" "daemon init failed"; }

row_setup() {
  run setup device setup --yes
  expect setup 0 . "device set up (grant + fee SOL)" "device setup failed"
}

# rc.8: the plain setup above defaults the allowance to 150 tDVPN and refuses a 60 tDVPN wallet (W91,
# fixed in rc.9: that row must flip to PASS there). This explicit allowance lets install + doctor run.
row_setup_allowance() {
  gap
  run setup_allowance device setup --allowance "${SETUP_ALLOWANCE:-50}" --yes
  expect setup_allowance 0 . "device set up with --allowance ${SETUP_ALLOWANCE:-50}" "device setup --allowance ${SETUP_ALLOWANCE:-50} failed"
}

row_install() {
  run install daemon install --yes
  expect install 0 . "service installed/updated and started" "daemon install failed"
}

row_doctor() {
  run doctor daemon doctor
  if [ "$RC" = 0 ] && ! echo "$OUT" | grep -Eq '"(status|level|result)" *: *"fail"'; then record doctor PASS "no failing check"
  else record doctor DIFFERS "doctor reports a failure (exit $RC): $(echo "$OUT" | head -c 300)"; fi
}

row_up() {
  # The price comes from the preview: its refusal or next line names --max-price when the default cap is hit;
  # otherwise the cheapest online per-GB price from nodes list (rounded up to 6 decimals).
  run up_preview agent up
  local mp
  mp=$(echo "$OUT" | grep -Eo -- '--max-price [0-9.]+' | head -1 | awk '{print $2}')
  if [ -z "$mp" ]; then
    run nodes_list nodes list --online --sort price --limit 5
    mp=$(echo "$OUT" | jq -r '[.. | objects | .pricePerGbText? // .pricePerGbTdvpn? // empty] | .[0] // empty' 2>/dev/null | grep -Eo '[0-9.]+' | head -1)
  fi
  put max_price "${mp:-}"
  gap
  if [ -n "$mp" ]; then run up agent up --max-price "$mp" --yes; else run up agent up --yes; fi
  if [ "$RC" = 0 ]; then record up PASS "connected${mp:+ at --max-price $mp}"
  else record up DIFFERS "tunnel did not start (named finding, no retry) (exit $RC): $(echo "$OUT" | head -c 400)"; fi
  put up_rc "$RC"
}

row_exit_ip() {
  [ "$(get up_rc)" = 0 ] || { RC=1; record exit_ip DIFFERS "skipped: agent up failed"; return; }
  run exit_ip quality ip
  local ip; ip=$(echo "$OUT" | ipv4)
  HOME_IP=${HOME_IP:-$(get home_ip)}
  if [ -n "$ip" ] && [ "$ip" != "$HOME_IP" ]; then record exit_ip PASS "exit IP $ip ≠ home $HOME_IP"
  else record exit_ip DIFFERS "exit IP '$ip' vs home '$HOME_IP'"; fi
}

row_status() {
  [ "$(get up_rc)" = 0 ] || { RC=1; record status DIFFERS "skipped: agent up failed"; return; }
  run status agent status
  expect status 0 '"session"' "agent status shows the session" "agent status has no session"
}

row_down() {
  [ "$(get up_rc)" = 0 ] || { RC=1; record down DIFFERS "skipped: agent up failed"; return; }
  gap
  run down agent down --yes
  expect down 0 . "disconnected, deposits closing" "agent down failed"
  date -u +%Y-%m-%dT%H:%M:%SZ >"$EV/down_at.out"
  run status_after agent status
  local nx; nx=$(echo "$OUT" | jq -r '.next // empty' 2>/dev/null)
  if echo "$nx" | grep -qi settle; then record status_next PASS "next = $nx"
  else record status_next DIFFERS "next is not the settle line: '$nx'"; fi
}

# ─── Rows: edges (no money moves) ───
row_usage_exit3() {
  run usage_exit3 agent up --bogus
  expect usage_exit3 3 . "unknown flag → usage, exit 3" "unknown flag did not exit 3"
}

row_send_above_balance() {
  run send_above_balance wallet send --to "$SEND_TO" --tdvpn 999999
  if [ "$RC" != 0 ] && ! echo "$OUT" | grep -qi '"signature"'; then record send_above_balance PASS "refused, nothing sent"
  else record send_above_balance DIFFERS "not refused (exit $RC): $(echo "$OUT" | head -c 300)"; fi
}

row_send_system_program() {
  run send_system_program wallet send --to "$SYSTEM_PROGRAM" --tdvpn 1
  expect send_system_program any 'system program' "refused: the Solana system program" "system-program send not refused"
}

row_send_sol_no_fees() {
  run wallet_show wallet show
  # wallet show --json gives the owner's balance as ownerLamports; send = balance − 1000 lamports,
  # so the send fits the balance but leaves no SOL for its fee (the refusal under test).
  local lamports send
  lamports=$(echo "$OUT" | jq -r '.ownerLamports // empty' 2>/dev/null | grep -Eo '^[0-9]+$' | head -1)
  if [ -z "$lamports" ] || [ "$lamports" -le 1000 ]; then
    RC=1; record send_sol_no_fees DIFFERS "no ownerLamports above 1000 in wallet show: $(echo "$OUT" | head -c 200)"; return
  fi
  send=$(awk -v l="$lamports" 'BEGIN{printf "%.9f", (l-1000)/1e9}')
  run send_sol_no_fees wallet send --to "$SEND_TO" --sol "$send"
  expect send_sol_no_fees any 'fees|low-sol-after|allow-empty' "refused: leaves no fee SOL ($send of $lamports lamports)" "SOL send leaving no fees not refused ($send of $lamports lamports)"
}

row_device_plan_above_wallet() {
  run device_plan_above_wallet device plan --allowance 999999
  expect device_plan_above_wallet any 'above|more than|exceed|balance|holds' "plan names the limit above the wallet" "plan does not flag a limit above the wallet"
}

row_keyfile_mode() {
  chmod 644 "$DVPN_KEYFILE"
  run keyfile_mode agent up
  chmod 600 "$DVPN_KEYFILE"
  expect keyfile_mode any 'keyfile-mode|keyfileMode|can be read by other users' "644 key refused (keyfileMode), back to 600" "644 key not refused"
}

# ─── Cleanup: always ───
cleanup() {
  chmod 600 "$DVPN_KEYFILE" 2>/dev/null || echo "cleanup: chmod 600 on the key failed" >&2
  "$CLI" agent down --yes --json >"$EV/cleanup_down.out" 2>&1 || echo "cleanup: agent down exit $?" >&2
  "$CLI" daemon restore-network --json >"$EV/cleanup_restore.out" 2>&1 || echo "cleanup: restore-network exit $?" >&2
  write_result
}

write_result() {
  local pass differs
  pass=$(jq -s '[.[] | select(.verdict=="PASS")] | length' "$EV/rows.jsonl")
  differs=$(jq -s '[.[] | select(.verdict!="PASS")] | length' "$EV/rows.jsonl")
  {
    echo "# macOS GHA live rows — $EXPECT_VERSION"
    echo
    echo "Runner: $(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) $(uname -m) · $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Wallet: $("$CLI" wallet show --json 2>/dev/null | jq -r '[.. | objects | .address? // empty] | .[0] // "?"' 2>/dev/null)"
    echo
    echo "**$pass PASS · $differs DIFFERS**"
    echo
    echo '| Row | Verdict | Exit | Detail |'
    echo '|---|---|---|---|'
    jq -r '"| \(.row) | \(.verdict) | \(.rc) | \(.detail | gsub("\\|";"/") | gsub("\n";" ")) |"' "$EV/rows.jsonl"
  } >"$EV/RESULT.md"
  echo "RESULT: $pass PASS, $differs DIFFERS → $EV/RESULT.md"
}
trap cleanup EXIT

# ─── Order ───
ROWS="version home_ip init setup setup_allowance install doctor up exit_ip status down usage_exit3 send_above_balance send_system_program send_sol_no_fees device_plan_above_wallet keyfile_mode"
[ -n "${EXTRA_ROWS_FILE:-}" ] && [ -f "$EXTRA_ROWS_FILE" ] && . "$EXTRA_ROWS_FILE"
ROWS="$ROWS ${EXTRA_ROWS:-}"
for r in ${ONLY_ROWS:-$ROWS}; do
  if declare -F "row_$r" >/dev/null; then "row_$r"
  else RC=1; record "$r" DIFFERS "no function row_$r"; fi
done
