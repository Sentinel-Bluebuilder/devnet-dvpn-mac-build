#!/bin/bash
# ─── Installer proof on macOS (run IN the guest, sudo -n): update, uninstall, reinstall ───
# Needs: the service installed and running from an earlier build, the test wallet (DVPN_KEYFILE).
# Each step writes a fingerprint of everything the app or the service can touch, then asserts
# on it. Results: ~/sweep/installer.tsv + installer.log (+ fp-<step>.txt).
# Phases: dirty setup (the user's own DNS, SOCKS proxy settings and pf anchor must survive
# everything), update, uninstall, reinstall, offline repair (web ports blocked: the bundled deps
# need nothing from the internet), then the user's setup is put back as it was.
# Usage: bash installer-test.sh <path-to.dmg>
set -u
DMG=$(cd "$(dirname "${1:?dmg}")" && pwd)/$(basename "$1")
APP='/Applications/Devnet dVPN.app'
LAUNCHER="$APP/Contents/Resources/bin/devnet-dvpn"
LIB=/usr/local/lib/devnet-dvpn
PLIST=/Library/LaunchDaemons/network.sentinel.devnet-dvpn.dvpnd.plist
LABEL=network.sentinel.devnet-dvpn.dvpnd
HOME_D=/var/db/dvpnd/client
OUT=~/sweep; mkdir -p "$OUT"; TSV="$OUT/installer.tsv"; : > "$TSV"; : > "$OUT/installer.log"
: "${DVPN_KEYFILE:?set DVPN_KEYFILE}"; export DVPN_DATA_DIR=${DVPN_DATA_DIR:-$HOME/ddv-data}
PASS=0; FAIL=0
check() {
  local desc=$1; shift
  local out; out=$("$@" 2>&1); local code=$?
  printf '\n### %s\n$ %s\n%s\n(exit %s)\n' "$desc" "$*" "$out" "$code" >> "$OUT/installer.log"
  if [ $code = 0 ]; then PASS=$((PASS + 1)); echo "ok   $desc"; printf 'PASS\t%s\tcheck\t\n' "$desc" >> "$TSV";
  else FAIL=$((FAIL + 1)); echo "FAIL $desc :: $(echo "$out" | head -3 | tr '\n' ' ')"; printf 'FAIL\t%s\tcheck\t%s\n' "$desc" "$(echo "$out" | head -2 | tr '\n\t' '  ')" >> "$TSV"; fi
}
# cli <args…>: a CLI step recorded with its command (the cover tier reads these)
cli() {
  local desc=$1; shift
  local out; out=$("$LAUNCHER" "$@" 2>&1); local code=$?
  printf '\n### %s\n$ devnet-dvpn %s\n%s\n(exit %s)\n' "$desc" "$*" "$out" "$code" >> "$OUT/installer.log"
  if [ $code = 0 ]; then PASS=$((PASS + 1)); echo "ok   $desc"; printf 'PASS\t%s\t%s\t\n' "$desc" "$*" >> "$TSV";
  else FAIL=$((FAIL + 1)); echo "FAIL $desc :: $(echo "$out" | tail -3 | tr '\n' ' ')"; printf 'FAIL\t%s\t%s\t%s\n' "$desc" "$*" "$(echo "$out" | tail -2 | tr '\n\t' '  ')" >> "$TSV"; fi
}
services() { networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*'; }
net_state() { # DNS + SOCKS proxy on every service, pf main ruleset without our anchor
  services | while IFS= read -r s; do printf '%s dns=%s socks=%s\n' "$s" "$(networksetup -getdnsservers "$s" | tr '\n' ',')" "$(networksetup -getsocksfirewallproxy "$s" | head -3 | tr '\n' ',')"; done
  sudo pfctl -sr 2>/dev/null | grep -v '"dvpnd"'
}
fingerprint() { # <name>
  {
    echo "== app";       ls -d "$APP" 2>/dev/null && /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist"
    echo "== files";     ls -d "$PLIST" "$LIB" /usr/local/bin/devnet-dvpn "$HOME_D" /Library/Logs/DevnetDVPN 2>/dev/null
    echo "== service";   sudo launchctl print "system/$LABEL" 2>/dev/null | grep -E '^\s+(state|pid) =' || echo 'not loaded'
    echo "== group";     dseditgroup -o read dvpn 2>/dev/null | grep -A3 GroupMembership | tr -s ' ' || echo 'no group'
    echo "== pf";        sudo pfctl -a dvpnd -s rules 2>/dev/null | head -3; sudo pfctl -s info 2>/dev/null | head -1
    echo "== utun";      ifconfig -l
    echo "== procs";     pgrep -lx 'dvpnd|v2ray|xray|hysteria2|openvpn' || true
    echo "== net";       net_state
    echo "== egress";    curl -s -m 12 https://api.ipify.org; echo
  } > "$OUT/fp-$1.txt" 2>&1
  cat "$OUT/fp-$1.txt" >> "$OUT/installer.log"
  # effect line (FINAL-PASS-EFFECT-SPEC.md DRIVER/INSTALL): what is installed at this step, measured
  local a=False v=none s=False d
  [ -d "$APP" ] && { a=True; v=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null); }
  grep -q 'state = running' "$OUT/fp-$1.txt" && s=True
  d=$([ -x "$LIB/dvpnd" ] && echo True || echo False)
  echo "installed at '$1': app present $a version ${v:-none}, service running $s, root dvpnd present $d" | tee -a "$OUT/installer.log"
}
install_app() { # drag-install from the .dmg (ditto keeps the ad-hoc signature)
  local m
  m=$(hdiutil attach -nobrowse -noverify -readonly "$DMG" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)
  [ -d "$m/Devnet dVPN.app" ] || { echo "no app in $DMG"; return 1; }
  pkill -f "$APP/Contents/MacOS/Devnet dVPN" 2>/dev/null
  sudo rm -rf "$APP" && sudo ditto "$m/Devnet dVPN.app" "$APP" && sudo chown -R "$(id -un):admin" "$APP"
  hdiutil detach "$m" -quiet
}
DIRECT=$(curl -s -m 12 https://api.ipify.org)
PRIMARY=$(services | head -1)
ORIG_DNS=$(networksetup -getdnsservers "$PRIMARY" | grep -E '^[0-9a-f.:]+$' | tr '\n' ' ')
ORIG_SOCKS=$(networksetup -getsocksfirewallproxy "$PRIMARY")
# pf_anchor <name> <rules|"">: an anchor of the user's (or the test's) own, attached at the END of
# the main ruleset so it never sits before dvpnd's anchor (dvpnd refuses the kill switch then).
# "" detaches and empties it.
pf_anchor() {
  local main
  main=$(sudo pfctl -sr 2>/dev/null | grep -v "^anchor \"$1\"")
  if [ -n "$2" ]; then main=$(printf '%s\nanchor "%s" all\n' "$main" "$1"); fi
  printf '%s\n' "$main" | sudo pfctl -R -f - 2>&1 | grep -v 'ALTQ\|^$' >&2
  if [ -n "$2" ]; then
    printf '%s\n' "$2" | sudo pfctl -a "$1" -f - 2>&1 | grep -v 'ALTQ\|^$' >&2
    # pf is off on a Mac with no kill switch held: a loaded anchor does nothing until it is on.
    # -E takes our own reference (a token), so dvpnd's own use of pf is never disturbed.
    # One token per anchor (the user's own anchor and the offline block overlap).
    [ -s "$OUT/pf-token-$1" ] || sudo pfctl -E 2>&1 | sed -n 's/^Token : //p' > "$OUT/pf-token-$1"
  else
    sudo pfctl -a "$1" -F all >/dev/null 2>&1
    [ -s "$OUT/pf-token-$1" ] && sudo pfctl -X "$(cat "$OUT/pf-token-$1")" >/dev/null 2>&1
    rm -f "$OUT/pf-token-$1"
  fi
}
user_setup_intact() {
  networksetup -getdnsservers "$PRIMARY" | grep -qx 9.9.9.9 &&
    networksetup -getsocksfirewallproxy "$PRIMARY" | grep -q '^Port: 9050' &&
    networksetup -getsocksfirewallproxy "$PRIMARY" | grep -q '^Enabled: No' &&
    sudo pfctl -sr | grep -q 'anchor "ddvuser"'
}
egress_is_direct() { [ "$(curl -s -m 12 https://api.ipify.org)" = "$DIRECT" ]; }
export -f user_setup_intact egress_is_direct; export PRIMARY DIRECT

PF_BEFORE=$(sudo pfctl -s info 2>/dev/null | awk '/^Status:/{print $2}')
# pf Enabled with NO reference held = enabled by a plain `pfctl -e` (e.g. a cell cut mid-kill-switch). Our own
# test token's -X then turns pf off when it is the last reference, so cleanup must put that rig state back itself.
PF_REFS_BEFORE=$(sudo pfctl -s References 2>/dev/null | grep -vc 'No pf starter references')
# D. dirty setup: what a real Mac already has. Every later "exactly as before" includes it.
sudo networksetup -setdnsservers "$PRIMARY" 9.9.9.9 1.0.0.1
sudo networksetup -setsocksfirewallproxy "$PRIMARY" 127.0.0.1 9050 && sudo networksetup -setsocksfirewallproxystate "$PRIMARY" off
pf_anchor ddvuser 'pass out quick proto tcp to any port 22 keep state'
check 'dirty: own DNS, own SOCKS settings (off) and own pf anchor in place' user_setup_intact
check 'dirty: still online with the user setup' egress_is_direct
DEVICE=$(cat "$HOME_D/device.pub" 2>/dev/null)

# 0. the package itself
check 'dmg: verifies and holds a signed app' bash -c "hdiutil verify '$DMG' >/dev/null 2>&1 && m=\$(hdiutil attach -nobrowse -noverify -readonly '$DMG' | awk -F'\t' '/\/Volumes\//{print \$NF}' | tail -1) && codesign --verify --deep --strict \"\$m/Devnet dVPN.app\"; r=\$?; hdiutil detach \"\$m\" -quiet; exit \$r"
fingerprint before
check 'before: service running' grep -q 'state = running' "$OUT/fp-before.txt"
NET_BEFORE=$(net_state)

# 1. update over a running service: the app is replaced, the service keeps the old copies until
#    "Update the VPN service" (daemon install) refreshes them.
install_app
check 'update: app replaced from the .dmg, signature intact' bash -c "codesign --verify --deep --strict '$APP'"
# positive control: an old root copy must be seen as stale
sudo sh -c "printf '\n# older build\n' >> $LIB/scripts/service-ctl.sh"
check 'update: doctor flags the stale service copy (service_update warn)' bash -c "'$LAUNCHER' daemon doctor --json | jq -e '.[] | select(.name==\"service_update\" and .ok==false)' >/dev/null"
cli 'update: daemon install --yes refreshes the service' daemon install --yes
fingerprint update
check 'update: service running'               grep -q 'state = running' "$OUT/fp-update.txt"
check 'update: doctor service_update ok'      bash -c "'$LAUNCHER' daemon doctor --json | jq -e '.[] | select(.name==\"service_update\" and .ok==true)' >/dev/null"
check 'update: service dvpnd = the app dvpnd' bash -c "[ \"\$(shasum -a 256 < $LIB/dvpnd)\" = \"\$(shasum -a 256 < '$APP/Contents/Resources/resources/bin/dvpnd')\" ]"
check 'update: CLI link points into the app'  bash -c "[ \"\$(readlink /usr/local/bin/devnet-dvpn)\" = '$LAUNCHER' ] && devnet-dvpn daemon version | grep -q 'network devnet'"
check 'update: config keys are the cf4c372 names (escrow_base_units, dns_backend, endpoint)' bash -c "grep -q '^escrow_base_units' $HOME_D/client/config.toml && grep -q '^dns_backend' $HOME_D/client/config.toml && grep -q '^endpoint' $HOME_D/config.toml && ! grep -qE '^(escrow|dns|pipe) =' $HOME_D/config.toml $HOME_D/client/config.toml"
check 'update: same device' bash -c "[ \"\$(cat $HOME_D/device.pub)\" = '$DEVICE' ]"
check 'update: launchd restarts the service after a crash (KeepAlive)' bash -c "p=\$(pgrep -x dvpnd); sudo kill -9 \$p; for i in \$(seq 1 40); do sleep 3; n=\$(pgrep -x dvpnd); [ -n \"\$n\" ] && [ \"\$n\" != \"\$p\" ] && devnet-dvpn daemon version >/dev/null 2>&1 && exit 0; done; exit 1"

# 2. uninstall: networking exactly as before the app; the device key home is kept on purpose
cli 'uninstall: daemon uninstall --yes' daemon uninstall --yes
fingerprint removed
check 'uninstall: LaunchDaemon gone, nothing loaded' bash -c "[ ! -e $PLIST ] && ! sudo launchctl print system/$LABEL >/dev/null 2>&1"
check 'uninstall: no dvpnd process'                bash -c "! pgrep -x dvpnd"
check 'uninstall: root copies and CLI link gone'   bash -c "[ ! -e $LIB ] && [ ! -e /usr/local/bin/devnet-dvpn ]"
check 'uninstall: no pf anchor rules, no utun of ours, no protocol process' bash -c "[ -z \"\$(sudo pfctl -a dvpnd -s rules 2>/dev/null)\" ] && ! pgrep -x 'v2ray|xray|hysteria2|openvpn|wireguard-go|amneziawg-go'"
check 'uninstall: DNS, SOCKS proxy and pf main ruleset exactly as before' bash -c "[ \"\$0\" = \"\$1\" ] || { diff <(printf '%s\n' \"\$0\") <(printf '%s\n' \"\$1\"); exit 1; }" "$NET_BEFORE" "$(net_state)"
check "uninstall: direct egress ($DIRECT)"         bash -c "[ \"\$(curl -s -m 12 https://api.ipify.org)\" = '$DIRECT' ]"
check 'uninstall: device key home kept (on-chain permission + SOL)' bash -c "sudo test -f $HOME_D/client/keys/device.json && [ \"\$(cat $HOME_D/device.pub)\" = '$DEVICE' ]"
sudo rm -rf "$APP"   # drag to the Trash
check 'uninstall: app gone' bash -c "[ ! -e '$APP' ]"

# 3. reinstall: the kept home is reused, one root step brings the service back
install_app
cli 'reinstall: daemon install --yes (kept home)' daemon install --yes
fingerprint reinstalled
check 'reinstall: service running'          grep -q 'state = running' "$OUT/fp-reinstalled.txt"
check 'reinstall: same device (device.pub)' bash -c "[ \"\$(cat $HOME_D/device.pub)\" = '$DEVICE' ]"
check 'reinstall: CLI on PATH again'        bash -c "devnet-dvpn daemon version | grep -q 'network devnet'"
check 'reinstall: doctor has no FAIL'       bash -c "! devnet-dvpn daemon doctor 2>&1 | grep -q '^FAIL'"
check 'reinstall: user DNS, SOCKS settings and pf anchor untouched' user_setup_intact

# 4. offline repair: web ports blocked; "daemon install" (repair) still brings the service back
#    from what the app bundles (no download, no Homebrew)
pf_anchor ddvoffline 'block drop out quick proto { tcp udp } to any port { 80 443 }'
check 'offline: the web is unreachable (positive control)' bash -c '! curl -s -m 8 https://api.ipify.org'
cli 'offline: daemon install --yes repairs with no internet' daemon install --yes
# dvpnd checks the RPC before it serves, so offline it is installed but not yet up: the CLI must say so
check 'offline: the repair says it starts once the network is back' bash -c "tail -4 '$OUT/installer.log' | grep -q 'starts by itself once the network is back'"
check 'offline: the service is installed (launchd job loaded)' bash -c "sudo launchctl print system/$LABEL >/dev/null"
pf_anchor ddvoffline ''
check 'offline: web back once unblocked' egress_is_direct
# launchd starts it again within a minute (ThrottleInterval 60): no user action needed
check 'offline: the service comes up by itself once online (within 100 s)' bash -c "for i in \$(seq 1 50); do sudo launchctl print system/$LABEL | grep -q 'state = running' && devnet-dvpn daemon version 2>/dev/null | grep -q 'network devnet' && exit 0; sleep 2; done; exit 1"
check 'offline: user setup still intact' user_setup_intact

# put the user setup back exactly as it was before this test
if [ -n "$ORIG_DNS" ]; then
  # shellcheck disable=SC2086 # one argument per server
  sudo networksetup -setdnsservers "$PRIMARY" $ORIG_DNS
else
  sudo networksetup -setdnsservers "$PRIMARY" Empty
fi
O_HOST=$(printf '%s\n' "$ORIG_SOCKS" | awk -F': ' '/^Server:/{print $2}')
O_PORT=$(printf '%s\n' "$ORIG_SOCKS" | awk -F': ' '/^Port:/{print $2}')
sudo networksetup -setsocksfirewallproxy "$PRIMARY" "${O_HOST:-}" "${O_PORT:-0}" >/dev/null 2>&1
sudo networksetup -setsocksfirewallproxystate "$PRIMARY" off
pf_anchor ddvuser ''
check 'cleanup: no test anchor left' bash -c "! sudo pfctl -sr | grep -q 'ddvuser\|ddvoffline'"
check 'cleanup: direct egress' egress_is_direct
check 'cleanup: no dvpnd pf reference or rule left' bash -c "! sudo pfctl -a dvpnd -s rules 2>/dev/null | grep -q . && ! sudo pfctl -s References 2>/dev/null | grep -qi dvpnd"
if [ "$PF_BEFORE" = Enabled ] && [ "${PF_REFS_BEFORE:-0}" = 0 ] && sudo pfctl -s info 2>/dev/null | grep -q '^Status: Disabled'; then
  echo "info cleanup: pf was Enabled with no reference before the test (plain pfctl -e); our test token's release turned it off: re-enabling to restore the rig state" | tee -a "$OUT/installer.log"
  sudo pfctl -e >/dev/null 2>&1
fi
check "cleanup: pf is $PF_BEFORE again, as before the test (no pf reference left)" bash -c "sudo pfctl -s info | grep -q '^Status: $PF_BEFORE'"
echo; echo "installer: passed $PASS  failed $FAIL  (details $OUT/installer.log)"
[ "$FAIL" = 0 ]
