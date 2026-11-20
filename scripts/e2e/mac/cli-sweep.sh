#!/bin/bash
# ─── macOS CLI sweep: every catalogue command against the INSTALLED app (run IN the guest) ───
#   local   scratch data dir, no service: Keychain wallet, settings, chain reads, every refusal
#   daemon  the installed LaunchDaemon + test wallet: reads, settings round trips
#   spend   live sessions on the six rig nodes (devnet tDVPN). Sequential, 7 s between txs.
#   ksdns   kill switch (pf) + DNS (networksetup) on every protocol: path lost + tunnel died
#   ledger  dns-off leak (tcpdump), persist, dvpnd SIGKILL, per_hour on all six, live top-up
#   cover   every command in `devnet-dvpn help` was run by some tier (reads the result logs)
# Results: ~/sweep/<tier>.tsv (PASS/FAIL <tab> description <tab> command) + <tier>.log
# Usage: bash cli-sweep.sh local|daemon|spend|ksdns|ledger|cover
# Env: DVPN_KEYFILE (test wallet key file), RIG_PASSWORD (the test user's login password: unlocks
#      the login Keychain over SSH; the rig Keychain holds nothing but test entries)
# Runs under Apple's /bin/bash 3.2: no associative arrays, no ${x,,}, guard empty arrays.
set -u
TIER=${1:?tier}
CLI=devnet-dvpn
OUT=~/sweep; mkdir -p "$OUT"
TSV="$OUT/$TIER.tsv"; : > "$TSV"
PASS=0; FAIL=0
NODE_IP=35.238.250.188
WG=SLVJNn38s5RfqcVW7a7A4hGKqjY7Y1bKkUpG7wrGX5D
AWG=1PwMkSjnyugAZHdHvDsddETzPUAubPkeyWymT7Ercn6
V2=Di5V9K2Vt5uptJUk7oVVnkDRXt9qWy5HhLbkEJMxEuM2
XR=E9RG1iZJjsLfEuLfDYTHM4yXCjyFE21jBbJLFvGoL2FD
OV=9EQJ7dBwneFUse9yy8Hg56u2wPiGF5qkjAaA1ZAr64nP
HY=E8nefMLBuBzG1CrA4dSDU9mqq6ZNpv69Bt3w9QEtzvPf
# another node set (RC2 = node-4) is written to ~/matrix/nodes.env by solo-nodes.sh on; same file lib.sh reads
if [ -f ~/matrix/nodes.env ]; then
  # shellcheck disable=SC1090
  . ~/matrix/nodes.env
  WG=${NODE_WIREGUARD:-$WG}; AWG=${NODE_AMNEZIAWG:-$AWG}; V2=${NODE_V2RAY:-$V2}; XR=${NODE_XRAY:-$XR}
  OV=${NODE_OPENVPN:-$OV}; HY=${NODE_HYSTERIA2:-$HY}
fi
LIB=/usr/local/lib/devnet-dvpn
HOME_D=/var/db/dvpnd/client
# utun interfaces macOS itself keeps (iCloud, etc.): taken once, before any session
UTUN_BASE_FILE="$OUT/utun-base.txt"
[ -s "$UTUN_BASE_FILE" ] || ifconfig -l | tr ' ' '\n' | grep '^utun' > "$UTUN_BASE_FILE"

note() { printf '%s\n' "$*"; }
record() { # PASS|FAIL desc cmd detail
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(printf '%s' "$4" | tr '\n\t' '  ' | cut -c1-300)" >> "$TSV"
  if [ "$1" = PASS ]; then PASS=$((PASS + 1)); note "ok   $2"; else FAIL=$((FAIL + 1)); note "FAIL $2 :: $(printf '%s' "$4" | head -3 | tr '\n' ' ' | cut -c1-240)"; fi
}

# run <expected-exit> <regex|-> <description> -- <cli args...>
LAST=''
run() {
  local want=$1 re=$2 desc=$3; shift 4
  local out code
  out=$($CLI "$@" 2>&1); code=$?
  out=$(printf '%s\n' "$out" | grep -v '^\[rpc\]')
  # a new wallet's recovery phrase is printed once: never let it reach a log file
  out=$(printf '%s\n' "$out" | sed -E '/shown once:/{n;s/.*/<24 words redacted>/;}')
  LAST=$out
  printf '\n### %s\n$ devnet-dvpn %s\n%s\n(exit %s)\n' "$desc" "$*" "$out" "$code" >> "$OUT/$TIER.log"
  # CLI effect line (FINAL-PASS-EFFECT-SPEC.md CLI group): what was asserted and what came back
  local got=no; [ "$re" = - ] || ! printf '%s' "$out" | grep -Eq -- "$re" || got=yes
  echo "CHECK $(printf '%s' "$*" | cut -c1-80) expect exit=$want$([ "$re" != - ] && printf ' match=/%s/' "$(printf '%s' "$re" | cut -c1-60)") got exit=$code$([ "$re" != - ] && printf ' match=%s' "$got") [$desc]"
  if [ "$code" != "$want" ]; then record FAIL "$desc (exit $code, want $want)" "$*" "$out"; return 1; fi
  if [ "$re" != - ] && ! printf '%s' "$out" | grep -Eq -- "$re"; then record FAIL "$desc: no /$re/" "$*" "$out"; return 1; fi
  if printf '%s' "$out" | grep -Eq 'api-key=[A-Za-z0-9]'; then record FAIL "$desc: printed an RPC API key" "$*" '<secret>'; return 1; fi
  record PASS "$desc" "$*" "$(printf '%s' "$out" | head -2)"
}
# check <description> <command…>: any shell assertion, recorded like a CLI step
check() {
  local desc=$1; shift
  local out; out=$("$@" 2>&1); local code=$?
  printf '\n### %s\n$ %s\n%s\n(exit %s)\n' "$desc" "$*" "$out" "$code" >> "$OUT/$TIER.log"
  echo "CHECK $(printf '%s' "$desc" | tr ' ' '_' | cut -c1-60) expect exit=0 got exit=$code" # output stays in the tier log only (a check may read key material)
  if [ $code = 0 ]; then record PASS "$desc" "check" "$out"; else record FAIL "$desc" "check" "$out"; fi
}
json_last() { # <jq filter> — read a CLI --json result from stdin (jq from Homebrew)
  jq -r "$1" 2>/dev/null
}
# the first listed plan whose provider answers a roster request
live_plan() {
  local p
  for p in $($CLI plans list --json 2>/dev/null | json_last '(if type=="array" then . else .plans end)[] | select(.listed) | .address'); do
    $CLI plans roster "$p" >/dev/null 2>&1 && { echo "$p"; return 0; }
  done
  return 1
}
gap() { note "  … 7 s"; sleep 7; }
egress() { curl -s -m 12 https://api.ipify.org; }
new_utuns() { ifconfig -l | tr ' ' '\n' | grep '^utun' | grep -vxF -f "$UTUN_BASE_FILE"; }
our_procs() { # protocol processes started from our root-owned copies, openvpn on a dvpnd config
  ps -axww -o pid=,comm= | awk -v lib="$LIB/" 'index($2, lib) == 1 && $2 != lib "dvpnd" { print $1 }'
  ps -axww -o pid=,comm=,args= | awk '$2 ~ /\/openvpn$/ && /\/var\/db\/dvpnd\// { print $1 }'
}
no_leftovers() { # after a session: our pf anchor, tunnel utuns and protocol processes are gone
  local r l p
  r=$(sudo pfctl -a dvpnd -s rules 2>/dev/null | grep -c .)
  l=$(new_utuns | grep -c .)
  p=$(our_procs | grep -c .)
  echo "pf=$r utun=$l procs=$p egress=$(egress)"
  [ "$r" = 0 ] && [ "$l" = 0 ] && [ "$p" = 0 ]
}
services() { networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*'; }
# effect lines (FINAL-PASS-EFFECT-SPEC.md) from lib.sh, in a subshell so its PATH/OUT stay out of here
SWEEP_DIR=$(cd "$(dirname "$0")" && pwd)
fx() { ( CASE="sweep-$TIER"; LOG=''; . "$SWEEP_DIR/lib.sh"; "$@" ); }
summary() {
  fx effect_after
  note ''; note "$TIER: passed $PASS  failed $FAIL  (details $OUT/$TIER.log)"
  [ "$FAIL" = 0 ]
}
unlock_keychain() {
  [ -n "${RIG_PASSWORD:-}" ] || return 0
  security unlock-keychain -p "$RIG_PASSWORD" ~/Library/Keychains/login.keychain-db 2>/dev/null
}
FN_DEFS="$(declare -f no_leftovers egress new_utuns our_procs); LIB='$LIB'; UTUN_BASE_FILE='$UTUN_BASE_FILE'"
fx effect_before

# ─── local ───
if [ "$TIER" = local ]; then
  unlock_keychain
  SCR=~/ddv-sweep-local; rm -rf "$SCR"; mkdir -p "$SCR"; : > "$OUT/local.log"
  export DVPN_DATA_DIR=$SCR DVPN_DAEMON_SOCKET=/nonexistent/daemon.sock
  unset DVPN_KEYFILE
  ACCT="cli-wallet:$SCR"
  run 0 'network devnet'          'version'                                  -- version
  run 0 'Usage'                   'help'                                     -- help
  run 3 'unknown'                 'unknown command is a usage error'         -- teleport
  run 3 '-'                       'wallet import without a file'             -- wallet import
  run 0 'No wallet'               'wallet show with no wallet'               -- wallet show
  # success path is live-proven by guest-personalize.sh (a new device per cloned rig)
  run 3 'wallet first'            'daemon init with no wallet is refused'    -- daemon init
  run 0 'Created'                 'wallet create (login Keychain)'           -- wallet create --yes
  check 'wallet secret is in the Keychain, not on disk' bash -c "security find-generic-password -s devnet-dvpn -a '$ACCT' >/dev/null && [ -f '$SCR/wallet.cli.keyring' ] && ! grep -rqs '\"secretKey\"' '$SCR'"
  check 'the secret never appeared on a command line (ps during save is not observable; the add line goes on stdin)' bash -c "! grep -rqs -- '-w ' '$SCR'"
  run 0 '^[1-9A-HJ-NP-Za-km-z]{32,44}' 'wallet receive prints address + QR'   -- wallet receive
  run 2 '--yes'                   'wallet logout needs --yes'                -- wallet logout
  run 2 '--yes'                   'wallet send needs --yes'                  -- wallet send --to 9enW4xCJrmytnEC6VsJYPbcT2ng3QTUwUkAHSrKR9Xrj --sol 0.001
  run 3 'not a Solana wallet'     'wallet send rejects a bad address'        -- wallet send --to nope --sol 0.001 --yes
  run 3 'Give --tdvpn'            'wallet send needs an amount'              -- wallet send --to AFaCESaEAFHZZCg6uzPvShVALUuACJnSh3i2wBe14kWB
  run 0 'removed'                 'wallet logout --yes'                      -- wallet logout --yes
  check 'logout removed the Keychain item' bash -c "! security find-generic-password -s devnet-dvpn -a '$ACCT' >/dev/null 2>&1"
  # import: a throwaway key file (never the test wallet), then a junk file must be refused
  node -e "const k=require('crypto').generateKeyPairSync('ed25519');const d=k.privateKey.export({format:'der',type:'pkcs8'}).subarray(16);const p=k.publicKey.export({format:'der',type:'spki'}).subarray(12);require('fs').writeFileSync('$SCR/throwaway.json',JSON.stringify([...d,...p]))"
  run 0 'Imported|imported|Wallet' 'wallet import a key file (throwaway)'  -- wallet import "$SCR/throwaway.json" --yes
  run 0 'removed'                 'wallet logout after import'               -- wallet logout --yes
  run 0 'Created'                 'wallet create again'                      -- wallet create --yes
  run 0 'removed'                 'wallet logout again'                      -- wallet logout --yes
  echo 'not a wallet' > "$SCR/junk.txt"
  run 1 '-'                       'wallet import refuses a junk file'        -- wallet import "$SCR/junk.txt" --yes
  # a locked Keychain (SSH session without unlock) gives an action, not a stack trace
  if [ -n "${RIG_PASSWORD:-}" ]; then
    security lock-keychain ~/Library/Keychains/login.keychain-db
    run 1 'locked|--keyfile'      'wallet create with the Keychain locked says what to do' -- wallet create --yes
    unlock_keychain
  fi
  run 0 'defaultBasis'            'settings get'                             -- settings get
  run 0 'defaultBasis = "per_hour"' 'settings set (allow-listed key)'        -- settings set defaultBasis=per_hour
  run 3 'unknown setting'         'settings set rejects unknown keys'        -- settings set bogus=1
  run 1 'value for defaultGb is not allowed' 'settings set rejects a bad value'     -- settings set defaultGb=3
  run 0 'api.devnet'              'rpc state'                                -- rpc state
  run 1 'https'                   'rpc set rejects plain http'               -- rpc set http://example.com
  run 0 'RPC pool: https://api.devnet.solana.com' 'rpc set (public devnet)'  -- rpc set https://api.devnet.solana.com
  run 0 'wallet'                  'poll show'                                -- poll show
  run 0 'wallet *= *30|wallet.*30' 'poll set wallet=30'                      -- poll set wallet=30
  run 3 '15 to 3600'               'poll set refuses a too-fast cadence'      -- poll set wallet=1
  run 0 '-'                       'poll reset wallet'                        -- poll reset wallet
  run 0 '-'                       'poll run nodes'                           -- poll run nodes
  run 0 '-'                       'poll watch for 10 s'                      -- poll watch --seconds 10
  run 0 '-'                       'daemon dns-check (Cloudflare answers)'    -- daemon dns-check --dns cloudflare
  run 1 '-'                       'daemon dns-check: a dead server fails (exit 1)' -- daemon dns-check --dns 192.0.2.1
  run 0 '-'                       'split status'                             -- split status
  run 0 'Google Chrome'           'split apps --search Chrome (full path)'   -- split apps --search Chrome
  run 2 '--yes'                   'settings reset needs --yes'               -- settings reset
  run 0 '-'                       'settings reset --yes'                     -- settings reset --yes
  run 0 'devnet'                  'rpc state after settings reset'           -- rpc state
  run 0 '-'                       'nodes list (chain read + probes)'         -- nodes list
  run 0 '-'                       'nodes list --online'                      -- nodes list --online
  run 0 '-'                       'nodes list --protocol wireguard --sort price --no-probe' -- nodes list --protocol wireguard --sort price --no-probe
  run 0 '-'                       'nodes list --country US --no-probe'       -- nodes list --country US --no-probe
  run 0 "$WG"                     'nodes show (WireGuard node)'              -- nodes show $WG
  run 0 'tDVPN'                   'cost per GB'                              -- cost $WG --units 2
  run 0 'tDVPN'                   'cost per hour'                            -- cost $WG --basis per_hour --units 1
  run 0 'Fav|fav'                 'nodes fav toggles a favourite'            -- nodes fav $WG
  run 0 '-'                       'nodes recent'                             -- nodes recent
  run 0 'tDVPN|No plans|plan'     'plans list'                               -- plans list
  PLAN=${PLAN_ADDR:-$(live_plan)}
  if [ -n "$PLAN" ]; then run 0 '-' 'plans roster (first listed plan)' -- plans roster "$PLAN"; else record FAIL 'plans roster: no listed plan has a provider answering' 'plans roster' ''; fi
  run 3 'plans subscribe'         'plans subscribe needs a plan address'     -- plans subscribe nope
  run 0 '-'                       'history list (empty)'                     -- history list
  run 0 '-'                       'history summary (empty)'                  -- history summary
  run 0 '-'                       'history export'                           -- history export --out "$SCR/h.csv"
  check 'history export wrote a CSV header' bash -c "head -1 '$SCR/h.csv' | grep -q ','"
  run 0 '-'                       'logs'                                     -- logs --lines 5
  run 0 'off|not set'             'proxy status'                             -- proxy status
  run 1 'no SOCKS endpoint'       'proxy on refuses without a SOCKS session' -- proxy on --yes
  run 0 '-'                       'proxy off with nothing set is a no-op'    -- proxy off
  run 1 'SOCKS|session'           'proxy browser refuses without a session'  -- proxy browser
  run 0 'not reachable|not running' 'status without a daemon says so'        -- status
  run 2 '--yes'                   'connect needs --yes'                      -- connect $WG
  run 2 '--yes'                   'settle run needs --yes'                   -- settle run
  run 1 'wallet'                  'device setup without a wallet'            -- device setup --yes
  run 1 'device setup|wallet'     'daemon install before device setup'       -- daemon install --yes
  run 2 '--yes'                   'daemon uninstall needs --yes'             -- daemon uninstall
  run 0 'tDVPN|deposit|lock'      'test plan (no transaction)'               -- test plan $WG $V2
  run 0 '-'                       'test history (empty)'                     -- test history
  run 0 '-'                       'quality ip'                               -- quality ip
  run 0 'Mbit|MB/s|Mbps'          'quality speed'                            -- quality speed
  run 0 'ready|missing'           'daemon drivers (no admin)'                -- daemon drivers
  summary; exit $?
fi

# ─── daemon (installed service, test wallet) ───
export DVPN_DATA_DIR=${DVPN_DATA_DIR:-$HOME/ddv-data}
: "${DVPN_KEYFILE:?set DVPN_KEYFILE to the test wallet key file}"
if [ "$TIER" = daemon ]; then
  : > "$OUT/daemon.log"
  run 0 'network devnet .* OK'    'daemon version (network identity)'        -- daemon version
  run 0 '-'                       'daemon doctor'                            -- daemon doctor
  check 'doctor has no FAIL row' bash -c "! printf '%s' \"\$(devnet-dvpn daemon doctor 2>&1)\" | grep -q '^FAIL'"
  check 'doctor: the service runs this app version (service_update ok)' bash -c "devnet-dvpn daemon doctor --json 2>/dev/null | jq -e '.[] | select(.name==\"service_update\") | .ok' | grep -q true"
  run 0 'killSwitch'              'daemon settings'                          -- daemon settings
  run 0 'All VPN drivers are ready' 'daemon drivers'                         -- daemon drivers
  # dvpnd's home: nothing readable by other users; no key or session secret readable by group dvpn
  # device.pub is public on purpose; protocol folders' config.toml(.bak) are the service settings the
  # app reads (tun on/off, no secret). Everything else (database, keys, session files) is closed.
  check 'dvpnd home: no world-readable file (but device.pub)' bash -c "f=\$(sudo find /var/db/dvpnd -type f -perm -004 ! -name device.pub 2>/dev/null); [ -z \"\$f\" ] || { echo \"\$f\"; exit 1; }"
  check 'dvpnd home: home and client dirs are not world-accessible' bash -c "for d in /var/db/dvpnd /var/db/dvpnd/client; do [ \$(( 0\$(stat -f %Lp \$d) & 7 )) = 0 ] || { stat -f '%Sp %N' \$d; exit 1; }; done"
  check 'dvpnd home: database is root only' bash -c "f=\$(sudo find /var/db/dvpnd -type f -name 'data.db*' -perm +077 2>/dev/null); [ -z \"\$f\" ] || { echo \"\$f\"; exit 1; }"
  check 'dvpnd home: keys and protocol session files are not group-readable' bash -c "f=\$(sudo find /var/db/dvpnd -type f -perm -040 ! -name config.toml ! -name config.toml.bak \( -path '*/keys/*' -o -path '*/wireguard/*' -o -path '*/amneziawg/*' -o -path '*/openvpn/*' -o -path '*/v2ray/*' -o -path '*/xray/*' -o -path '*/hysteria2/*' \) 2>/dev/null); [ -z \"\$f\" ] || { echo \"\$f\"; exit 1; }"
  run 0 'Ready +yes'              'device show'                              -- device show
  run 0 '-'                       'device plan'                              -- device plan --allowance 2
  run 0 'Recorded device|[1-9A-HJ-NP-Za-km-z]{32,44}' 'device register reads device.pub' -- device register
  run 0 'Wallet|Daemon'           'status'                                   -- status
  run 0 '-'                       'sessions'                                 -- sessions
  run 0 '-'                       'channels'                                 -- channels
  run 0 '-'                       'tickets'                                  -- tickets
  run 0 '-'                       'settle list'                              -- settle list
  run 0 '-'                       'plans subscriptions'                      -- plans subscriptions
  run 0 'tDVPN'                   'wallet show (test wallet, read)'          -- wallet show
  run 0 '[Nn]o (active )?session|Not connected' 'disconnect with no session is a no-op' -- disconnect
  run 0 '-'                       'daemon restore-network (nothing to restore)' -- daemon restore-network
  run 2 '--yes'                   'device setup stops for --yes'             -- device setup --allowance 3
  run 2 '--yes'                   'daemon install stops for --yes'           -- daemon install
  run 2 '--yes'                   'daemon set stops for --yes'               -- daemon set --kill-switch on
  run 2 '--yes'                   'device revoke stops for --yes'            -- device revoke
  run 2 '--yes'                   'settle withdraw stops for --yes'          -- settle withdraw
  run 2 '--yes'                   'daemon repair-drivers stops for --yes'    -- daemon repair-drivers
  run 2 '--yes'                   'daemon uninstall stops for --yes'         -- daemon uninstall
  # socket + home permissions as setup left them
  check 'socket root:dvpn 0660 with an ACL for this user' bash -c "s=\$(stat -f '%Su:%Sg %Lp' $HOME_D/daemon.sock); [ \"\$s\" = 'root:dvpn 660' ] && ls -led $HOME_D | grep -q \"user:\$(id -un) allow\""
  check 'device key folder is root-only' bash -c "! ls $HOME_D/client/keys >/dev/null 2>&1 && [ \"\$(sudo stat -f '%Su %Lp' $HOME_D/client/keys)\" = 'root 700' ]"
  check 'service runs root-owned copies only (no Homebrew, no app bundle on its PATH)' bash -c "p=\$(sudo launchctl print system/network.sentinel.devnet-dvpn.dvpnd | grep -E 'PATH|program'); ! printf '%s' \"\$p\" | grep -Eq 'homebrew|/usr/local/bin|\\.app/'; [ \"\$(stat -f %Su $LIB/dvpnd)\" = root ]"
  # settings round trips through the root helper (restarts the service each time)
  run 0 '-'                       'daemon set --allow-lan true'              -- daemon set --allow-lan true --yes
  run 0 'allowLan +true'          'allow-lan reads back true'                -- daemon settings
  check 'allow_lan written to the service config' bash -c "grep -q '^allow_lan = true' $HOME_D/client/config.toml"
  run 0 '-'                       'daemon set --allow-lan false --dns cloudflare --dns-mode networksetup' -- daemon set --allow-lan false --dns cloudflare --dns-mode networksetup --yes
  run 0 '1.1.1.1'                 'dns reads back'                           -- daemon settings
  run 3 'DNS mode'                'daemon set refuses the Windows-only netsh' -- daemon set --dns-mode netsh --yes
  run 3 'DNS mode'                'daemon set refuses the Linux-only resolvectl' -- daemon set --dns-mode resolvectl --yes
  run 0 '-'                       'daemon set --kill-switch off'             -- daemon set --kill-switch off --yes
  run 0 'killSwitch +off'         'kill switch reads back off'               -- daemon settings
  check 'service loaded and socket answering after restarts' bash -c "sudo launchctl print system/network.sentinel.devnet-dvpn.dvpnd | grep -q 'state = running' && devnet-dvpn daemon version >/dev/null"
  run 0 'Fresh|ok|ready|repair|All VPN drivers|nothing to install' 'daemon repair-drivers (nothing missing)' -- daemon repair-drivers --yes
  summary; exit $?
fi

# ─── spend (live sessions) ───
if [ "$TIER" = spend ]; then
  : > "$OUT/spend.log"
  DIRECT=$(egress)
  check "direct egress before sessions = $DIRECT" bash -c "[ -n '$DIRECT' ] && [ '$DIRECT' != '$NODE_IP' ]"
  socks_of() { $CLI proxy status --json 2>/dev/null | grep -oE '127\.0\.0\.1:[0-9]+' | head -1; }
  session() { # <name> <node> [extra connect args…]
    local name=$1 node=$2; shift 2
    run 0 'Connected|connected' "connect $name per GB" -- connect "$node" --units 1 "$@" --yes || { $CLI disconnect >/dev/null 2>&1; gap; return 1; }
    sleep 3
    run 0 'Connected|connected|'"$name" "status while on $name" -- status
    # V2Ray/Xray are SOCKS sessions: only traffic sent to their SOCKS port leaves through the node
    local via=''
    case $name in v2ray|xray) via="--socks5-hostname $(socks_of)" ;; esac
    check "$name: egress IP = node ($NODE_IP)${via:+ via SOCKS}" bash -c "for i in 1 2 3; do [ \"\$(curl -s -m 12 $via https://api.ipify.org)\" = '$NODE_IP' ] && exit 0; sleep 3; done; exit 1"
    case $name in wireguard|amneziawg|openvpn|hysteria2)
      check "$name: a new utun carries it (positive control for the leftover check)" bash -c "$FN_DEFS; [ -n \"\$(new_utuns)\" ]" ;;
    esac
    case $name in v2ray|xray|hysteria2|openvpn)
      check "$name: leftover pattern sees the live process (positive control)" bash -c "$FN_DEFS; [ -n \"\$(our_procs)\" ]" ;;
    esac
    run 0 "$NODE_IP" "$name: quality ip shows the node" -- quality ip
    gap
    run 0 '-' "disconnect $name" -- disconnect
    sleep 3
    check "$name: no leftovers, egress back to direct" bash -c "$FN_DEFS; for i in 1 2 3; do no_leftovers && [ \"\$(egress)\" = '$DIRECT' ] && exit 0; sleep 4; done; no_leftovers; exit 1"
    gap
  }
  session wireguard "$WG"
  session amneziawg "$AWG"
  session openvpn "$OV"
  session hysteria2 "$HY"
  session xray "$XR"
  # V2Ray: SOCKS session → macOS system proxy on every service + Chrome as the system-proxy oracle
  run 0 'Connected|connected' 'connect v2ray per GB' -- connect "$V2" --units 1 --yes
  sleep 3
  run 0 'socks|SOCKS|127.0.0.1' 'proxy status shows the SOCKS endpoint' -- proxy status
  SOCKS=$(socks_of)
  check "v2ray: SOCKS $SOCKS egress = node" bash -c "[ \"\$(curl -s -m 15 --socks5-hostname $SOCKS https://api.ipify.org)\" = '$NODE_IP' ]"
  BEFORE_PROXY=$(services | while IFS= read -r s; do printf '%s|' "$s"; networksetup -getsocksfirewallproxy "$s" | tr '\n' ' '; echo; done)
  run 0 '-' 'proxy on --yes (networksetup, every service)' -- proxy on --yes
  check "proxy on: every enabled service has SOCKS $SOCKS" bash -c "services() { networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*'; }; services | while IFS= read -r s; do o=\$(networksetup -getsocksfirewallproxy \"\$s\"); printf '%s\n' \"\$o\" | grep -q '^Enabled: Yes' && printf '%s\n' \"\$o\" | grep -q \"^Server: \${0%%:*}\" && printf '%s\n' \"\$o\" | grep -q \"^Port: \${0##*:}\" || { echo \"\$s: \$o\"; exit 1; }; done" "$SOCKS"
  check 'proxy on: Chrome with no flags (system proxy) exits at the node' bash -c "d=\$(mktemp -d); ip=\$('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' --headless=new --disable-gpu --no-first-run --user-data-dir=\"\$d\" --dump-dom https://api.ipify.org 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){3}' | head -1); rm -rf \"\$d\"; echo \"chrome=\$ip\"; [ \"\$ip\" = '$NODE_IP' ]"
  run 0 'on|127.0.0.1' 'proxy status (on)' -- proxy status
  run 0 '-' 'proxy off' -- proxy off
  AFTER_PROXY=$(services | while IFS= read -r s; do printf '%s|' "$s"; networksetup -getsocksfirewallproxy "$s" | tr '\n' ' '; echo; done)
  check 'proxy off: every service back exactly as before' bash -c "[ \"\$0\" = \"\$1\" ] || { printf 'before:\n%s\nafter:\n%s\n' \"\$0\" \"\$1\"; exit 1; }" "$BEFORE_PROXY" "$AFTER_PROXY"
  # the browser window needs the console GUI session: launch the CLI inside it
  run 0 '-' 'proxy browser (Chrome, own profile, through SOCKS)' -- proxy browser --browser chrome --url https://api.ipify.org
  sleep 6
  check 'browser window runs with --proxy-server=socks5' bash -c "pgrep -fl '[G]oogle Chrome.*--proxy-server=socks5://127.0.0.1' | head -1 | grep -q proxy-server"
  pkill -f '[G]oogle Chrome.*--proxy-server=socks5://127.0.0.1' 2>/dev/null
  # switch: v2ray → wireguard without a gap in between
  gap
  run 0 'Connected|connected' 'connect --switch v2ray → wireguard' -- connect "$WG" --units 1 --switch --yes
  sleep 3
  check 'after switch: egress = node' bash -c "[ \"\$(curl -s -m 12 https://api.ipify.org)\" = '$NODE_IP' ]"
  gap
  run 0 '-' 'disconnect after switch' -- disconnect
  gap
  # per hour (stream channel)
  run 0 'Connected|connected' 'connect wireguard per hour' -- connect "$WG" --basis per_hour --units 1 --yes
  sleep 5
  check 'per hour: egress = node' bash -c "[ \"\$(curl -s -m 12 https://api.ipify.org)\" = '$NODE_IP' ]"
  gap
  run 0 '-' 'disconnect per hour' -- disconnect
  gap
  # follow mode: connect and stream status until the session ends (ended by a disconnect from a 2nd shell)
  ( sleep 25; $CLI disconnect >/dev/null 2>&1 ) &
  STOPPER=$!
  run 0 '-' 'connect --follow (ends on disconnect)' -- connect "$XR" --units 1 --yes --follow
  wait "$STOPPER"
  gap
  # money: top up an open channel, settle, withdraw
  run 0 '-' 'channels (after sessions)' -- channels
  CH=$($CLI channels --json 2>/dev/null | json_last '[(if type=="array" then . else .channels end)[] | select((.status // .state // "") | test("open";"i"))][0] | (.address // .channel // "")')
  if [ -n "$CH" ] && [ "$CH" != null ]; then run 0 '-' "channels fund $CH" -- channels fund "$CH" --tdvpn 1 --yes; else record FAIL 'channels fund: no open channel found' 'channels fund' "$($CLI channels 2>&1 | head -5)"; fi
  gap
  run 0 '-' 'settle list' -- settle list
  run 0 '-' 'settle run' -- settle run --yes
  gap
  run 0 '-' 'settle withdraw' -- settle withdraw --yes
  gap
  # plans: subscribe → connect on the subscription → close (PLAN_ADDR must be one #31 allowed)
  if [ -n "${PLAN_ADDR:-}" ]; then
    PLAN=$PLAN_ADDR
    run 0 '-' 'plans subscribe' -- plans subscribe "$PLAN" --yes
    gap
    run 0 '-' 'plans subscriptions' -- plans subscriptions
    SUB=$($CLI plans subscriptions --json 2>/dev/null | json_last '(if type=="array" then . else .subscriptions end) | last | (.address // .subscription // "")')
    ROSTER=$($CLI plans roster "$PLAN" --json 2>/dev/null | grep -oE "$WG|$V2|$XR|$OV|$HY|$AWG" | head -1)
    if [ -n "$SUB" ] && [ -n "$ROSTER" ]; then
      run 0 'Connected|connected' 'connect on the subscription' -- connect "$ROSTER" --plan "$SUB" --yes
      sleep 3
      check 'plan session: egress = node' bash -c "[ \"\$(curl -s -m 12 https://api.ipify.org)\" = '$NODE_IP' ]"
      gap
      run 0 '-' 'disconnect plan session' -- disconnect
      gap
    else
      record FAIL "plan session: no subscription or no rig node on the roster (sub='$SUB' roster='$ROSTER')" 'plans roster' ''
    fi
    [ -n "$SUB" ] && run 0 '-' 'plans close the subscription' -- plans close "$SUB" --yes
    gap
  else
    note 'PLAN_ADDR not set: plan subscribe/connect/close skipped (needs a plan #31 allows)'
  fi
  # node test run on two nodes, then its reports
  run 0 'FAST|SLOW|FAIL' 'test run (wireguard + v2ray)' -- test run $WG $V2 --max-spend 5 --yes
  gap
  run 0 '-' 'test history' -- test history
  run 0 '-' 'test show --compare' -- test show --compare
  run 0 '-' 'test export' -- test export --out "$OUT/test-run.json"
  run 0 '-' 'test stop (nothing running)' -- test stop
  run 0 '-' 'nodes recent (after sessions)' -- nodes recent
  run 0 '-' 'history list' -- history list
  run 0 '-' 'history summary' -- history summary
  run 0 '-' 'sessions' -- sessions
  run 0 '-' 'tickets' -- tickets
  check 'final: no leftovers, direct egress' bash -c "$FN_DEFS; no_leftovers && [ \"\$(egress)\" = '$DIRECT' ]"
  summary; exit $?
fi

# ─── ksdns: kill switch (pf) + DNS (networksetup) on every protocol ───
# Per protocol: kill switch on + Cloudflare DNS → connect → egress = node, the dvpnd pf anchor
# holds rules naming the utun that actually exists (gap #29 shape), names resolve, the VPN's DNS
# is set on every service → 1) the path to the server is lost (a test pf anchor placed BEFORE
# dvpnd's drops everything to the node) → nothing may leave directly → 2) the tunnel itself
# dies (utun down / protocol process killed) → nothing may leave directly → disconnect +
# restore-network → direct egress back, pf/DNS/utun/processes exactly as before. SSH into the
# guest drops while the kill switch is on (allow_lan off): run this detached; the deadman is put
# on hold around each deliberate block.
if [ "$TIER" = ksdns ]; then
  : > "$OUT/ksdns.log"
  DIRECT=$(egress)
  KS_PAY=${KS_PAY:-gb}
  [ "$KS_PAY" = gb ] || PLAN=${PLAN_ADDR:?set PLAN_ADDR}
  hold() { sudo touch /var/run/ddv-deadman.hold; }
  dns_now() { services | while IFS= read -r s; do printf '%s=%s;' "$s" "$(networksetup -getdnsservers "$s" | tr '\n' ',')"; done; }
  pf_main() { sudo pfctl -sr 2>/dev/null; }
  DNS_BEFORE=$(dns_now)
  PF_MAIN_BEFORE=$(pf_main | grep -v '"ddvtest"')
  # the test anchor: inserted right before dvpnd's anchor line (same way dvpnd inserts its own)
  block_node() {
    local rules
    rules=$(pf_main)
    if ! printf '%s\n' "$rules" | grep -q 'anchor "ddvtest"'; then
      rules=$(printf '%s\n' "$rules" | awk '/^anchor "dvpnd"/ && !d { print "anchor \"ddvtest\" out quick all"; d=1 } { print }')
      printf '%s\n' "$rules" | sudo pfctl -R -f - 2>&1 | grep -v 'ALTQ\|^$' >&2
    fi
    printf 'block drop out quick to %s\n' "$NODE_IP" | sudo pfctl -a ddvtest -f - 2>&1 | grep -v 'ALTQ\|^$' >&2
  }
  # also detach the test anchor: dvpnd refuses the kill switch ("conflicting pf anchor
  # attachment") when any rule sits before its own anchor, so a left-over line broke every
  # later kill-switch connect (#33 rig 3: five protocols after the first block)
  unblock_node() {
    sudo pfctl -a ddvtest -F all >/dev/null 2>&1
    pf_main | grep -v '^anchor "ddvtest"' | sudo pfctl -R -f - 2>&1 | grep -v 'ALTQ\|^$' >&2
  }
  tunnel_utun() { new_utuns | tail -1; }
  check "direct egress before = $DIRECT" bash -c "[ -n '$DIRECT' ] && [ '$DIRECT' != '$NODE_IP' ]"
  run 0 '-' 'kill switch on, Cloudflare DNS, networksetup' -- daemon set --kill-switch on --dns cloudflare --dns-mode networksetup --allow-lan false --yes
  run 0 'killSwitch +persist' 'kill switch on reads back persist (one On = persist since 97eb1077)' -- daemon settings
  gap
  ks_case() { # <name> <node> <subscription>
    local name=$1 node=$2 sub=$3 via='' link
    hold
    local pay="--units 1"; [ "$KS_PAY" = gb ] || pay="--plan $sub"
    run 0 'Connected|connected' "ks $name: connect (${KS_PAY})" -- connect "$node" $pay --yes || { $CLI disconnect >/dev/null 2>&1; $CLI daemon restore-network >/dev/null 2>&1; gap; return 1; }
    sleep 4
    case $name in v2ray|xray) via="--socks5-hostname $($CLI proxy status --json 2>/dev/null | grep -oE '127\.0\.0\.1:[0-9]+' | head -1)" ;; esac
    check "ks $name: egress = node${via:+ via SOCKS}" bash -c "for i in 1 2 3; do [ \"\$(curl -s -m 12 $via https://api.ipify.org)\" = '$NODE_IP' ] && exit 0; sleep 3; done; exit 1"
    link=$(tunnel_utun)
    check "ks $name: pf anchor dvpnd is loaded and pf is enabled" bash -c "for i in 1 2 3 4 5 6; do sudo pfctl -a dvpnd -s rules 2>/dev/null | grep -q 'block drop out all' && sudo pfctl -s info 2>/dev/null | grep -q 'Status: Enabled' && exit 0; sleep 2; done; exit 1"
    case $name in wireguard|amneziawg|openvpn|hysteria2)
      # #29 shape: rules armed before the adapter existed would name no utun (or a stale one)
      check "ks $name: pf passes the utun that exists ($link)" bash -c "[ -n '$link' ] && ifconfig '$link' >/dev/null && for i in 1 2 3 4 5 6; do sudo pfctl -a dvpnd -s rules 2>/dev/null | grep -q 'pass out quick on $link all' && exit 0; sleep 2; done; exit 1" ;;
    esac
    check "ks $name: names resolve with the kill switch on" bash -c "dscacheutil -q host -a name example.com | grep -q ip_address || curl -s -m 12 $via -o /dev/null -w '%{http_code}' https://example.com | grep -q 200"
    case $name in wireguard|amneziawg|openvpn|hysteria2)
      # Q0365: dvpnd's DNS forwarder listens on the session utun's own IPv4:53; every service points there
      check "ks $name: VPN DNS = the session's forwarder (127.0.0.1, or the utun IPv4 if :53 is taken; Q0377) on every service" bash -c "a=\$(sudo -n grep -F 'dns forwarder racing' /Library/Logs/DevnetDVPN/dvpnd.log | tail -1 | grep -oE 'addr.:.[0-9.]+:53' | grep -oE '[0-9.]+:53' | cut -d: -f1); [ -n \"\$a\" ] || exit 1; networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*' | while IFS= read -r s; do networksetup -getdnsservers \"\$s\" | grep -qx \"\$a\" || { echo \"\$s\"; exit 1; }; done" ;;
    esac
    case $name in v2ray|xray)
      check "ks $name: a direct (non-proxied) request is blocked" bash -c "out=\$(curl -s -m 8 https://api.ipify.org); [ -z \"\$out\" ] || [ \"\$out\" != '$DIRECT' ]" ;;
    esac
    # 1) the path to the server fails while the protocol keeps running (the usual "VPN drops")
    hold
    block_node
    sleep 8
    check "ks $name: path to the server lost → no direct leak (request fails)" bash -c "out=\$(curl -s -m 10 https://api.ipify.org); [ -z \"\$out\" ] || [ \"\$out\" = '$NODE_IP' ]"
    check "ks $name: path to the server lost → never the direct IP" bash -c "[ \"\$(curl -s -m 10 https://api.ipify.org)\" != '$DIRECT' ]"
    unblock_node
    sleep 3
    # 2) the tunnel itself dies (utun down / protocol process killed). UPSTREAM-GAPS #41: for
    #    user-space protocols cf4c372 may end the session and release the kill switch.
    hold
    case $name in
      wireguard|amneziawg) [ -n "$link" ] && sudo ifconfig "$link" down ;;
      openvpn|hysteria2|v2ray|xray) sudo pkill -x "$name" ;;  # this guest runs no other copy of these
    esac
    sleep 3
    check "ks $name: tunnel broken → no direct leak (request fails)" bash -c "out=\$(curl -s -m 10 https://api.ipify.org); [ -z \"\$out\" ] || [ \"\$out\" = '$NODE_IP' ]"
    check "ks $name: tunnel broken → never the direct IP" bash -c "[ \"\$(curl -s -m 10 https://api.ipify.org)\" != '$DIRECT' ]"
    # dvpnd ends the session after ~5 failed stats reads as "service stats unavailable"; before
    # ddv6 that released the kill switch (gap #41). So check again after the session ended.
    hold
    sleep 25
    run 0 '-' "ks $name: status after the tunnel died (recorded)" -- status
    check "ks $name: 25 s later (session ended under the user) → kill switch still up" bash -c "sudo pfctl -a dvpnd -s rules | grep -q 'block drop out all'"
    check "ks $name: 25 s later → never the direct IP" bash -c "[ \"\$(curl -s -m 10 https://api.ipify.org)\" != '$DIRECT' ]"
    check "ks $name: IPv6 never leaves directly" bash -c "out=\$(curl -6 -s -m 8 https://api64.ipify.org); [ -z \"\$out\" ] || { echo \"direct v6: \$out\"; exit 1; }"
    hold
    run 0 '-' "ks $name: disconnect" -- disconnect
    sleep 3
    run 0 '-' "ks $name: restore network" -- daemon restore-network
    sleep 3
    check "ks $name: after restore: no leftovers, direct egress back" bash -c "$FN_DEFS; for i in 1 2 3 4; do no_leftovers && [ \"\$(egress)\" = '$DIRECT' ] && exit 0; sleep 5; done; no_leftovers; exit 1"
    check "ks $name: after restore: DNS on every service as before" bash -c "[ \"\$0\" = \"\$(networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*' | while IFS= read -r s; do printf '%s=%s;' \"\$s\" \"\$(networksetup -getdnsservers \"\$s\" | tr '\n' ',')\"; done)\" ]" "$DNS_BEFORE"
    gap
  }
  KS_LIST=${KS_LIST:-"wireguard:$WG amneziawg:$AWG openvpn:$OV hysteria2:$HY v2ray:$V2 xray:$XR"}
  SUB=''
  if [ "$KS_PAY" != gb ]; then
    run 0 '-' 'plans subscribe' -- plans subscribe "$PLAN" --yes
    gap
    SUB=$($CLI plans subscriptions --json 2>/dev/null | json_last '(if type=="array" then . else .subscriptions end) | last | (.address // .subscription // "")')
  fi
  for pn in $KS_LIST; do ks_case "${pn%%:*}" "${pn#*:}" "$SUB"; done
  [ -n "$SUB" ] && { run 0 '-' 'plans close' -- plans close "$SUB" --yes; gap; }
  run 0 '-' 'kill switch off again' -- daemon set --kill-switch off --yes
  # the test anchor line goes too: the main ruleset ends exactly as it started
  rules=$(pf_main | grep -v '"ddvtest"'); printf '%s\n' "$rules" | sudo pfctl -R -f - >/dev/null 2>&1
  check 'final: direct egress, nothing left' bash -c "$FN_DEFS; no_leftovers && [ \"\$(egress)\" = '$DIRECT' ]"
  check 'final: pf main ruleset as before (no dvpnd or test anchor left)' bash -c "[ \"\$(sudo pfctl -sr 2>/dev/null | grep -v '\"ddvtest\"\|\"dvpnd\"')\" = \"\$(printf '%s\n' \"\$0\" | grep -v '\"dvpnd\"')\" ]" "$PF_MAIN_BEFORE"
  check 'final: DNS on every service as before' bash -c "[ \"\$0\" = \"\$(networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*' | while IFS= read -r s; do printf '%s=%s;' \"\$s\" \"\$(networksetup -getdnsservers \"\$s\" | tr '\n' ',')\"; done)\" ]" "$DNS_BEFORE"
  summary; exit $?
fi

# ─── ledger: the items #31 and #32 listed as not yet proven (guest only, detached) ───
#   dns-off   kill switch OFF: no DNS query leaves on the physical interface while a full tunnel
#             is up (tcpdump on the default-route interface; V2Ray/Xray: a SOCKS-resolved name)
#   persist   kill switch PERSIST: service restart and dvpnd SIGKILL mid-session never leak;
#             the block stays after the session ends until restore-network
#   kill-on   kill switch ON + dvpnd SIGKILL: launchd restarts it, nothing leaks meanwhile
#   per_hour  every protocol on a stream channel
#   topup     channels fund on the channel of the LIVE session, session keeps working
if [ "$TIER" = ledger ]; then
  : > "$OUT/ledger.log"
  DIRECT=$(egress)
  NIC=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
  SVC_LABEL=network.sentinel.devnet-dvpn.dvpnd
  hold() { sudo touch /var/run/ddv-deadman.hold; }
  restore() { $CLI disconnect >/dev/null 2>&1; sleep 2; $CLI daemon restore-network >/dev/null 2>&1; sleep 3; }
  back_clean() { check "$1: after restore: nothing left, direct egress back" bash -c "$FN_DEFS; for i in 1 2 3 4; do no_leftovers && [ \"\$(egress)\" = '$DIRECT' ] && exit 0; sleep 5; done; no_leftovers; exit 1"; }
  svc_up() { for i in $(seq 1 40); do $CLI daemon version >/dev/null 2>&1 && return 0; sleep 3; done; return 1; }
  # DNS packets on the physical interface while names are resolved (0 = no leak)
  dns_on_nic() { # <resolver command…>
    local f; f=$(mktemp)
    sudo tcpdump -ni "$NIC" -l 'udp port 53 or tcp port 53' > "$f" 2>/dev/null & local tp=$!
    sleep 2
    for n in 1 2 3; do "$@" "ddv-leak-$RANDOM$RANDOM.example.com" >/dev/null 2>&1; done
    sleep 8; sudo kill "$tp" 2>/dev/null; wait "$tp" 2>/dev/null
    local n; n=$(grep -c . "$f")
    # keep the capture when a "must be 0" check saw packets (Q0205: show WHAT left); only checks that set
    # DNS_LEAK_LABEL keep one, so the no-VPN positive control (packets expected) never does
    [ "$n" -gt 0 ] && [ -n "${DNS_LEAK_LABEL:-}" ] && cp "$f" "$HOME/sweep/dns-leak-$(date -u +%Y%m%dT%H%M%SZ)-$DNS_LEAK_LABEL.txt" 2>/dev/null
    echo "$n"; rm -f "$f"
  }
  lookup() { dscacheutil -q host -a name "$1"; }
  DNS_FN="$(declare -f dns_on_nic lookup); NIC=$NIC"
  check "direct egress before = $DIRECT, interface $NIC" bash -c "[ -n '$DIRECT' ] && [ '$DIRECT' != '$NODE_IP' ] && [ -n '$NIC' ]"
  # positive control: without a VPN a lookup DOES show on the interface (else 0 below proves nothing)
  check "control: with no VPN, lookups are seen on $NIC" bash -c "$DNS_FN; [ \"\$(dns_on_nic lookup)\" -gt 0 ]"

  # dns-off
  run 0 '-' 'dns-off: kill switch off, Cloudflare DNS, networksetup' -- daemon set --kill-switch off --dns cloudflare --dns-mode networksetup --yes
  for pn in wireguard:$WG amneziawg:$AWG openvpn:$OV hysteria2:$HY v2ray:$V2 xray:$XR; do
    name=${pn%%:*}; node=${pn#*:}
    run 0 'Connected|connected' "dns-off $name: connect (per GB)" -- connect "$node" --units 1 --yes || { restore; gap; continue; }
    sleep 4
    case $name in
      v2ray|xray)
        S=$($CLI proxy status --json 2>/dev/null | grep -oE '127\.0\.0\.1:[0-9]+' | head -1)
        check "dns-off $name: SOCKS-resolved names never hit $NIC port 53" bash -c "$DNS_FN; DNS_LEAK_LABEL=dns-off-$name; c() { curl -s -m 8 --socks5-hostname $S -o /dev/null https://$1; }; [ \"$(dns_on_nic c)\" = 0 ]" ;;
      *)
        check "dns-off $name: VPN DNS = the session's forwarder (127.0.0.1, or the utun IPv4 if :53 is taken; Q0377) on every service, first resolver in scutil (Q0365)" bash -c "a=\$(sudo -n grep -F 'dns forwarder racing' /Library/Logs/DevnetDVPN/dvpnd.log | tail -1 | grep -oE 'addr.:.[0-9.]+:53' | grep -oE '[0-9.]+:53' | cut -d: -f1); [ -n \"\$a\" ] || exit 1; networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*' | while IFS= read -r s; do networksetup -getdnsservers \"\$s\" | grep -qx \"\$a\" || exit 1; done && scutil --dns | awk '/resolver #1/{f=1} f && /nameserver\[0\]/{print \$3; exit}' | grep -qx \"\$a\""
        check "dns-off $name: no lookup leaves on $NIC (kill switch off)" bash -c "$DNS_FN; DNS_LEAK_LABEL=dns-off-$name; [ \"\$(dns_on_nic lookup)\" = 0 ]" ;;
    esac
    run 0 '-' "dns-off $name: disconnect" -- disconnect
    sleep 3; back_clean "dns-off $name"; gap
  done

  # persist: service restart + dvpnd SIGKILL mid-session
  run 0 '-' 'persist: kill switch persist' -- daemon set --kill-switch persist --yes
  run 0 'killSwitch +persist' 'persist reads back' -- daemon settings
  for pn in wireguard:$WG openvpn:$OV; do
    name=${pn%%:*}; node=${pn#*:}
    hold
    run 0 'Connected|connected' "persist $name: connect (per GB)" -- connect "$node" --units 1 --yes || { restore; gap; continue; }
    sleep 4
    check "persist $name: egress = node" bash -c "[ \"\$(curl -s -m 12 https://api.ipify.org)\" = '$NODE_IP' ]"
    hold; sudo launchctl kickstart -k "system/$SVC_LABEL"; sleep 2
    check "persist $name: during the service restart → never the direct IP" bash -c "[ \"\$(curl -s -m 8 https://api.ipify.org)\" != '$DIRECT' ]"
    sleep 15
    run 0 '-' "persist $name: status after restart (recorded)" -- status
    check "persist $name: after restart: pf anchor still blocking" bash -c "sudo pfctl -a dvpnd -s rules | grep -q 'block drop out all'"
    check "persist $name: after restart → never the direct IP" bash -c "[ \"\$(curl -s -m 10 https://api.ipify.org)\" != '$DIRECT' ]"
    hold; sudo pkill -9 -x dvpnd; sleep 2
    check "persist $name: dvpnd SIGKILLed → never the direct IP" bash -c "[ \"\$(curl -s -m 8 https://api.ipify.org)\" != '$DIRECT' ]"
    check "persist $name: launchd brings dvpnd back (ThrottleInterval 60 s)" bash -c "$(declare -f svc_up); CLI=$CLI; svc_up"
    sleep 5
    run 0 '-' "persist $name: status after SIGKILL (recorded)" -- status
    check "persist $name: after SIGKILL + restart → never the direct IP" bash -c "[ \"\$(curl -s -m 10 https://api.ipify.org)\" != '$DIRECT' ]"
    hold
    restore; back_clean "persist $name"; gap
  done

  # kill-on: mode ON + dvpnd SIGKILL
  run 0 '-' 'kill-on: kill switch on' -- daemon set --kill-switch on --yes
  for pn in wireguard:$WG hysteria2:$HY; do
    name=${pn%%:*}; node=${pn#*:}
    hold
    run 0 'Connected|connected' "kill-on $name: connect (per GB)" -- connect "$node" --units 1 --yes || { restore; gap; continue; }
    sleep 4
    hold; sudo pkill -9 -x dvpnd; sleep 2
    check "kill-on $name: dvpnd SIGKILLed → never the direct IP" bash -c "[ \"\$(curl -s -m 8 https://api.ipify.org)\" != '$DIRECT' ]"
    check "kill-on $name: launchd brings dvpnd back" bash -c "$(declare -f svc_up); CLI=$CLI; svc_up"
    sleep 5
    run 0 '-' "kill-on $name: status after SIGKILL (recorded)" -- status
    check "kill-on $name: after restart → never the direct IP while not disconnected" bash -c "[ \"\$(curl -s -m 10 https://api.ipify.org)\" != '$DIRECT' ]"
    hold
    restore; back_clean "kill-on $name"; gap
  done
  run 0 '-' 'kill switch off' -- daemon set --kill-switch off --yes

  # per_hour on every protocol
  for pn in wireguard:$WG amneziawg:$AWG openvpn:$OV hysteria2:$HY v2ray:$V2 xray:$XR; do
    name=${pn%%:*}; node=${pn#*:}
    run 0 'Connected|connected' "per_hour $name: connect" -- connect "$node" --basis per_hour --units 1 --yes || { restore; gap; continue; }
    sleep 4
    case $name in v2ray|xray) via="--socks5-hostname $($CLI proxy status --json 2>/dev/null | grep -oE '127\.0\.0\.1:[0-9]+' | head -1)" ;; *) via='' ;; esac
    check "per_hour $name: egress = node" bash -c "for i in 1 2 3; do [ \"\$(curl -s -m 12 $via https://api.ipify.org)\" = '$NODE_IP' ] && exit 0; sleep 3; done; exit 1"
    run 0 'per_hour|hour' "per_hour $name: status shows the hourly basis" -- status
    run 0 '-' "per_hour $name: disconnect" -- disconnect
    sleep 3; back_clean "per_hour $name"; gap
  done

  # top-up of the live session's channel
  run 0 'Connected|connected' 'topup: connect wireguard (per GB)' -- connect "$WG" --units 1 --yes
  sleep 4
  CH=$($CLI status --json 2>/dev/null | grep -oE '"channel[A-Za-z]*" *: *"[1-9A-HJ-NP-Za-km-z]{32,44}"' | head -1 | grep -oE '[1-9A-HJ-NP-Za-km-z]{32,44}"$' | tr -d '"')
  gap
  if [ -n "$CH" ]; then run 0 '-' "topup: channels fund $CH during the session" -- channels fund "$CH" --tdvpn 1 --yes; else record FAIL 'topup: no channel in status --json' 'status --json' "$($CLI status --json 2>&1 | head -c 400)"; fi
  sleep 5
  check 'topup: session still up, egress = node' bash -c "[ \"\$(curl -s -m 12 https://api.ipify.org)\" = '$NODE_IP' ]"
  run 0 'Connected|connected|wireguard' 'topup: status still connected' -- status
  run 0 '-' 'topup: disconnect' -- disconnect
  sleep 3; back_clean 'topup'
  check 'final: kill switch off, direct egress, nothing left' bash -c "$FN_DEFS; no_leftovers && [ \"\$(egress)\" = '$DIRECT' ]"
  summary; exit $?
fi

# ─── cover ───
if [ "$TIER" = cover ]; then
  ran=$(cat "$OUT"/*.tsv | awk -F '\t' '$1 == "PASS" && $3 != "check" { print $3 }')
  missing=0
  while read -r key; do
    if printf '%s\n' "$ran" | grep -Eq "^$key( |$)"; then echo "ran     $key"; else echo "MISSING $key"; missing=$((missing + 1)); fi
  done < <($CLI help 2>/dev/null | grep -E '^  [a-z]' | sed -E 's/^  //; s/ (<|\[|--|\||…).*//' | awk '{ if ($2 ~ /^[a-z-]+$/) print $1" "$2; else print $1 }' | sort -u)
  echo "missing $missing"
  [ "$missing" = 0 ]
fi
