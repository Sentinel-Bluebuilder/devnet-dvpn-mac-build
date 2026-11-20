#!/bin/bash
# ─── Edge: DNS search-suffix leak (Q0333 Mac twin): a search domain on the uplink must not leak ───
#   bash scripts/e2e/mac/dns-suffix-leak.sh [protocols…]   (runs IN the guest; default all six, whole device)
# The uplink service gets a search domain. During a session, names that fail inside the tunnel
# (a single label, so the resolver appends the suffix, and a .invalid name) are looked up through the
# system resolver while tcpdump watches the uplink: no DNS packet (port 53) may leave it except to the
# node. A positive control before connecting proves the capture sees the suffixed query. The user's
# search domains are put back exactly as they were.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
case_init dns-suffix-leak; case_reset
P=-
env_init >/dev/null
. "$ENV_FILE"
# health reads only dvpnd log lines after this mark (same as soak.sh)
sudo wc -l "$DVPND_LOG" 2>/dev/null | awk '{print $1}' > "$OUT/dns-suffix-leak.-.mark"
PROTOS=${*:-$ALL_PROTOCOLS}
SUFFIX=ddvleak-test.example
SVC=$(networksetup -listnetworkserviceorder | awk -v n="$NIC" -F'Device: ' '/^\([0-9]+\)/{s=$0; sub(/^\([0-9]+\) /, "", s)} index($0, "Device: " n ")"){print s; exit}')
[ -n "$SVC" ] || SVC=$(services | head -1)
ORIG=$(networksetup -getsearchdomains "$SVC" | grep -v "aren't any" | tr '\n' ' ')
restore() {
  # shellcheck disable=SC2086 # one argument per domain
  if [ -n "$ORIG" ]; then sudo networksetup -setsearchdomains "$SVC" $ORIG; else sudo networksetup -setsearchdomains "$SVC" Empty; fi
}
trap 'restore' EXIT
info 'uplink' "nic $NIC service '$SVC' search domains before: ${ORIG:-none}"

CAP="$OUT/dns-suffix-cap.txt"
cap_start() { # <filter>
  : > "$CAP"; sudo tcpdump -i "$NIC" -n -l "$1" > "$CAP" 2>/dev/null & CAP_PID=$!; sleep 2
}
cap_stop() { sleep 2; sudo kill "$CAP_PID" 2>/dev/null; wait "$CAP_PID" 2>/dev/null; }
lookups() { # names that fail in the tunnel, through the system resolver (mDNSResponder applies the search list)
  local r; r=$RANDOM$RANDOM
  dscacheutil -q host -a name "ddvleak$r" >/dev/null 2>&1
  dscacheutil -q host -a name "ddvleak$r.invalid" >/dev/null 2>&1
  curl -s -m 5 "http://ddvleak$r/" >/dev/null 2>&1
  echo "ddvleak$r"
}

sudo networksetup -setsearchdomains "$SVC" "$SUFFIX"
check "search domain $SUFFIX set on '$SVC'" bash -c "networksetup -getsearchdomains '$SVC' | grep -qx '$SUFFIX'"
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder 2>/dev/null

# positive control: with no session the suffixed query leaves the uplink and the capture sees it
cap_start 'port 53'
name=$(lookups)
cap_stop
check "control: capture sees the suffixed query on $NIC with no session" grep -q "$name.$SUFFIX" "$CAP"
info 'control capture' "$(grep -c . "$CAP") DNS packets on $NIC"

run 0 '-' 'whole device on, kill switch off, LAN on' -- daemon set --whole-device true --kill-switch off --allow-lan true --yes
for p in $PROTOS; do
  P=$p
  connect_p "$p" || { run 0 '-' 'disconnect' -- disconnect; continue; }
  check 'egress = the node' egress_is_node "$p"
  sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder 2>/dev/null
  cap_start "port 53 and not host $NODE_IP"
  name=$(lookups); lookups >/dev/null
  cap_stop
  n=$(grep -c . "$CAP")
  fx_line "dns: $n DNS packets left $NIC outside the tunnel during the session [$p] (queried $name, suffix $SUFFIX)"
  check "no DNS packet leaves $NIC outside the tunnel (suffix $SUFFIX)" bash -c "! grep -q . '$CAP' || { head -5 '$CAP'; exit 1; }"
  run 0 '-' 'disconnect' -- disconnect; sleep 3
  check 'nothing left, own IP back' bash -c "$(declare -f no_leftovers egress new_utuns our_procs anchor_rules services proxy_snapshot); LIB='$LIB'; OUT='$OUT'; for i in 1 2 3 4; do no_leftovers && [ \"\$(egress)\" = '$DIRECT' ] && exit 0; sleep 5; done; no_leftovers; exit 1"
  sleep 7
done

P=-
restore; trap - EXIT
check "search domains on '$SVC' back as before (${ORIG:-none})" bash -c "[ \"\$(networksetup -getsearchdomains '$SVC' | grep -v \"aren't any\" | tr '\n' ' ')\" = '$ORIG' ]"
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder 2>/dev/null
rm -f "$CAP"
CASE=dns-suffix-leak; health dns-suffix-leak
summary
