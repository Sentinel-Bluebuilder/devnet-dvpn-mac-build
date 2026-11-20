#!/bin/bash
# ─── M-uifire:<name>: press a critical button in the REAL installed app, check its real effect, restore (run IN the guest) ───
# Owner order 2026-10-29: "present, not fired" and "dialog opened, Cancel closed" are not a pass. Each cell:
#   FIRED   the real button (and its confirm) pressed in the app (ui-smoke.sh + DVPN_UI_SCENARIO, the in-app driver
#           src/main/dev/ui-scenario.ts already in the shipped build: no new build needed)
#   EFFECT  the consequence read from outside the app (CLI chain/service reads, pf anchor, egress, files)
#   RESTORE the guest put back (kill switch mode, settings file, session, network) and checked
# A cell passes only with all three lines OK. Usage: bash uifire.sh <apply|ks-always|restore-network|restore-defaults>
# Env (cell-guest.sh): DVPN_KEYFILE (test wallet, read only), RIG_PASSWORD (Keychain unlock, never printed).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
NAME=${1:?usage: uifire.sh <button>}
case_init "uifire-$NAME"; case_reset; P=ui
UIOUT=$OUT/uifire-$NAME-ui
FIRED=0 EFFECT=0 RESTORED=0

# ui <scenario>: run the installed app with the scenario; every step result goes to the log; exit 0 when all ok
ui() {
  note "scenario: $1"
  DVPN_UI_SCENARIO="$1" DVPN_UI_DIRECT_IP="${DIRECT:-}" DVPN_UI_EXPECT_NODE_IP="$NODE_IP" \
    bash "$HERE/ui-smoke.sh" dark "$UIOUT" >> "$LOG" 2>&1
  [ -s "$UIOUT/scenario.json" ] || { note 'no scenario.json: the app did not run the scenario'; return 1; }
  node -e '
    const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const steps = Array.isArray(r) ? r : (r.steps ?? []);
    for (const s of steps) console.log(`${s.ok ? "step ok  " : "step FAIL"} ${s.step} :: ${String(s.detail ?? "").slice(0, 160)}`);
    process.exit(steps.length && steps.every((s) => s.ok) ? 0 : 1);
  ' "$UIOUT/scenario.json" | tee -a "$LOG"
  return "${PIPESTATUS[0]}"
}
# uio <scenario>: the same, on the fresh onboarding profile ($PROF), no test key file, the setup screen driven
uio() {
  note "onboarding scenario: ${1//\[[0-9,]*\]/<key file>}"
  DVPN_UI_SCENARIO="$1" DVPN_UI_ONBOARD=1 DVPN_KEYFILE="${UIO_KEYFILE:-none}" DVPN_DATA_DIR="${UIO_DATA:-$PROF}" bash "$HERE/ui-smoke.sh" dark "$UIOUT" >> "$LOG" 2>&1
  [ -s "$UIOUT/scenario.json" ] || { note 'no scenario.json: the app did not run the scenario'; return 1; }
  node -e '
    const steps = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    for (const s of steps) console.log(`${s.ok ? "step ok  " : "step FAIL"} ${s.step.replace(/\[[0-9,]+\]/, "<key file>")} :: ${String(s.detail ?? "").slice(0, 160)}`);
    process.exit(steps.length && steps.every((s) => s.ok) ? 0 : 1);
  ' "$UIOUT/scenario.json" | tee -a "$LOG"
  return "${PIPESTATUS[0]}"
}
owner_of() { node -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const o = s.filter((x) => x.step.startsWith("owner") && x.ok).pop(); console.log(o ? o.detail.replace(/^owner /, "") : "")' "$UIOUT/scenario.json" 2>/dev/null; }
unlock_kc() { [ -n "${RIG_PASSWORD:-}" ] && security unlock-keychain -p "$RIG_PASSWORD" ~/Library/Keychains/login.keychain-db 2>/dev/null; return 0; }
ks_mode() { $CLI daemon settings --json 2>/dev/null | grep -oE '"killSwitch" *: *"[a-z]+"' | grep -oE '[a-z]+"$' | tr -d '"'; }
fired() { if [ "$1" = 0 ]; then FIRED=1; record PASS "FIRED: $2" ''; else record FAIL "FIRED: $2" "see $UIOUT/scenario.json"; fi; }
effect() { local d=$1; shift; if check "EFFECT: $d" "$@"; then EFFECT=1; fi; settings_effect; } # + SETTINGS lines read back from the daemon (lib.sh)
restored() { local d=$1; shift; if check "RESTORE: $d" "$@"; then RESTORED=1; fi; }
ks_back() { # <mode>: put the kill switch mode back and release anything it holds
  [ "$(ks_mode)" = "$1" ] || $CLI daemon set --kill-switch "$1" --yes >> "$LOG" 2>&1
  $CLI daemon restore-network >> "$LOG" 2>&1; sleep 4
}

env_init >> "$LOG" 2>&1
note "uifire $NAME: direct $DIRECT, node $NODE_IP"
hold # the guest dead-man stays off while a cell blocks traffic on purpose
ORIG_KS=$(ks_mode); info 'kill switch mode before' "${ORIG_KS:-unknown}"
[ -n "$ORIG_KS" ] || { record FAIL 'read the kill switch mode (daemon settings --json)' ''; summary; exit 1; }

case $NAME in
  # ─── Kill switch page: pick On, press Apply → the service restarts with kill_switch = persist ───
  # The page has Off and On only since 97eb1077 (FMC): On = dvpnd 'persist', "Always" and its confirm are gone.
  # ks-always is kept as an alias so older cell lists still run; it is the same cell.
  apply|ks-always)
    case $ORIG_KS in on|persist) $CLI daemon set --kill-switch off --yes >> "$LOG" 2>&1; sleep 3 ;; esac
    check 'before: kill switch is off' bash -c "[ '$(ks_mode)' = off ] || { echo \"mode $(ks_mode)\"; exit 1; }"
    ui 'ks-mode=on;shot=after-apply'; fired $? 'Kill switch → On → Apply (administrator)'
    effect 'service setting now kill_switch = persist (daemon settings)' bash -c "[ \"$(ks_mode)\" = persist ] || { echo \"mode $(ks_mode)\"; exit 1; }"
    info 'pf anchor dvpnd rules with On and no session' "$(anchor_rules)"
    ks_back "$ORIG_KS"
    restored "kill switch back to $ORIG_KS, pf anchor released, direct egress" bash -c \
      "$(declare -f anchor_rules); for i in 1 2 3 4 5; do [ \"\$(curl -4 -s -m 12 https://api.ipify.org)\" = '$DIRECT' ] && { [ '$ORIG_KS' != off ] || [ \"\$(anchor_rules)\" = 0 ]; } && exit 0; sleep 4; done; echo \"pf=\$(anchor_rules)\"; exit 1" ;;

  # ─── Restore network (Diagnostics, or the banner): a live session with the kill switch on → all released ───
  restore-network)
    case $ORIG_KS in on|persist) ;; *) $CLI daemon set --kill-switch on --yes >> "$LOG" 2>&1; sleep 3 ;; esac
    gap; run 0 'Connected|connected' 'setup: a live WireGuard session with the kill switch on (CLI)' -- connect "$(node_of wireguard)" --units 1 --yes
    sleep 4
    check 'setup: egress is the node and pf holds rules' bash -c "$(declare -f anchor_rules); [ \"\$(curl -4 -s -m 12 https://api.ipify.org)\" = '$NODE_IP' ] && [ \"\$(anchor_rules)\" -gt 0 ]" || true
    ui 'restore;shot=after-restore'; fired $? 'Restore network (banner or Diagnostics)'
    effect 'no session, pf anchor empty, no tunnel, direct egress' bash -c \
      "$(declare -f no_leftovers egress new_utuns our_procs anchor_rules services proxy_snapshot); LIB='$LIB'; OUT='$OUT'; $CLI status | grep -qE '^Session +Not connected' && no_leftovers && [ \"\$(egress)\" = '$DIRECT' ]"
    ks_back "$ORIG_KS"
    restored "kill switch back to $ORIG_KS, nothing left" bash -c \
      "$(declare -f no_leftovers egress new_utuns our_procs anchor_rules services proxy_snapshot); LIB='$LIB'; OUT='$OUT'; [ '$(ks_mode)' = '$ORIG_KS' ] && no_leftovers" ;;

  # ─── Settings: "Restore default settings" → confirm "Restore defaults" → app settings back to defaults ───
  restore-defaults)
    SF=$DVPN_DATA_DIR/settings.json; BK=$OUT/uifire-settings.bak # copied, never printed (holds the RPC URL)
    cp -p "$SF" "$BK" 2>/dev/null || : > "$BK.none"
    run 0 'per_hour' 'setup: a non-default setting (defaultBasis = per_hour)' -- settings set defaultBasis=per_hour
    ui 'nav=Settings;click=[data-settings-reset];click=[role="dialog"] .btn-primary;sleep=2;shot=after-reset'; fired $? 'Restore default settings → "Restore defaults" confirm'
    effect 'app settings back to defaults (defaultBasis = per_gb)' bash -c "$CLI settings get | grep -E '^defaultBasis' | grep -q per_gb"
    if [ -e "$BK.none" ]; then rm -f "$SF" "$BK.none"; restored 'no settings file, as before the cell' test ! -e "$SF"
    else cp -p "$BK" "$SF"; restored 'the settings file is byte for byte what it was before the cell' cmp -s "$BK" "$SF"; rm -f "$BK"; fi ;;

  # ─── Activity: an open deposit's "Top up" → amount 0.1 → confirm "Top up" → the wallet pays 0.1 tDVPN into it ───
  top-up)
    gap; run 0 'Connected|connected' 'setup: a live per-GB WireGuard session (an open deposit)' -- connect "$(node_of wireguard)" --units 1 --yes
    sleep 10; B0=$(tdvpn_now); info 'wallet tDVPN before' "$B0"
    ui 'nav=Activity;click=[data-refunds="open"] [data-refund] button;fill=Amount:0.1;click=[role="dialog"] .btn-primary;sleep=20;shot=after-topup'; fired $? 'Activity → Top up → 0.1 → "Top up" confirm'
    sleep 10; B1=$(tdvpn_now); info 'wallet tDVPN after' "$B1"
    # wallet --json gives base units (6 decimals): 0.1 tDVPN = 100000
    effect 'the wallet paid 0.1 tDVPN into the deposit (chain balance)' node -e 'const [a, b] = process.argv.slice(1).map(Number); const d = (a - b) / 1e6; console.log(`paid ${d.toFixed(6)} tDVPN`); process.exit(a > 0 && d >= 0.099 && d <= 0.101 ? 0 : 1)' "${B0:-0}" "${B1:-0}"
    restore
    restored 'session ended, nothing left, direct egress' bash -c "$(declare -f no_leftovers egress new_utuns our_procs anchor_rules services proxy_snapshot); LIB='$LIB'; OUT='$OUT'; $CLI status | grep -qE '^Session +Not connected' && no_leftovers" ;;

  # ─── Activity: "Settle now" → confirm "Settle" → an open deposit starts closing on chain ───
  settle)
    gap; run 0 'Connected|connected' 'setup: a per-GB session whose deposit stays open (CLI)' -- connect "$(node_of wireguard)" --units 1 --yes
    sleep 5; run 0 '-' 'setup: disconnect (the CLI leaves its deposit open)' -- disconnect; sleep 10
    O0=$($CLI settle list --json 2>/dev/null | grep -oE '"status" *: *"open"' | grep -c .); info 'open deposits before' "$O0"
    ui 'nav=Activity;click=text:Settle now;click=[role="dialog"] .btn-primary;sleep=30;shot=after-settle'; fired $? 'Activity → Settle now → "Settle" confirm'
    sleep 10; O1=$($CLI settle list --json 2>/dev/null | grep -oE '"status" *: *"open"' | grep -c .); info 'open deposits after' "$O1"
    effect 'fewer open deposits on chain (they started closing)' bash -c "echo 'open $O0 -> $O1'; [ '$O0' -gt 0 ] && [ '$O1' -lt '$O0' ]"
    restored 'no session, nothing left, direct egress' bash -c "$(declare -f no_leftovers egress new_utuns our_procs anchor_rules services proxy_snapshot); LIB='$LIB'; OUT='$OUT'; $CLI status | grep -qE '^Session +Not connected' && no_leftovers" ;;

  # ─── Plans: "Subscribe" → confirm "Pay N tDVPN" → a new subscription on chain; it is closed again after ───
  subscribe)
    # Pinned to node-4's plan (the Mac lane never uses node-3's 8z7U383V…). data-plan exists from the combined
    # build on: on an older build the click finds nothing and nothing is paid.
    PLAN=${PLAN_ADDR:-55yEYsyUd87AFEhLg9PuL39cfaDMktjEg74CSw8PdRzc}
    $CLI plans subscriptions --json > "$OUT/uifire-subs0.json" 2>/dev/null
    ui "nav=Plans;click=[data-plan=\"$PLAN\"] button;click=[role=\"dialog\"] .btn-primary;sleep=25;shot=after-subscribe"; fired $? "Plans → Subscribe on plan ${PLAN:0:8} → \"Pay … tDVPN\" confirm"
    sleep 10; $CLI plans subscriptions --json > "$OUT/uifire-subs1.json" 2>/dev/null
    NEW=$(node -e '
      const fs = require("fs"); const rd = (f) => { try { const j = JSON.parse(fs.readFileSync(f, "utf8")); return Array.isArray(j) ? j : (j.subscriptions ?? j.items ?? []); } catch (err) { console.error(`uifire: cannot read ${f}: ${err.message}`); return []; } };
      const id = (s) => s.address ?? s.subscription ?? s.id;
      const before = new Set(rd(process.argv[1]).map(id));
      const fresh = rd(process.argv[2]).filter((s) => id(s) && !before.has(id(s)));
      const wrong = fresh.filter((s) => s.plan && s.plan !== process.argv[3]);
      if (wrong.length) console.error(`uifire: subscribed to another plan: ${wrong.map((s) => s.plan).join(" ")}`);
      console.log(fresh.map(id).join(" "));
    ' "$OUT/uifire-subs0.json" "$OUT/uifire-subs1.json" "$PLAN" 2> "$OUT/uifire-subs.err")
    effect "a new subscription of this wallet on chain, on plan ${PLAN:0:8} only" bash -c "echo 'new: ${NEW:-none}'; cat '$OUT/uifire-subs.err'; [ -n '$NEW' ] && [ ! -s '$OUT/uifire-subs.err' ]"
    CL=0; for s in $NEW; do gap; $CLI plans close "$s" --yes >> "$LOG" 2>&1 || CL=1; done
    restored 'each new subscription closed again (plans close exit 0, chain tx)' bash -c "[ -n '$NEW' ] && [ '$CL' = 0 ]" ;;

  # ─── Servers: connected to A, Connect on B → the sheet says "Switch" → confirm → the session is B ───
  switch)
    A=$(node_of wireguard); B=$(node_of amneziawg)
    ui "connect=$A:per_gb;connect=$B:per_gb;shot=after-switch"; fired $? 'connected to WireGuard, then Connect on AmneziaWG → "Switch" confirm'
    effect 'the live session is the second server (AmneziaWG), egress = node' bash -c "$CLI status | grep -qi amneziawg && [ \"\$(curl -4 -s -m 12 https://api.ipify.org)\" = '$NODE_IP' ]"
    restore
    restored 'session ended, nothing left, direct egress' bash -c "$(declare -f no_leftovers egress new_utuns our_procs anchor_rules services proxy_snapshot); LIB='$LIB'; OUT='$OUT'; $CLI status | grep -qE '^Session +Not connected' && no_leftovers" ;;

  # ─── Split tunnelling: "Open browser through VPN" → a browser process on the session's SOCKS proxy ───
  open-browser)
    WD=true; whole_device || WD=false
    $CLI daemon set --whole-device false --yes >> "$LOG" 2>&1; sleep 3
    gap; run 0 'Connected|connected' 'setup: a V2Ray session in proxy mode (CLI)' -- connect "$(node_of v2ray)" --units 1 --yes
    sleep 4; S=$(socks); info 'session SOCKS' "${S:-none}"
    ui 'browser;shot=after-browser'; fired $? 'Split tunnelling → Open browser through VPN'
    effect "a browser process runs on the session proxy (socks5://${S:-?})" bash -c "[ -n '$S' ] && pgrep -f 'proxy-server=socks5://$S' >/dev/null && echo \"\$(pgrep -f 'proxy-server=socks5://$S' | grep -c .) processes\""
    pkill -f 'proxy-server=socks5://127.0.0.1' 2>/dev/null; sleep 2
    restore; $CLI proxy off >> "$LOG" 2>&1
    [ "$WD" = true ] && { $CLI daemon set --whole-device true --yes >> "$LOG" 2>&1; sleep 3; }
    restored "no browser on our proxy, session ended, whole device back to $WD, nothing left" bash -c "$(declare -f no_leftovers egress new_utuns our_procs anchor_rules services proxy_snapshot whole_device); CLI=$CLI; LIB='$LIB'; OUT='$OUT'; ! pgrep -f 'proxy-server=socks5://127.0.0.1' >/dev/null && { [ '$WD' = false ] || whole_device; } && no_leftovers" ;;

  # ─── Onboarding on a FRESH profile (owner order): the app's own wallet, made in the UI; profile deleted after ───
  # Needs the combined build (DVPN_UI_ONBOARD + the owner step). A fresh DVPN_DATA_DIR, no test key file.
  onboard-create|onboard-backup|onboard-restart|onboard-import|onboard-import-bad)
    unlock_kc
    PROF=$OUT/onboard-profile; rm -rf "$PROF"; mkdir -p "$PROF"
    LAST=$OUT/uifire-onboard-last-address
    case $NAME in
      onboard-create)
        uio 'click=text:Create a new wallet;sleep=3;shot=phrase;click=text:I saved it;owner=30;shot=after-saved'; fired $? 'setup → Create a new wallet → I saved it'
        A=$(owner_of); info 'new wallet' "${A:-none}"; info 'previous run' "$(cat "$LAST" 2>/dev/null || echo none)"
        effect 'a new wallet: an address, not the last run'"'"'s, its key stored encrypted (no plaintext secret in the profile)' bash -c \
          "[ -n '$A' ] && [ '$A' != \"\$(cat '$LAST' 2>/dev/null)\" ] && ls '$PROF' | grep -qi wallet && ! grep -rqs secretKey '$PROF'"
        [ -n "$A" ] && echo "$A" > "$LAST" ;;
      onboard-backup)
        # Q0297: after "I saved it" the app asks some words back; a wrong word is refused (data-phrase-wrong names
        # it, setup stays), the right words let setup go on. Words are read on the phrase card, kept in memory only.
        uio 'click=text:Create a new wallet;sleep=3;phrase-read;click=text:I saved it;shot=check;phrase-fill=wrong;shot=wrong;phrase-fill=right;shot=after-check;owner=30'; R=$?
        node -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.exit(s.some((x) => x.step === "click=text:I saved it" && x.ok) && s.some((x) => x.step === "phrase-fill=wrong") ? 0 : 1)' "$UIOUT/scenario.json"; fired $? 'Create → I saved it → backup check: wrong word → Check, then right words → Check'
        effect 'a wrong word is refused and named (setup held); the right words are accepted (setup goes on)' bash -c "[ '$R' = 0 ] && grep -E 'phrase-fill=(wrong|right)' '$LOG' | tail -2" ;;
      onboard-restart)
        uio 'click=text:Create a new wallet;sleep=3;click=text:I saved it;owner=30'; fired $? 'setup → Create a new wallet → I saved it (first launch)'
        A=$(owner_of)
        # second launch: the smoke driver shoots "Welcome back" (00-welcome.png) and presses its Continue itself
        uio 'owner=30;shot=after-restart'; R=$?
        B=$(owner_of); info 'address first launch / after restart' "${A:-none} / ${B:-none}"
        effect 'after a restart the app opens the SAME wallet (Welcome back shown, no new address)' bash -c "[ '$R' = 0 ] && [ -n '$A' ] && [ '$A' = '$B' ] && [ -s '$UIOUT/00-welcome.png' ]" ;;
      onboard-import)
        KF=$PROF/../uifire-throwaway.json
        KEY=$(node -e '
          const c = require("crypto"); const k = c.generateKeyPairSync("ed25519");
          const d = k.privateKey.export({ format: "der", type: "pkcs8" }).subarray(16), p = k.publicKey.export({ format: "der", type: "spki" }).subarray(12);
          require("fs").writeFileSync(process.argv[1], JSON.stringify([...d, ...p]), { mode: 0o600 });
          const A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"; let n = BigInt("0x" + p.toString("hex")), s = "";
          while (n > 0n) { s = A[Number(n % 58n)] + s; n /= 58n; } for (const b of p) { if (b) break; s = "1" + s; }
          console.log(s);' "$KF")
        info 'throwaway key file address (never funded)' "$KEY"
        uio "click=text:Import a wallet;fill=#imp:$(cat "$KF");click=text:Import;owner=30;shot=after-import"; fired $? 'setup → Import a wallet → paste the key file → Import'
        B=$(owner_of); rm -f "$KF"
        effect 'the app holds exactly the imported wallet' bash -c "[ -n '$KEY' ] && [ '$B' = '$KEY' ] || { echo 'app ${B:-none}'; exit 1; }" ;;
      onboard-import-bad)
        uio 'click=text:Import a wallet;fill=#imp:not a wallet at all;click=text:Import;sleep=4;shot=after-bad-import;owner=8'; UR=$?
        node -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.exit(s.some((x) => x.step.startsWith("click=text:Import") && x.step !== "click=text:Import a wallet" && x.ok) ? 0 : 1)' "$UIOUT/scenario.json"; fired $? 'setup → Import a wallet → junk → Import'
        V=$(node -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log([...new Set(s.flatMap((x) => x.visible ?? []))].join(" | ").slice(0, 300))' "$UIOUT/scenario.json" 2>/dev/null)
        info 'what the screen said' "${V:-nothing}"
        effect 'refused with a readable error, no wallet, the app did not crash' bash -c \
          "[ '$UR' != 0 ] && [ -z '$(owner_of)' ] && grep -q '^exit=0' '$LOG' && printf '%s' \"$V\" | grep -qiE 'not|invalid|could|recovery|key' && ! printf '%s' \"$V\" | grep -qiE 'undefined|TypeError|\\[object|at .*\\.js'" ;;
    esac
    rm -rf "$PROF"
    restored 'the fresh profile and its throwaway wallet removed; the test wallet profile untouched' bash -c "[ ! -e '$PROF' ] && [ -s \"\${DVPN_KEYFILE:-$HOME/.ddv/test-wallet.json}\" ]" ;;

  # ─── Dedicated uifire wallet (never the test wallet; DIR funds it): device setup in the UI, and Sign out ───
  # ~/.ddv/uifire-wallet.json is made on the first run (0600, back it up to ~/memory/ddv-vm-wallets/); until DIR
  # funds it (~0.05 SOL) the permission step cannot sign and the cell fails with "fund <address>".
  onboard-device-setup|sign-out)
    unlock_kc
    UW=$HOME/.ddv/uifire-wallet.json; PROF=$OUT/onboard-profile; rm -rf "$PROF"; mkdir -p "$PROF"
    if [ ! -s "$UW" ]; then
      node -e 'const c = require("crypto"); const k = c.generateKeyPairSync("ed25519");
        const d = k.privateKey.export({ format: "der", type: "pkcs8" }).subarray(16), p = k.publicKey.export({ format: "der", type: "spki" }).subarray(12);
        require("fs").writeFileSync(process.argv[1], JSON.stringify([...d, ...p]), { mode: 0o600 });' "$UW"
      note "created the dedicated uifire wallet $UW: back it up to ~/memory/ddv-vm-wallets/"
    fi
    UA=$(DVPN_KEYFILE=$UW $CLI wallet show --json 2>/dev/null | grep -oE '"(owner|address)" *: *"[1-9A-HJ-NP-Za-km-z]{32,44}"' | head -1 | grep -oE '[1-9A-HJ-NP-Za-km-z]{32,44}"$' | tr -d '"')
    info 'uifire wallet' "${UA:-unknown}"
    # Fees for its permission step: the test wallet sends 0.05 SOL when it holds less than 0.03 (left for the C6 sweep).
    US=$(DVPN_KEYFILE=$UW $CLI wallet show --json 2>/dev/null | grep -oE '"ownerLamports" *: *"?[0-9]+' | grep -oE '[0-9]+$')
    info 'uifire wallet lamports' "${US:-unknown}"
    if [ -n "$UA" ] && [ "${US:-0}" -lt 30000000 ]; then gap; run 0 '-' 'setup: fund the uifire wallet with 0.05 SOL (test wallet)' -- wallet send --to "$UA" --sol 0.05 --yes; sleep 15; fi
    IMPORT="click=text:Import a wallet;fill=#imp:$(cat "$UW");click=text:Import;owner=30"
    SETUP="click=text:Find device address;sleep=10;click=text:Review and sign;click=[role=\"dialog\"] .btn-primary;sleep=40;nav=Connect;shot=main"
    if [ "$NAME" = onboard-device-setup ]; then
      uio "$IMPORT;$SETUP"; fired $? 'fresh profile → Import → Find device address → Review and sign → "Sign" → main screen'
      effect 'the wallet gave this device a spending permission on chain (device show: Ready yes) and the app reached Connect' bash -c \
        "DVPN_KEYFILE='$UW' $CLI device show 2>/dev/null | grep -qE '^Ready +yes' || { echo 'not ready; fund ${UA:-the uifire wallet} if its SOL is 0'; exit 1; }"
    else
      uio "$IMPORT;$SETUP;nav=Wallet;click=text:Sign out of this wallet;click=[role=\"dialog\"] .btn-danger;sleep=4;shot=signed-out"; R1=$?
      OUT1=$(node -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const i = s.findIndex((x) => x.step === "click=text:Sign out of this wallet"); console.log(i >= 0 && s[i].ok && s[i + 1]?.ok ? "fired" : "not fired")' "$UIOUT/scenario.json" 2>/dev/null)
      [ "$OUT1" = fired ]; fired $? 'Wallet → Sign out of this wallet → "Sign out" confirm'
      GONE=0; ls "$PROF" | grep -qi wallet || GONE=1
      uio "owner=6"; NOW=$(owner_of)
      uio "$IMPORT;shot=reimported"; B=$(owner_of)
      info 'after sign-out / after re-import' "${NOW:-no wallet} / ${B:-none}"
      effect 'signed out: the key left this computer (no wallet file, the next launch has no wallet); re-import gives the same address' bash -c \
        "[ '$GONE' = 1 ] && [ -z '$NOW' ] && [ -n '$B' ] && [ '$B' = '${UA:-x}' ]"
    fi
    # Setup with another wallet rebinds the SHARED service device to it (TMC, plan-a3a4 run 2: "ticket was issued
    # for another owner"). Put it back: revoke the uifire grant, device setup with the test wallet, prove one connect.
    gap; DVPN_KEYFILE=$UW $CLI device revoke --yes >> "$LOG" 2>&1
    gap; run 0 '-' 'restore: device setup with the test wallet (rebinds the service device to it)' -- device setup --yes
    sleep 10; run 0 '^Ready +yes' 'restore: test wallet device ready' -- device show
    gap; run 0 'Connected|connected' 'restore: one plain WireGuard connect with the test wallet' -- connect "$(node_of wireguard)" --units 1 --yes
    sleep 4; check 'restore: egress = node' egress_is_node wireguard; restore
    rm -rf "$PROF"
    restored 'uifire grant revoked, service device back on the test wallet (ready + a working connect), fresh profile removed' bash -c \
      "$(declare -f no_leftovers egress new_utuns our_procs anchor_rules services proxy_snapshot); LIB='$LIB'; OUT='$OUT'; [ ! -e '$PROF' ] && ! DVPN_KEYFILE='$UW' $CLI device show 2>/dev/null | grep -qE '^Ready +yes' && $CLI device show | grep -qE '^Ready +yes' && no_leftovers" ;;

  # ─── Activity: "Export CSV" → the native Save sheet (path typed by System Events) → the CSV on disk ───
  export-csv)
    DEST=$OUT/uifire-export; rm -rf "$DEST"; mkdir -p "$DEST"
    N=$($CLI history list --json 2>/dev/null | node -e 'let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => { try { const j = JSON.parse(s); console.log((Array.isArray(j) ? j : j.entries ?? j.rows ?? []).length); } catch (err) { console.error(`history json: ${err.message}`); console.log(0); } })')
    info 'sessions in history (CLI)' "$N"
    # The Save sheet is the OS's: answer it the way a person would (Go to folder, type the path, Save).
    # SIP keeps Accessibility closed to osascript here, so the HOST types the keys on the VM's virtual
    # keyboard (cell-guest.sh save_sheet_keys + ddv-faultctl keys): this side only asks, once the sheet is up.
    KREQ=$HOME/matrix/uifire-keys.req KDONE=$HOME/matrix/uifire-keys.done; rm -f "$KREQ" "$KDONE"
    # the keys go to whatever has focus: bring the app (and its sheet) to the front first. `open -a` needs no
    # Accessibility; a stray dialog in the console session (a keychain prompt) once took the typed path.
    # Ask for the keys only once the app says it clicked Export CSV (signal step; the app writes to
    # DVPN_UI_SIG_DIR, passed through ui-smoke.sh): a fixed 10 s wait typed the path into "Welcome back" (Q0322 lab run)
    export DVPN_UI_SIG_DIR=$OUT/uifire-sig; SIGF=$DVPN_UI_SIG_DIR/exportsheet; rm -f "$SIGF"
    ( for i in $(seq 1 240); do [ -e "$SIGF" ] && break; sleep 0.5; done; sleep 3
      launchctl asuser "$(id -u)" open -a '/Applications/Devnet dVPN.app'; sleep 2; printf '%s' "$DEST" > "$KREQ" ) &
    SAVER=$!
    DVPN_UI_SMOKE_FOCUS=1 ui 'nav=Activity;click=text:Export CSV;signal=exportsheet;sleep=45;shot=after-export'; fired $? 'Activity → Export CSV → Save sheet → Save'
    info 'Export CSV clicked (app signal) before the keys' "$([ -e "$SIGF" ] && echo yes || echo NO)"
    kill "$SAVER" 2>/dev/null; wait "$SAVER" 2>/dev/null
    if [ -e "$KDONE" ]; then note 'save sheet answered by host keystrokes'; else note 'no host keystrokes (run through cell-guest.sh on the host)'; fi
    rm -f "$KREQ" "$KDONE"
    F=$(ls "$DEST"/*.csv 2>/dev/null | head -1)
    effect 'a CSV was written where it was saved: a header and one row per session' bash -c \
      "[ -n '$F' ] && head -1 '$F' | grep -qi 'start' && [ \"\$(tail -n +2 '$F' | grep -c .)\" -ge 1 ] && echo \"\$(tail -n +2 '$F' | grep -c .) rows, history has $N\" || { echo \"no csv in $DEST (host keystrokes: see uifire-keys note above)\"; grep -i 'osascript\\|not allowed\\|assistive' '$LOG' | tail -2; exit 1; }"
    rm -rf "$DEST"
    restored 'exported file removed' test ! -e "$DEST" ;;

  # ─── Diagnostics: the service is gone → "Install service" → LaunchDaemon running, dvpnd answers ───
  install-service)
    run 0 '-' 'setup: uninstall the VPN service (device key kept)' -- daemon uninstall --yes
    check 'setup: the service is gone' bash -c "! sudo launchctl print system/$LABEL >/dev/null 2>&1"
    # The setup gate keeps a set-up computer on the main screen when its service is gone; Q0305 puts
    # "Install service" on the banner and in Diagnostics (data-install-service; combined build on).
    ui 'nav=Diagnostics;click=[data-service-missing] [data-install-service];sleep=60;shot=after-install'; fired $? 'Diagnostics → (service missing) Install service'
    effect 'the LaunchDaemon runs and dvpnd answers (daemon version)' bash -c "$(declare -f svc_running); LABEL=$LABEL; for i in \$(seq 1 30); do svc_running && $CLI daemon version >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1"
    ks_back "$ORIG_KS"
    restored "service installed and running, kill switch $ORIG_KS, direct egress" bash -c "$(declare -f svc_running); LABEL=$LABEL; svc_running && [ '$(ks_mode)' = '$ORIG_KS' ] && [ \"\$(curl -4 -s -m 12 https://api.ipify.org)\" = '$DIRECT' ]" ;;

  *) record FAIL "unknown uifire button '$NAME'" 'apply | ks-always | restore-network | restore-defaults | top-up | settle | subscribe | switch | open-browser'; summary; exit 3 ;;
esac

note "uifire $NAME: fired=$FIRED effect=$EFFECT restore=$RESTORED"
summary || exit 1
[ "$FIRED$EFFECT$RESTORED" = 111 ] || { echo "FAIL uifire:$NAME (fired=$FIRED effect=$EFFECT restore=$RESTORED)"; exit 1; }
echo "PASS uifire:$NAME"
