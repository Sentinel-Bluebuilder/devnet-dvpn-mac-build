#!/bin/bash
# ─── Fault injection for the macOS guest, run ON ddv-mac-host-1 (installed as /usr/local/sbin/ddv-faultctl) ───
# The guest reaches the internet through QEMU user networking, so its packets leave from the QEMU
# process here: an iptables drop on this host is "the path to the server is lost" for the guest,
# without touching the guest's pf (dvpnd insists its anchor is the first pf rule).
# Every fault is TIMED and undoes itself, so a lost driver never leaves the guest cut off.
# The laptop driver (matrix.sh) calls it: ssh ddv-mac-host sudo -n /usr/local/sbin/ddv-faultctl …
# The guest holds no credential for this host.
# Usage:
#   block   <ipv4> <seconds>     drop everything to <ipv4> (TCP + UDP) for <seconds>
#   udp     <seconds>            drop all UDP leaving the guest except DNS to the QEMU resolver
#   bigudp  <ipv4> <seconds>     a 1280-byte path to <ipv4>: UDP packets over 1280 B are dropped both ways, no ICMP
#                                (a path-MTU black hole: the tunnel handshakes, full-size packets vanish; Q0357)
#   tcp443  <seconds>            only TCP 443 (and DNS) leaves the guest
#   offline <seconds>            the guest has no internet at all (its SSH via host loopback stays up)
#   link    <seconds>            NIC unplugged (QMP set_link off), then back on
#   pause   <seconds>            the whole VM stopped (sleep), then resumed
#   netem   <loss%> <delay-ms> <rate-kbit|0> <seconds>
#                                loss / latency (+20 % jitter) / bandwidth on the guest's outbound
#                                packets only (iptables owner mark → tc on the uplink); 0 = no cap
#   keys    <key> [key …]        press keys on the guest's virtual keyboard (HMP sendkey, e.g. meta_l-shift-g,
#                                slash, ret): answers an OS dialog without macOS Accessibility (SIP keeps TCC closed)
#   clear                        remove every fault now
#   status                       list active faults
set -u
CHAIN=DDVFAULT
CHAIN_IN=DDVFAULTIN
QEMU_USER=${QEMU_USER:-ubuntu}
VMCTL=/home/$QEMU_USER/vmctl.py
die() { echo "ddv-faultctl: $*" >&2; exit 2; }
secs() { [[ "$1" =~ ^[0-9]{1,3}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 600 ] || die "seconds must be 1..600"; }
ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "not an IPv4 address: $1"; }
# QEMU's sockets belong to its user: match on that owner so only the guest's traffic is cut
owner() { echo "-m owner --uid-owner $(id -u "$QEMU_USER")"; }
ensure_chain() {
  iptables -N "$CHAIN" 2>/dev/null
  iptables -C OUTPUT -j "$CHAIN" 2>/dev/null || iptables -I OUTPUT 1 -j "$CHAIN"
}
ensure_chain_in() { # replies reach QEMU's sockets through INPUT (no owner there: match the server address)
  iptables -N "$CHAIN_IN" 2>/dev/null
  iptables -C INPUT -j "$CHAIN_IN" 2>/dev/null || iptables -I INPUT 1 -j "$CHAIN_IN"
}
later() { # <seconds> <command…>: run after a delay, detached from this SSH session
  local s=$1; shift
  # tagged so clear can cancel it: a stale timer must not undo the NEXT fault
  nohup setsid bash -c "sleep $s; $*" ddv-fault-timer >/dev/null 2>&1 < /dev/null &
}
vm() { sudo -u "$QEMU_USER" python3 "$VMCTL" hmp "$@"; }
log() { logger -t ddv-faultctl "$*"; echo "$*"; }
uplink() { ip route show default | awk '{print $5; exit}'; }

case "${1:-}" in
  block)
    ipv4 "${2:-}"; secs "${3:-}"; ensure_chain
    rule="-d $2 $(owner) -m comment --comment ddv-block -j DROP"
    iptables -A "$CHAIN" $rule
    later "$3" "iptables -D $CHAIN $rule"
    log "block $2 for $3 s" ;;
  udp)
    secs "${2:-}"; ensure_chain
    # QEMU answers DNS itself (10.0.2.3 → this host's resolver), not from the guest's sockets here
    rule="-p udp ! --dport 53 $(owner) -m comment --comment ddv-udp -j DROP"
    iptables -A "$CHAIN" $rule
    later "$2" "iptables -D $CHAIN $rule"
    log "udp blocked for $2 s" ;;
  bigudp)
    ipv4 "${2:-}"; secs "${3:-}"; ensure_chain; ensure_chain_in
    r1="-d $2 -p udp -m length --length 1281:65535 $(owner) -m comment --comment ddv-bigudp -j DROP"
    r2="-s $2 -p udp -m length --length 1281:65535 -m comment --comment ddv-bigudp -j DROP"
    iptables -A "$CHAIN" $r1; iptables -A "$CHAIN_IN" $r2
    later "$3" "iptables -D $CHAIN $r1; iptables -D $CHAIN_IN $r2"
    log "udp over 1280 B to/from $2 dropped for $3 s" ;;
  tcp443)
    secs "${2:-}"; ensure_chain
    # loopback stays open: QEMU answers the SSH port forward (host 127.0.0.1:2222) from its own
    # sockets, and a drop there cut the driver off (rig 1 r9: the run step never ran, 13 false passes)
    r1="-p udp ! --dport 53 ! -d 127.0.0.0/8 $(owner) -m comment --comment ddv-443 -j DROP"
    r2="-p tcp ! --dport 443 ! -d 127.0.0.0/8 $(owner) -m comment --comment ddv-443 -j DROP"
    iptables -A "$CHAIN" $r1; iptables -A "$CHAIN" $r2
    later "$2" "iptables -D $CHAIN $r1; iptables -D $CHAIN $r2"
    log "only tcp 443 for $2 s" ;;
  offline)
    secs "${2:-}"; ensure_chain
    rule="! -d 127.0.0.0/8 $(owner) -m comment --comment ddv-offline -j DROP"
    iptables -A "$CHAIN" $rule
    later "$2" "iptables -D $CHAIN $rule"
    log "offline for $2 s" ;;
  link)
    secs "${2:-}"
    vm set_link net0 off
    later "$2" "sudo -u $QEMU_USER python3 $VMCTL hmp set_link net0 on"
    log "link off for $2 s" ;;
  pause)
    secs "${2:-}"
    later "$2" "sudo -u $QEMU_USER python3 $VMCTL hmp cont"
    vm stop
    log "vm paused for $2 s" ;;
  netem)
    [[ "${2:-}" =~ ^[0-9]{1,2}$ ]] || die "loss must be 0..99 %"
    [[ "${3:-}" =~ ^[0-9]{1,4}$ ]] || die "delay must be 0..9999 ms"
    [[ "${4:-}" =~ ^[0-9]{1,7}$ ]] || die "rate must be kbit (0 = no cap)"
    secs "${5:-}"
    dev=$(uplink)
    iptables -t mangle -C OUTPUT $(owner) -m comment --comment ddv-netem -j MARK --set-mark 0x77 2>/dev/null \
      || iptables -t mangle -A OUTPUT $(owner) -m comment --comment ddv-netem -j MARK --set-mark 0x77
    tc qdisc del dev "$dev" root 2>/dev/null
    tc qdisc add dev "$dev" root handle 1: htb default 10
    tc class add dev "$dev" parent 1: classid 1:10 htb rate 10gbit
    rate=$4; [ "$rate" = 0 ] && rate=10000000
    tc class add dev "$dev" parent 1: classid 1:20 htb rate "${rate}kbit"
    jit=$(( $3 / 5 )); netem="loss $2%"; [ "$3" -gt 0 ] && netem="delay ${3}ms ${jit}ms $netem"
    tc qdisc add dev "$dev" parent 1:20 handle 20: netem $netem limit 10000
    tc filter add dev "$dev" parent 1: protocol ip handle 0x77 fw flowid 1:20
    later "$5" "tc qdisc del dev $dev root; iptables -t mangle -D OUTPUT $(owner) -m comment --comment ddv-netem -j MARK --set-mark 0x77"
    log "netem loss $2 % delay $3 ms rate $4 kbit on $dev for $5 s" ;;
  keys)
    shift; [ $# -ge 1 ] && [ $# -le 120 ] || die "keys: 1..120 key names"
    for k in "$@"; do [[ $k =~ ^[a-z0-9_]+(-[a-z0-9_]+){0,3}$ ]] || die "not a key name: $k"; done
    for k in "$@"; do vm sendkey "$k" >/dev/null || die "sendkey $k failed"; sleep 0.12; done
    log "keys: $# pressed" ;;
  clear)
    pkill -f ddv-fault-timer 2>/dev/null
    iptables -F "$CHAIN" 2>/dev/null; iptables -F "$CHAIN_IN" 2>/dev/null
    dev=$(uplink); tc qdisc del dev "$dev" root 2>/dev/null
    iptables -t mangle -D OUTPUT $(owner) -m comment --comment ddv-netem -j MARK --set-mark 0x77 2>/dev/null
    vm set_link net0 on >/dev/null; vm cont >/dev/null
    log "cleared" ;;
  status)
    { iptables -S "$CHAIN" 2>/dev/null; iptables -S "$CHAIN_IN" 2>/dev/null; } | grep -- '-A' || echo 'no packet faults'
    tc qdisc show dev "$(uplink)" | grep -q netem && echo 'netem active'
    vm info status ;;
  *) die "usage: block <ipv4> <s> | udp <s> | bigudp <ipv4> <s> | tcp443 <s> | offline <s> | link <s> | pause <s> | netem <loss%> <ms> <kbit> <s> | keys <key>… | clear | status" ;;
esac
