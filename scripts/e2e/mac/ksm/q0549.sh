#!/bin/bash
# Q0549 (fork 6.11, DVPN-LINUX): after an engine crash under kill switch persist, dvpnd must REDIAL (data-path probe
# first), not end the session and leave the user blocked with none. Guest, run DETACHED (the kill switch can cut SSH).
# Usage: bash q0549.sh <out dir>
# Cells (DIR): V2Ray x3 under persist (the gate: Q0549 was found on a V2Ray kill, and V2Ray/Xray is the owner's
# original report), WireGuard x1 under persist (same Wait path, other client), V2Ray x1 with the kill switch off
# (control). Per cell: connect, record the running session, kill -9 the engine, sample 1 s for 20 s.
# PASS (persist) = traffic exits via a node again within 12 s AND a NEW running session row has replaces = the old id,
# the same channel, the same chainStartedUnix (the reconnect chain carried), and wallet tDVPN unchanged (no new
# deposit). A redial is a new session id by design (the old row gets replacedBy), so "same id" is never the test.
# Control (off) = the internet works within 15 s (node or direct) and no pf rules are held unless still connected.
set -u
O=$1; mkdir -p "$O"; LOG=$O/run.log
export DVPN_KEYFILE=$HOME/ksm/ksm-wallet.json DVPN_DATA_DIR=$HOME/ksm/profile PATH=/usr/local/bin:$PATH
WG=85UXF7JoeojwCe3vBEQsu8A3iBhqtggi1n828Lq84K3q; V2SW=${V2SW_NODE:-7vfACxthUe1eRF3XUUqrJD37Q7QbFTmzNCha22PnyNHc}; HY2=${HY2_NODE:-E8nefMLBuBzG1CrA4dSDU9mqq6ZNpv69Bt3w9QEtzvPf}; WG2=${WG2_NODE:-E5o54jGDJct1FNxCpkHbPBRpBzagM92TA98aYswzA74G}; AWG=${AWG_NODE:-6ZCHcPjGR5BRS3UdiUBasUWhDB1tueTuPWNSjuhSguWc}; V2=Di5V9K2Vt5uptJUk7oVVnkDRXt9qWy5HhLbkEJMxEuM2; DIRECT=${DIRECT_IP:-104.196.36.139}
NODE=$HOME/node/bin/node
c() { echo "> $*" >> "$LOG"; devnet-dvpn "$@" >> "$LOG" 2>&1; }
ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }
tdvpn() { devnet-dvpn status 2>&1 | awk '/^Wallet/{for(i=1;i<=NF;i++) if($(i+1)=="tDVPN"){print $i; exit}}'; }
pfn() { sudo -n pfctl -a sentinel-dvpn-c0 -sr 2>/dev/null | grep -cE '^(block|pass)'; }
# the running session as "id<TAB>channel<TAB>chainStartedUnix<TAB>replaces<TAB>proxyEndpoint" (empty = none running)
# every running session as "id<TAB>node" (several = two sessions at once)
sessions_running() {
  devnet-dvpn sessions --json 2>/dev/null | "$NODE" -e '
    let s = ""; process.stdin.on("data", (d) => { s += d; }).on("end", () => {
      let l = []; try { const j = JSON.parse(s); l = Array.isArray(j) ? j : (j.data ?? []); } catch (e) { console.error(`sessions json: ${e.message}`); }
      l.filter((x) => /running|active|connected/i.test(x.status ?? "")).forEach((r) => console.log(`${r.id}\t${r.node}`));
    });'
}
running() {
  devnet-dvpn sessions --json 2>/dev/null | "$NODE" -e '
    let s = ""; process.stdin.on("data", (d) => { s += d; }).on("end", () => {
      let l = []; try { const j = JSON.parse(s); l = Array.isArray(j) ? j : (j.data ?? []); } catch (e) { console.error(`sessions json: ${e.message}`); }
      const r = l.find((x) => /running|active|connected/i.test(x.status ?? ""));
      if (r) console.log([r.id, r.channel, r.chainStartedUnix ?? "", r.replaces ?? "", r.proxyEndpoint ?? ""].join("\t"));
    });'
}
egress() { # <proxyEndpoint or empty>: V2Ray proxy mode under the kill switch only gets out through its SOCKS port
  if [ -n "$1" ]; then curl -s -m 1.5 -x "socks5h://$1" https://api.ipify.org || echo FAIL
  else curl -s -m 1.5 https://api.ipify.org || echo FAIL; fi
}
printf 'cell\tengine\tks\tfirst_node_s\tfirst_direct_s\tpf_end\told_id\tnew_id\treplaces\tsame_channel\tsame_chain_start\ttdvpn_before\ttdvpn_after\tverdict\n' > "$O/cells.tsv"
one() { # <label> <node> <engine process> <ks>
  local T=$1 N=$2 P=$3 KS=$4
  echo; echo "######## $(date -u +%T) $T engine=$P ks=$KS" >> "$LOG"
  c disconnect; c daemon restore-network; c daemon set --kill-switch "$KS" --whole-device false --yes
  c connect "$N" --basis per_gb --yes; sleep 6
  local b; b=$(running); local wb; wb=$(tdvpn)
  local bid bch bcs bpe; IFS=$'\t' read -r bid bch bcs _ bpe <<< "$b"
  local wp; wp=$(pgrep -x "$P" | head -1)
  echo "before: id=$bid channel=$bch chainStart=$bcs proxy=$bpe | wallet $wb tDVPN | $P pid=${wp:-none}" >> "$LOG"
  if [ -z "$wp" ] || [ -z "$bid" ]; then
    printf '%s\t%s\t%s\t-\t-\t-\t%s\t-\t-\t-\t-\t%s\t-\tNOT-CONNECTED\n' "$T" "$P" "$KS" "${bid:--}" "$wb" >> "$O/cells.tsv"; return
  fi
  local k; k=$(ms); sudo -n kill -9 "$wp"
  local fn='' fd='' i e pe="$bpe" cur
  for i in $(seq 1 20); do
    cur=$(running); [ -n "$cur" ] && pe=$(cut -f5 <<< "$cur")
    e=$(egress "$pe")
    local rel; rel=$(awk -v a="$(ms)" -v b="$k" 'BEGIN{printf "%.1f", (a - b) / 1000}')
    echo "$rel egress=$e pf=$(pfn) running=$(cut -f1,4 <<< "$cur" | tr '\t' ' ')" >> "$LOG"
    if [ "$e" != FAIL ] && [ "$e" != "$DIRECT" ] && [ -z "$fn" ]; then fn=$rel; fi
    if [ "$e" = "$DIRECT" ] && [ -z "$fd" ]; then fd=$rel; fi
    sleep 1; sudo -n touch /var/run/ddv-deadman.hold
  done
  local a; a=$(running); local wa; wa=$(tdvpn); local pe2; pe2=$(pfn)
  local aid ach acs arp; IFS=$'\t' read -r aid ach acs arp _ <<< "$a"
  echo "after: id=$aid channel=$ach chainStart=$acs replaces=$arp | wallet $wa tDVPN | pf $pe2" >> "$LOG"
  devnet-dvpn sessions >> "$LOG" 2>&1; devnet-dvpn status >> "$LOG" 2>&1
  local sc=no scs=no; [ -n "$ach" ] && [ "$ach" = "$bch" ] && sc=yes
  # chain start carried: the new row has one, and it equals the old row's (an old first session may report 0/empty,
  # its chain starts at its own startedAt; then any carried non-zero value counts)
  if [ -n "$acs" ] && [ "$acs" != 0 ]; then
    if [ "$acs" = "$bcs" ] || [ -z "$bcs" ] || [ "$bcs" = 0 ]; then scs=yes; fi
  fi
  local v=FAIL
  if [ "$KS" = persist ]; then
    [ -n "$fn" ] && awk -v t="$fn" 'BEGIN{exit !(t<=12)}' && [ -n "$aid" ] && [ "$aid" != "$bid" ] && [ "$arp" = "$bid" ] \
      && [ $sc = yes ] && [ $scs = yes ] && [ "$wa" = "$wb" ] && v=PASS
  else
    local w=${fn:-$fd}; [ -n "$w" ] && awk -v t="$w" 'BEGIN{exit !(t<=15)}' && { [ "$pe2" = 0 ] || [ -n "$aid" ]; } && v=PASS
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$T" "$P" "$KS" "${fn:--}" "${fd:--}" "$pe2" "$bid" "${aid:--}" "${arp:--}" "$sc" "$scs" "$wb" "$wa" "$v" >> "$O/cells.tsv"
}
asked() { # <label> disconnect|switch: WireGuard under persist, a requested teardown, then 20 s of samples
  local T=$1 A=$2 TO=${3:-$WG2}
  echo; echo "######## $(date -u +%T) $T asked=$A ks=persist" >> "$LOG"
  c disconnect; c daemon restore-network
  # positive control: with the network restored the same probe must see the direct IP (else "no leak" proves nothing)
  local ctl; ctl=$(curl -s -m 3 https://api.ipify.org || echo FAIL); echo "probe control (network restored): $ctl" >> "$LOG"
  c daemon set --kill-switch persist --whole-device false --yes
  c connect "$WG" --basis per_gb --yes; sleep 6
  local bid; bid=$(running | cut -f1)
  [ -n "$bid" ] || { printf '%s\tasked-%s\tpersist\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\tNOT-CONNECTED\n' "$T" "$A" >> "$O/cells.tsv"; return; }
  # DIR 11-13: the block must hold DURING the teardown/switch, so direct egress is probed in the background from
  # just before the action until the samples end; any answer from the direct IP is a leak.
  local EG="$O/$T-direct-egress.txt"; : > "$EG"
  ( while [ ! -e "$O/.stop-eg" ]; do echo "$(ms) $(curl -s -m 1.5 https://api.ipify.org || echo FAIL)" >> "$EG"; sleep 0.3; done ) &
  local egp=$!
  local rc=0
  if [ "$A" = switch ]; then devnet-dvpn connect "$TO" --switch --basis per_gb --yes >> "$LOG" 2>&1 || rc=$?
  else devnet-dvpn disconnect >> "$LOG" 2>&1 || rc=$?; fi
  echo "action $A exit=$rc" >> "$LOG"
  local i cur old_back=no old_gone=no nid='' nnode=''
  for i in $(seq 1 20); do
    cur=$(sessions_running)
    echo "$i running=$(echo "$cur" | tr '\n\t' '  ')" >> "$LOG"
    # the old node "runs again" only after it was gone (a refused switch keeps the old session: not a redial)
    if echo "$cur" | grep -q "$WG"; then [ "$old_gone" = yes ] && old_back=yes; else old_gone=yes; fi
    sleep 1; sudo -n touch /var/run/ddv-deadman.hold
  done
  touch "$O/.stop-eg"; wait "$egp" 2>/dev/null; rm -f "$O/.stop-eg"
  cur=$(sessions_running); nid=$(echo "$cur" | head -1 | cut -f1); nnode=$(echo "$cur" | head -1 | cut -f2)
  local nrun; nrun=$(echo "$cur" | grep -c .)
  local leaks probes; leaks=$(awk -v d="$DIRECT" '$2==d{n++} END{print n+0}' "$EG"); probes=$(grep -c . "$EG")
  echo "direct egress probes=$probes leaks=$leaks" >> "$LOG"
  local why='' v=PASS
  [ "$rc" = 0 ] || why="$why action exit=$rc;"
  [ "$leaks" = 0 ] || why="$why LEAK: direct egress $leaks/$probes during the $A;"
  [ "$probes" -gt 10 ] || why="$why too few egress probes ($probes);"
  [ "$ctl" = "$DIRECT" ] || why="$why probe control did not see the direct IP ($ctl);"
  if [ "$A" = disconnect ]; then [ "$nrun" = 0 ] || why="$why a session runs after disconnect ($nid);"
  else
    [ "$old_back" = no ] || why="$why the old node runs again (redial);"
    [ "$nrun" = 1 ] && [ "$nnode" = "$TO" ] || why="$why not exactly one session on the new node ($nrun, $nnode);"
  fi
  [ -z "$why" ] || v=FAIL
  devnet-dvpn sessions 2>&1 | head -3 >> "$LOG"
  echo "verdict $v $why" >> "$LOG"
  printf '%s\tasked-%s\tpersist\t-\t-\t%s\t%s\t%s\t-\t-\t-\t-\t-\t%s\n' "$T" "$A" "$(pfn)" "$bid" "${nid:--}" "$v" >> "$O/cells.tsv"
}
# CELLS picks a set (DIR 11-13): default = the 6.11 set; awg = AmneziaWG x1 persist; switch = WG->WG + WG->V2Ray server
# switch under persist (the switch fix proof); wg3 = WireGuard x3 + AmneziaWG x1
# persist + WireGuard KS-off control (the 6.13 proof). amneziawg-go and wireguard-go both background themselves on macOS.
case ${CELLS:-default} in
  switch1) asked wireguard-switch-to-wireguard switch "$WG2" ;;
  switch) asked wireguard-switch-to-wireguard switch "$WG2"; sleep 7
          asked wireguard-switch-to-v2ray switch "$V2SW"; sleep 7
          asked wireguard-switch-to-hy2 switch "$HY2" ;;
  awg) one amneziawg-persist-1 "$AWG" amneziawg-go persist; sleep 7 ;;
  wg3) for n in 1 2 3; do one "wireguard-persist-$n" "$WG" wireguard-go persist; sleep 7; done
       one amneziawg-persist-1 "$AWG" amneziawg-go persist; sleep 7
       one wireguard-control-ks-off "$WG" wireguard-go off; sleep 7
       # DIR 6.13: a requested teardown must never read as an engine crash (no redial, ended as asked)
       asked wireguard-asked-disconnect disconnect; sleep 7
       asked wireguard-asked-switch switch ;;
  *) for n in 1 2 3; do one "v2ray-persist-$n" "$V2" v2ray persist; sleep 7; done
     one wireguard-persist-1 "$WG" wireguard-go persist; sleep 7
     one v2ray-control-ks-off "$V2" v2ray off ;;
esac
c disconnect; c daemon restore-network; c daemon set --kill-switch off --yes
echo "Q0549_DONE $(date -u +%T)" >> "$LOG"
