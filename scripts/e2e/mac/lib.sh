#!/bin/bash
# ─── Shared helpers for the macOS live suites (matrix-steps.sh, edge). Source it; runs IN the guest ───
# Mac twin of #32 scripts/e2e/linux/lib.sh. Every check records
#   PASS|FAIL|INFO <tab> protocol <tab> check <tab> detail      in $TSV, a transcript in $LOG.
# Four oracles per case: network (egress during / direct after, nothing left: pf anchor, utun,
# protocol process, system proxy), money (chain reads through the CLI), message (exit code +
# copy), health (no panic / error lines in dvpnd's log since the case started).
# Each step is a fresh process (the laptop driver runs one step per SSH call), so state that must
# outlive a step is kept in files under ~/matrix.
# Apple's /bin/bash 3.2: no associative arrays, no ${x,,}, guard empty arrays.
export PATH="/Applications/Devnet dVPN.app/Contents/Resources/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
CLI=devnet-dvpn
LIB=/usr/local/lib/devnet-dvpn
LABEL=network.sentinel.devnet-dvpn.dvpnd
DVPND_LOG=/Library/Logs/DevnetDVPN/dvpnd.log
# A run against another node set (e.g. the SOLO node) writes ~/matrix/nodes.env: NODE_IP + NODE_<PROTOCOL>.
[ -f ~/matrix/nodes.env ] && . ~/matrix/nodes.env
NODE_IP=${NODE_IP:-35.238.250.188}
ALL_PROTOCOLS="wireguard amneziawg openvpn hysteria2 v2ray xray"
export DVPN_KEYFILE=${DVPN_KEYFILE:-$HOME/.ddv/test-wallet.json}
export DVPN_DATA_DIR=${DVPN_DATA_DIR:-$HOME/ddv-data}
OUT=~/matrix; mkdir -p "$OUT"
ENV_FILE="$OUT/env"
# svc_back: wait until the CLI reaches dvpnd again after a kill (launchd ThrottleInterval 60 s: a
# second death within a minute of the last start is respawned up to 60 s later, by design)
svc_back() {
  local t0 i; t0=$(date +%s)
  for i in $(seq 1 75); do
    $CLI daemon version >/dev/null 2>&1 && { echo "dvpnd answers $(( $(date +%s) - t0 )) s after the kill"; return 0; }
    sleep 1
  done
  echo "dvpnd still down after 75 s"; return 1
}
# fetch_bytes <n> [curl args]: exactly n bytes as a range of a fixed file. The Cloudflare speed
# endpoint answered 403 above 25 MB and then 429 to the node IP; Hetzner and OVH serve ranges (206).
DL_URL=${DL_URL:-https://ash-speed.hetzner.com/100MB.bin}
fetch_bytes() { local n=$1; shift; curl -s -r "0-$((n - 1))" "$@" "$DL_URL"; }
P=${P:--}

node_of() {
  case $1 in
    wireguard) echo "${NODE_WIREGUARD:-SLVJNn38s5RfqcVW7a7A4hGKqjY7Y1bKkUpG7wrGX5D}" ;;
    amneziawg) echo "${NODE_AMNEZIAWG:-1PwMkSjnyugAZHdHvDsddETzPUAubPkeyWymT7Ercn6}" ;;
    openvpn) echo "${NODE_OPENVPN:-9EQJ7dBwneFUse9yy8Hg56u2wPiGF5qkjAaA1ZAr64nP}" ;;
    hysteria2) echo "${NODE_HYSTERIA2:-E8nefMLBuBzG1CrA4dSDU9mqq6ZNpv69Bt3w9QEtzvPf}" ;;
    v2ray) echo "${NODE_V2RAY:-Di5V9K2Vt5uptJUk7oVVnkDRXt9qWy5HhLbkEJMxEuM2}" ;;
    xray) echo "${NODE_XRAY:-E9RG1iZJjsLfEuLfDYTHM4yXCjyFE21jBbJLFvGoL2FD}" ;;
  esac
}

# ─── Suite state ───
# env_init: once per suite run, while the guest is on its own network (no session, no pf anchor)
env_init() {
  local nic direct s
  # The "before" picture must be the guest's own network: end anything a killed run left live
  # (a session, its system proxy, a held kill switch) first, or every later check compares
  # against our own leftovers.
  $CLI disconnect >/dev/null 2>&1; $CLI proxy off >/dev/null 2>&1
  $CLI daemon restore-network >/dev/null 2>&1; sudo pfctl -a ddvtest -F all >/dev/null 2>&1; sleep 3
  services | while read -r s; do
    networksetup -getsocksfirewallproxy "$s" | grep -q '^Enabled: Yes' && sudo networksetup -setsocksfirewallproxystate "$s" off
    # A test PAC (the cases serve them on 127.0.0.1:8099) left by a killed run made a dirty
    # baseline: every later "proxy back" check failed against it (rig 2 r8 proxy-crash, lan).
    if networksetup -getautoproxyurl "$s" | grep -q '127\.0\.0\.1:8099/'; then
      sudo networksetup -setautoproxystate "$s" off; pac_clear "$s"
    fi
  done
  nic=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
  direct=$(curl -4 -s -m 12 https://api.ipify.org)
  {
    echo "NIC=$nic"; echo "DIRECT=$direct"
  } > "$ENV_FILE"
  ifconfig -l | tr ' ' '\n' | grep '^utun' > "$OUT/utun-base.txt"
  proxy_snapshot > "$OUT/proxy-base.txt"
  scutil --dns | awk '/nameserver\[/{print $3}' | sort -u > "$OUT/dns-base.txt"
  echo "NIC=$nic DIRECT=$direct utun-base=$(tr '\n' ' ' < "$OUT/utun-base.txt")"
}
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

case_init() { # <case>: open the result files (kept across the case's steps)
  CASE=$1; TSV="$OUT/$CASE.tsv"; LOG="$OUT/$CASE.log"
}
case_reset() { : > "$TSV"; : > "$LOG"; effect_before; }

# ─── Effect lines (~/memory/state/FINAL-PASS-EFFECT-SPEC.md): rc=0 alone never counts ───
# Measured state printed to stdout (so the cell log carries it) and the case log: the product
# installed + the wallet before the case (case_reset), the same after it plus the egress (summary),
# and the egress during a session (egress_is_node). fd 7 = the step's own stdout, also from inside
# a check's $(…) capture.
{ exec 7>&1; } 2>/dev/null
fx_line() { printf '%s\n' "$*" | tee -a "${LOG:-/dev/null}" >&7; }
money_now() { # "<wallet tDVPN> <refundable>" from status --json, or nothing
  $CLI status --json 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const w=JSON.parse(s).wallet||{};const f=u=>(Number(u||0)/1e6).toFixed(6);if(w.ownerTdvpn!==undefined)console.log(f(w.ownerTdvpn)+" "+f(w.userBalance))}catch(e){console.error("money_now: "+e.message)}})'
}
product_now() { # "app <version> dvpnd <version>"
  local a d
  a=$(defaults read "/Applications/Devnet dVPN.app/Contents/Info" CFBundleShortVersionString 2>/dev/null)
  d=$($CLI daemon version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+[0-9A-Za-z.-]*' | head -1)
  echo "app ${a:-absent} dvpnd ${d:-unreachable}"
}
settings_flat() { # "<key> <value>" per service setting, read back from the daemon (not the UI)
  $CLI daemon settings --json 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const walk=(o,p)=>{for(const[k,v]of Object.entries(o)){const n=p?p+"."+k:k;if(v&&typeof v==="object"&&!Array.isArray(v))walk(v,n);else console.log(n+" "+String(Array.isArray(v)?(v.join(",")||"none"):v).replace(/\s+/g,"_"))}};walk(JSON.parse(s),"")}catch(e){console.error("settings_flat: "+e.message)}})'
}
settings_effect() { # one "EFFECT setting <key> <before> -> after <after>" per key changed since the case start
  local now="$OUT/$CASE.settings1" k v old
  settings_flat > "$now"
  while read -r k v; do
    old=$(awk -v k="$k" '$1==k{print $2; exit}' "$OUT/$CASE.settings0" 2>/dev/null)
    [ "$old" != "$v" ] && fx_line "EFFECT setting $k ${old:-unset} -> after $v (read back: daemon settings --json)"
  done < "$now"
}
effect_before() {
  local m; m=$(money_now)
  echo "$m" > "$OUT/$CASE.money0"; product_now > "$OUT/$CASE.product0"; settings_flat > "$OUT/$CASE.settings0"
  fx_line "product installed before the case: $(cat "$OUT/$CASE.product0")"
  fx_line "balance before the case: tDVPN ${m%% *} refundable ${m##* }"
}
effect_after() {
  local e m0 m1
  fx_line "product installed after the case: $(product_now) (before: $(cat "$OUT/$CASE.product0" 2>/dev/null))"
  m0=$(cat "$OUT/$CASE.money0" 2>/dev/null); m1=$(money_now)
  fx_line "balance tDVPN ${m0%% *} -> ${m1%% *}, refundable ${m0##* } -> ${m1##* } (before -> after the case)"
  e=$(egress)
  if [ "$e" = "${DIRECT:-}" ]; then fx_line "egress $e after the case = direct"
  else fx_line "egress ${e:-none} after the case, NOT the direct ${DIRECT:-?}"; fi
}

# ─── Recording ───
note() { printf '%s\n' "$*" | tee -a "$LOG"; }
record() { # PASS|FAIL check detail
  printf '%s\t%s\t%s\t%s\n' "$1" "$P" "$2" "$(printf '%s' "${3:-}" | tr '\n\t' '  ' | cut -c1-300)" >> "$TSV"
  if [ "$1" = PASS ]; then note "ok   [$P] $2"; else note "FAIL [$P] $2 :: $(printf '%s' "${3:-}" | head -3 | tr '\n' ' ' | cut -c1-240)"; fi
}
info() { printf 'INFO\t%s\t%s\t%s\n' "$P" "$1" "$(printf '%s' "${2:-}" | tr '\n\t' '  ' | cut -c1-300)" >> "$TSV"; note "info [$P] $1: $(printf '%s' "${2:-}" | head -2 | tr '\n' ' ' | cut -c1-200)"; }
# run <expected-exit> <regex|-> <check> -- <cli args…>   (LAST = output)
LAST=''
run() {
  local want=$1 re=$2 desc=$3; shift 4
  local out code
  out=$($CLI "$@" 2>&1); code=$?
  out=$(printf '%s\n' "$out" | grep -v '^\[rpc\]' | sed -E '/shown once:/{n;s/.*/<24 words redacted>/;}')
  LAST=$out
  printf '\n### [%s] %s\n$ devnet-dvpn %s\n%s\n(exit %s)\n' "$P" "$desc" "$*" "$out" "$code" >> "$LOG"
  if [ "$code" != "$want" ]; then record FAIL "$desc (exit $code, want $want)" "$out"; return 1; fi
  if [ "$re" != - ] && ! printf '%s' "$out" | grep -Eq -- "$re"; then record FAIL "$desc: no /$re/" "$out"; return 1; fi
  if printf '%s' "$out" | grep -Eq 'api-key=[A-Za-z0-9]'; then record FAIL "$desc: printed an RPC API key" '<secret>'; return 1; fi
  record PASS "$desc" "$(printf '%s' "$out" | head -2)"
}
check() { # <check> <command…>
  local desc=$1; shift
  local out; out=$("$@" 2>&1); local code=$?
  printf '\n### [%s] %s\n$ %s\n%s\n(exit %s)\n' "$P" "$desc" "$*" "$out" "$code" >> "$LOG"
  if [ $code = 0 ]; then record PASS "$desc" "$out"; else record FAIL "$desc" "$out"; fi
  return $code
}

# ─── Network oracle ───
gap() { sleep 7; }
hold() { sudo touch /var/run/ddv-deadman.hold; }
egress() { curl -4 -s -m 12 https://api.ipify.org; }
socks() { $CLI proxy status --json 2>/dev/null | grep -oE '127\.0\.0\.1:[0-9]+' | head -1; }
whole_device() { $CLI daemon settings --json 2>/dev/null | grep -qE '"wholeDevice"\s*:\s*true'; }
# V2Ray/Xray without whole-device = a local SOCKS proxy (+ the system proxy); everything else = a tunnel
is_proxy() { case $1 in v2ray|xray) whole_device && return 1; return 0 ;; *) return 1 ;; esac; }
egress_p() { if is_proxy "$1"; then curl -4 -s -m 12 --socks5-hostname "$(socks)" https://api.ipify.org; else egress; fi; }
egress_is_node() {
  local i e
  for i in 1 2 3; do
    e=$(egress_p "$1"); [ "$e" = "$NODE_IP" ] && { fx_line "egress $e = the node during the session [$1]"; return 0; }
    sleep 3
  done
  fx_line "egress ${e:-none} during the session [$1], NOT the node $NODE_IP"; echo "egress $e"; return 1
}
never_direct() { check "$1 → never the direct IP" bash -c "[ \"\$(curl -4 -s -m 10 https://api.ipify.org)\" != '$DIRECT' ]"; }
new_utuns() { ifconfig -l | tr ' ' '\n' | grep '^utun' | grep -vxF -f "$OUT/utun-base.txt"; }
tunnel_link() { new_utuns | head -1; }
our_procs() { # protocol processes started from our root-owned copies, openvpn on a dvpnd config
  ps -axww -o pid=,comm= | awk -v lib="$LIB/" 'index($2, lib) == 1 && $2 != lib "dvpnd" { print $1 }'
  ps -axww -o pid=,comm=,args= | awk '$2 ~ /\/openvpn$/ && /\/var\/db\/dvpnd\// { print $1 }'
}
proto_pids() { # <protocol>: the running process(es) of that protocol (ours only)
  local name=$1 dir u
  case $1 in
    # WireGuard/AmneziaWG run the Homebrew userspace daemon (not our copies), started as
    # "wireguard-go utun": ours is the process holding the control socket of the utun our name file names
    wireguard|amneziawg)
      if [ "$1" = wireguard ]; then dir=/var/run/wireguard u=dvpn-wg-client; else dir=/var/run/amneziawg u=dvpn-awg-client; fi
      u=$(sudo cat "$dir/$u.name" 2>/dev/null) && [ -n "$u" ] && sudo lsof -t "$dir/$u.sock" 2>/dev/null | sort -u
      return 0 ;;
  esac
  for pid in $(our_procs); do ps -o comm= -p "$pid" | grep -q "/$name\$" && echo "$pid"; done
}
services() { networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*'; }
proxy_snapshot() {
  local s
  services | while read -r s; do
    printf '%s|socks:%s|web:%s|secure:%s|pac:%s\n' "$s" \
      "$(networksetup -getsocksfirewallproxy "$s" | tr '\n' ' ')" \
      "$(networksetup -getwebproxy "$s" | head -1)" \
      "$(networksetup -getsecurewebproxy "$s" | head -1)" \
      "$(networksetup -getautoproxyurl "$s" | tr '\n' ' ')"
  done
}
anchor_rules() { sudo pfctl -a dvpnd -s rules 2>/dev/null | grep -c .; }
anchor_blocks() { sudo pfctl -a dvpnd -s rules 2>/dev/null | head -1 | grep -q '^block drop out all'; }
no_leftovers() {
  local r l p x
  r=$(anchor_rules); l=$(new_utuns | grep -c .); p=$(our_procs | grep -c .)
  x=same; proxy_snapshot | diff -q - "$OUT/proxy-base.txt" >/dev/null || x=changed
  echo "pf=$r utun=$l procs=$p proxy=$x egress=$(egress)"
  [ "$r" = 0 ] && [ "$l" = 0 ] && [ "$p" = 0 ] && [ "$x" = same ]
}
dns_back() { # the system resolvers are the ones from before the session
  scutil --dns | awk '/nameserver\[/{print $3}' | sort -u | diff - "$OUT/dns-base.txt"
}
restore() { $CLI disconnect >/dev/null 2>&1; sleep 2; $CLI daemon restore-network >/dev/null 2>&1; sleep 3; }
back_clean() {
  check "$1: after: nothing left (pf, utun, process, proxy), DNS back, direct egress" bash -c \
    "$(declare -f no_leftovers egress new_utuns our_procs anchor_rules services proxy_snapshot dns_back); LIB='$LIB'; OUT='$OUT'; for i in 1 2 3 4; do no_leftovers && dns_back && [ \"\$(egress)\" = '$DIRECT' ] && exit 0; sleep 5; done; no_leftovers; dns_back; exit 1"
}
# try_run <desc> -- <cli args…>: logs like run, records nothing; exit code returned, output in LAST
# (for steps where a refusal is as valid as success, e.g. connecting through a broken rival VPN).
try_run() {
  local desc=$1 out code; shift 2
  out=$($CLI "$@" 2>&1); code=$?
  LAST=$(printf '%s\n' "$out" | grep -v '^\[rpc\]')
  printf '\n### [%s] %s\n$ devnet-dvpn %s\n%s\n(exit %s)\n' "$P" "$desc" "$*" "$LAST" "$code" >> "$LOG"
  return $code
}
connect_p() { # <protocol> [extra connect args…]: per GB unless args say otherwise
  local p=$1; shift
  hold
  run 0 'Connected|connected' "connect${*:+ $*}" -- connect "$(node_of "$p")" --units 1 --yes "$@"
}
svc_running() { sudo launchctl print "system/$LABEL" 2>/dev/null | grep -q 'state = running'; }
# live_again: reconnect when an earlier step ended the session, so the next step tests a live one
live_again() {
  svc_back >/dev/null || true
  $CLI status 2>/dev/null | grep -q '^Session *Not connected' || return 0
  connect_p "$P" || return 1
  sleep 4; check 'reconnected for the next step: egress = node' egress_is_node "$P"
}

# DNS leak probe: the number of the probe names seen in clear on the physical interface
dns_on_nic() { # <resolver command…> (gets the name as its last argument)
  local f n names='' bare=0 tp
  f=$(mktemp)
  sudo tcpdump -ni "$NIC" -l 'udp port 53 or tcp port 53' > "$f" 2>/dev/null & tp=$!
  sleep 2
  for i in 1 2 3; do n="ddv-leak-$RANDOM$RANDOM.example.com"; names="$names $n"; "$@" "$n" >/dev/null 2>&1; done
  sleep 3; sudo kill "$tp" 2>/dev/null; wait "$tp" 2>/dev/null
  for n in $names; do bare=$((bare + $(grep -F "$n" "$f" | grep -c .))); done
  echo "$bare"; rm -f "$f"
}
sys_lookup() { dscacheutil -q host -a name "$1"; } # the system resolver path apps use

# ─── Health oracle: dvpnd log lines since the case mark ───
# wc runs as root: since setup uses Umask 077 the log is root-only (600), and "sudo wc < log" opened it as the user (empty mark = whole log read).
mark() { sudo wc -l "$DVPND_LOG" 2>/dev/null | awk '{print $1}' > "$OUT/$CASE.$P.mark"; }
# A step that restarts dvpnd mid-session on purpose (a live daemon set) calls restarted_live: the
# V2Ray/Xray final-usage voucher is then lost at shutdown (#31 UPSTREAM-GAPS #77, low: the node is
# underpaid, never the user). Only those two messages are allowed, only after such a restart.
restarted_live() { : > "$OUT/$CASE.$P.restart"; }
# dvpnd logs JSON with "error" BEFORE "message", so both orders are matched; warn level only (an
# error-level line is never allowed). The service stop cancels the in-flight voucher on every
# protocol (close case), not only the V2Ray/Xray final one.
GAP77='"level":"warn".*(context canceled|Canceled).*issuing voucher failed|"level":"warn".*issuing voucher failed.*(Canceled|context canceled)|"level":"warn".*reading peer stats.*(DeadlineExceeded|deadline exceeded).*issuing voucher failed|sampling final session usage failed'
# A step that makes the node unreachable on purpose (node blocked, link down, VM paused, bad path)
# calls faulted_live: vouchers sent while it is cut time out. Only timeouts/unreachable are allowed.
faulted_live() { : > "$OUT/$CASE.$P.fault"; }
NETFAULT='"level":"warn".*(deadline exceeded|Client.Timeout|i/o timeout|connection refused|connection reset|network is unreachable|no route to host|EOF|no admitted address answered).*(issuing voucher failed|closing remote session failed)'
# A step that kills the protocol process on purpose calls proto_killed: until dvpnd ends the
# session, each voucher fails reading that protocol's stats (openvpn "process exited", Hysteria2
# "peer not found", V2Ray/Xray stats API "Unavailable"). Only those stats failures are allowed.
proto_killed() { : > "$OUT/$CASE.$P.protokill"; }
PROTOKILL='"level":"warn".*reading peer stats.*issuing voucher failed'
health() { # <check> [extra allowed regex]
  local from bad allow="${2:-}"
  [ -f "$OUT/$CASE.$P.restart" ] && allow="${allow:+$allow|}$GAP77"
  [ -f "$OUT/$CASE.$P.fault" ] && allow="${allow:+$allow|}$NETFAULT"
  [ -f "$OUT/$CASE.$P.protokill" ] && allow="${allow:+$allow|}$PROTOKILL"
  from=$(cat "$OUT/$CASE.$P.mark" 2>/dev/null); [ -n "$from" ] || { record FAIL "$1: health" "no log mark for this case (cannot tell new lines from old)"; return; }
  bad=$(sudo tail -n +"$((from + 1))" "$DVPND_LOG" 2>/dev/null \
    | grep -E 'panic|"level":"(error|fatal)"|level=(error|fatal)|closing remote session failed|issuing voucher failed|sampling final session usage failed' \
    | grep -Ev "${allow:-^$}" | head -5)
  rm -f "$OUT/$CASE.$P.restart" "$OUT/$CASE.$P.fault" "$OUT/$CASE.$P.protokill"
  if [ -z "$bad" ]; then record PASS "$1: health (no panic/error/voucher/close failures in dvpnd)" ''; else record FAIL "$1: health" "$bad"; fi
}

summary() {
  local p f
  effect_after
  p=$(awk -F'\t' '$1=="PASS"' "$TSV" | grep -c .); f=$(awk -F'\t' '$1=="FAIL"' "$TSV" | grep -c .)
  note ''; note "$CASE: passed $p  failed $f"; echo DONE >> "$LOG"
  [ "$f" = 0 ]
}

# ─── Split-dyn helpers: the macOS system proxy (SOCKS + PAC per network service) ───
# sys_socks: host:port the primary service's SOCKS proxy points at while enabled, else ""
sys_socks() {
  networksetup -getsocksfirewallproxy "$(services | head -1)" |
    awk -F': ' '/^Enabled:/{e=$2} /^Server:/{h=$2} /^Port:/{p=$2} END{if (e == "Yes") print h ":" p}'
}
listening() { [ -n "$1" ] && sudo lsof -nP -iTCP:"${1##*:}" -sTCP:LISTEN >/dev/null 2>&1; }
other_proxy() { if [ "$1" = v2ray ]; then echo xray; else echo v2ray; fi; }
# A system-proxy app: nscurl = Apple's URL stack (NSURLSession), which reads the system proxy the
# way Safari and most Mac apps do. Headless Chrome crashed on the VM display in every try of the
# proxy cases (exit 138/139, rig 3 r6); app_ip (Firefox) is the probe where a real .app is the point.
sys_app_ip() { perl -e 'alarm 30; exec @ARGV' /usr/bin/nscurl https://api.ipify.org 2>/dev/null | grep -oE '^[0-9]+(\.[0-9]+){3}$' | head -1; }
sys_app_is_node() { local ip; ip=$(sys_app_ip); [ "$ip" = "$NODE_IP" ] || { echo "nscurl sees ${ip:-nothing}"; return 1; }; }
sys_app_online() { local ip; ip=$(sys_app_ip); [ -n "$ip" ] || { echo 'nscurl reached nothing'; return 1; }; echo "nscurl sees $ip"; }
proxy_is() { proxy_snapshot | diff - "$1"; } # <snapshot file>: exit 0 when the proxy is exactly that
# proxy_save / proxy_load: each service's SOCKS + PAC values and states, put back as they were
proxy_save() {
  local s
  services | while read -r s; do
    printf '%s|%s|%s|%s|%s|%s\n' "$s" \
      "$(networksetup -getsocksfirewallproxy "$s" | awk -F': ' '/^Server:/{print $2}')" \
      "$(networksetup -getsocksfirewallproxy "$s" | awk -F': ' '/^Port:/{print $2}')" \
      "$(networksetup -getsocksfirewallproxy "$s" | awk -F': ' '/^Enabled:/{print $2}')" \
      "$(networksetup -getautoproxyurl "$s" | awk -F': ' '/^URL:/{print $2}')" \
      "$(networksetup -getautoproxyurl "$s" | awk -F': ' '/^Enabled:/{print $2}')"
  done > "$1"
}
proxy_load() {
  local s h pt se u ue
  while IFS='|' read -r s h pt se u ue; do
    sudo networksetup -setsocksfirewallproxy "$s" "${h:-}" "${pt:-0}" >/dev/null 2>&1
    [ "$se" = Yes ] || sudo networksetup -setsocksfirewallproxystate "$s" off
    if [ -n "$u" ] && [ "$u" != '(null)' ]; then sudo networksetup -setautoproxyurl "$s" "$u"; else pac_clear "$s"; fi
    [ "$ue" = Yes ] || sudo networksetup -setautoproxystate "$s" off
  done < "$1"
}
# pac_clear <service>: networksetup cannot empty a PAC URL ("parameters were not valid"); scutil --prefs can
pac_clear() {
  local id
  for id in $(printf 'list /NetworkServices
' | sudo scutil --prefs | awk -F/ '/path/ && NF == 3 {print $3}'); do
    printf 'get /NetworkServices/%s
d.show
' "$id" | sudo scutil --prefs | grep -qxF "  UserDefinedName : $1" || continue
    printf 'get /NetworkServices/%s/Proxies
d.remove ProxyAutoConfigURLString
set /NetworkServices/%s/Proxies
commit
apply
quit
' "$id" "$id" | sudo scutil --prefs >/dev/null
  done
}
set_user_proxy() { # <host> <port> [pac url]: the user's own proxy, enabled, on every service
  local s
  services | while read -r s; do
    sudo networksetup -setsocksfirewallproxy "$s" "$1" "$2"
    if [ -n "${3:-}" ]; then sudo networksetup -setautoproxyurl "$s" "$3"; fi
  done
}
# sdyn_begin / sdyn_end: proxy mode for the case; the end puts the user's proxy back and checks it
sdyn_begin() {
  proxy_save "$OUT/sdyn-orig.save"; proxy_snapshot > "$OUT/sdyn-user.txt"
  run 0 '-' 'proxy mode (whole device off)' -- daemon set --whole-device false --yes
}
sdyn_end() { # [snapshot the user had at the end, default the one from the start]
  local want=${1:-$OUT/sdyn-user.txt}
  run 0 '-' 'proxy off' -- proxy off
  run 0 '-' 'disconnect' -- disconnect; sleep 3
  check "$CASE end: the user's proxy exactly as they left it" proxy_is "$want"
  proxy_load "$OUT/sdyn-orig.save"
  check "$CASE end: test proxy settings removed (as before the case)" proxy_is "$OUT/sdyn-user.txt"
  run 0 '-' 'whole device back on' -- daemon set --whole-device true --yes
}

# ─── Money / message oracles shared by the edge cases ───
tdvpn_now() { $CLI wallet --json 2>/dev/null | grep -oE '"(tdvpn|ownerTdvpn)"\s*:\s*"?[0-9.]+' | head -1 | grep -oE '[0-9.]+$'; }
plain_copy() { # <text>: a person can read it — no stack, no internals, no catch-all
  ! printf '%s' "$1" | grep -Eqi 'something went wrong|undefined|\[object |^\s+at .*\.(c?js|ts):|TypeError|ReferenceError|grpc|rpc error: code'
}

# The IP a real app (Firefox, headless, fresh profile) sees: split-by-app needs a bundle executable.
# Its page fetches ipify itself and reports the answer (or its network error) to a one-shot listener
# on loopback. Firefox, not Chrome: headless Chrome 156 segfaults in this VM (EXC_BAD_ACCESS in
# -[NSWindow _finishClosingWindow], CVDisplayLink errors), 0/6 with this probe vs Firefox 4/4 (rig 3).
PROBE_APP="${PROBE_APP:-/Applications/Firefox.app/Contents/MacOS/firefox}"
APP_PROBE_PY='
import http.server, socketserver, sys, urllib.parse
PAGE = b"""<script>fetch("https://api.ipify.org",{cache:"no-store"}).then(r=>r.text())
.then(t=>fetch("/r?ip="+encodeURIComponent(t.trim()))).catch(e=>fetch("/r?err="+encodeURIComponent(String(e))))</script>"""
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
        if u.path == "/r":
            q = urllib.parse.parse_qs(u.query)
            print(("ip " + q["ip"][0]) if "ip" in q else ("err " + q.get("err", ["?"])[0]), flush=True)
            sys.exit(0)
        self.wfile.write(PAGE)
s = socketserver.TCPServer(("127.0.0.1", 0), H); s.timeout = 50
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.handle_request(); s.handle_request(); s.handle_request()
'
app_ip() {
  # An empty answer leaves its evidence in $OUT/app-probe-fail.log. An app that died before
  # reporting says nothing about the network, so it is retried (3 tries); a reported network error
  # is never retried.
  local d t0 ip res cpid spid try=0 i
  while :; do
    try=$((try + 1)); d=$(mktemp -d); t0=$(date +%s); res=''
    python3 -c "$APP_PROBE_PY" "$d.port" > "$d.res" 2>/dev/null & spid=$!
    for i in $(seq 1 50); do [ -s "$d.port" ] && break; sleep 0.1; done
    "$PROBE_APP" --headless --no-remote --profile "$d" "http://127.0.0.1:$(cat "$d.port" 2>/dev/null)/" \
      > /dev/null 2> "$d.err" & cpid=$!
    for i in $(seq 1 50); do kill -0 "$spid" 2>/dev/null || break; sleep 1; done
    kill "$spid" 2>/dev/null; kill "$cpid" 2>/dev/null; sleep 1; kill -9 "$cpid" 2>/dev/null
    pkill -f -- "[-]-profile $d" 2>/dev/null
    wait "$spid" "$cpid" 2>/dev/null
    res=$(head -1 "$d.res" 2>/dev/null)
    ip=$(printf '%s' "$res" | sed -n 's/^ip //p' | grep -oE '^[0-9]+(\.[0-9]+){3}$')
    if [ -z "$ip" ]; then
      { printf '%s [%s] %s: empty after %s s, report "%s", try %s\n' "$(date -u +%FT%TZ)" "${P:-}" "${CASE:-}" "$(( $(date +%s) - t0 ))" "$res" "$try"
        grep -E 'ERROR|net::' "$d.err" | tail -5; } >> "${OUT:-/tmp}/app-probe-fail.log"
    fi
    rm -rf "$d" "$d.port" "$d.res" "$d.err"
    if [ -n "$ip" ] || [ "${res%% *}" = err ] || [ "$try" -ge 3 ]; then break; fi
  done
  printf '%s\n' "$ip"
}
