#!/bin/bash
# ─── Soak: hours of sessions across all six protocols, with faults, watching for leaks ───
#   bash scripts/e2e/mac/soak.sh [minutes=120]        (runs IN the guest; results ~/matrix/soak.tsv)
# Mac twin of #31 vm-soak.ps1. Each cycle: connect (round-robin protocol), traffic, one fault
# (none / service restart / --switch to the next protocol), check the session still carries
# traffic via the node, disconnect, check nothing is left. Every cycle samples dvpnd's RSS and
# open files; at the end growth within one dvpnd process must stay under 10 %, no crash report may
# appear for our processes, and dvpnd's log must have no panic.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
MINUTES=${1:-120}
case_init soak; case_reset
P=-
env_init >/dev/null
SAMPLES="$OUT/soak-samples.tsv"; : > "$SAMPLES"
START_MARK="$OUT/soak.start"; : > "$START_MARK"
mark_all() { sudo wc -l "$DVPND_LOG" 2>/dev/null | awk '{print $1}' > "$OUT/soak.-.mark"; } # the redirect of `sudo wc -l < log` runs unprivileged and left the mark empty
mark_all
# ─── Money + reconnect oracles (SOAK-PLAN.md checks 1 + 2; vendored copies of ~/memory/bin/soak-*.mjs) ───
ORC="$(cd "$(dirname "$0")" && pwd)/soak-oracle"
MONEY="$OUT/soak-money.jsonl"; : > "$MONEY"
CYCLES="$OUT/soak-cycles.csv"; echo 'cycle,start,fault' > "$CYCLES"
money_sample() { node "$ORC/soak-money.mjs" sample --cli "$CLI" --out "$MONEY" >> "$LOG" 2>&1 || note 'money sample failed (see log)'; LAST_MONEY=$(date +%s); }
money_sample

dvpnd_pid() { sudo launchctl print "system/$LABEL" 2>/dev/null | awk '/^\tpid = /{print $3; exit}'; }
sample() { # <cycle> <protocol>
  local pid rss fds
  pid=$(dvpnd_pid); [ -n "$pid" ] || return
  rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
  fds=$(sudo lsof -p "$pid" 2>/dev/null | tail -n +2 | grep -c .)
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$pid" "${rss:-0}" "${fds:-0}" >> "$SAMPLES"
}
next_proto() { # <protocol>: the one after it, round-robin
  local first='' take=0 p
  for p in $ALL_PROTOCOLS; do
    [ -z "$first" ] && first=$p
    [ $take = 1 ] && { echo "$p"; return; }
    [ "$p" = "$1" ] && take=1
  done
  echo "$first"
}
traffic() { # ~5 MB through whatever routes the session (proxy protocols through the SOCKS port)
  local i
  for i in 1 2 3; do
    if is_proxy "$1"; then fetch_bytes 2000000 -m 30 --socks5-hostname "$(socks)" -o /dev/null
    else fetch_bytes 2000000 -m 30 -o /dev/null; fi
  done
}

run 0 '-' 'kill switch off, LAN on, whole device on, split off' -- \
  daemon set --kill-switch off --allow-lan true --whole-device true --split-mode off --split-apps none --split-routes none --yes
END=$(( $(date +%s) + MINUTES * 60 ))
cycle=0; proto=wireguard; faults="none switch none switch none svcrestart none switch none switch"
while [ "$(date +%s)" -lt "$END" ]; do
  cycle=$((cycle + 1))
  set -- $faults; idx=$(( (cycle - 1) % 10 + 1 )); fault=$(eval echo "\${$idx}")
  P=$proto
  note "── cycle $cycle: $proto, fault $fault ($(( (END - $(date +%s)) / 60 )) min left)"
  echo "$cycle,$(date -u +%FT%TZ),$fault" >> "$CYCLES"
  if connect_p "$proto"; then
    traffic "$proto"; sample "$cycle" "$proto"
    case $fault in
      svcrestart)
        : > "$OUT/soak.-.restart"  # deliberate restart: the #77 voucher lines are allowed (see health)
        sudo launchctl kickstart -k "system/$LABEL"
        check "cycle $cycle: dvpnd back after a service restart" bash -c "for i in \$(seq 1 30); do $CLI daemon version >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1"
        sleep 20
        info "cycle $cycle: status after the restart" "$($CLI status 2>&1 | grep -iE '^Session' | head -1)" ;;
      switch)
        local_next=$(next_proto "$proto")
        run 0 'Connected|connected' "cycle $cycle: --switch to $local_next" -- connect "$(node_of "$local_next")" --units 1 --switch --yes \
          && P=$local_next ;;
    esac
    if [ "$fault" != svcrestart ]; then
      check "cycle $cycle: traffic still via the node" egress_is_node "$P"
    fi
    traffic "$P"; sample "$cycle" "$P"
  fi
  run 0 '-' "cycle $cycle: disconnect" -- disconnect; sleep 3
  check "cycle $cycle: nothing left, own IP back" bash -c "$(declare -f no_leftovers egress new_utuns our_procs anchor_rules services proxy_snapshot); LIB='$LIB'; OUT='$OUT'; for i in 1 2 3 4; do no_leftovers && [ \"\$(egress)\" = '$DIRECT' ] && exit 0; sleep 5; done; no_leftovers; exit 1"
  sample "$cycle" -
  [ $(( $(date +%s) - LAST_MONEY )) -ge 600 ] && money_sample  # every 10 min, taken disconnected
  proto=$(next_proto "$proto")
  sleep 7
done

# ─── Leak oracle: within the longest-lived dvpnd process, last vs first sample ───
P=-
read -r lpid lcount <<EOF
$(awk -F'\t' '{n[$4]++} END{for (p in n) print p, n[p]}' "$SAMPLES" | sort -k2 -n | tail -1)
EOF
info 'samples' "$(grep -c . "$SAMPLES") samples, longest-lived dvpnd pid $lpid ($lcount samples), $cycle cycles"
if [ "${lcount:-0}" -ge 6 ]; then
  # skip the first two samples of that process (warm-up), compare the median of the next 3 with the last 3
  growth() { # <column>
    awk -F'\t' -v p="$lpid" -v c="$1" '$4==p{v[++n]=$c} END{
      if (n<6) {print 0; exit}
      a=(v[3]+v[4]+v[5])/3; b=(v[n]+v[n-1]+v[n-2])/3; if (a<=0) {print 0; exit}
      printf "%.1f", (b-a)*100/a }' "$SAMPLES"
  }
  # open files differ by protocol (a connected openvpn holds more than a connected wireguard), so
  # compare only the idle samples (protocol '-', taken after disconnect): skip the first (warm-up),
  # then the mean of the next 2 against the mean of the last 2 (the all-sample window read 19.2 %
  # on a 9-sample pid that mixed protocols)
  growth_idle() { # <column>
    awk -F'\t' -v p="$lpid" -v c="$1" '$4==p && $3=="-"{v[++n]=$c} END{
      if (n<5) {print "n/a"; exit}
      a=(v[2]+v[3])/2; b=(v[n]+v[n-1])/2; if (a<=0) {print 0; exit}
      printf "%.1f", (b-a)*100/a }' "$SAMPLES"
  }
  rg=$(growth 5); fg=$(growth_idle 6)
  check "dvpnd memory growth under 10 % ($rg %)" awk -v g="$rg" 'BEGIN{exit !(g < 10)}'
  if [ "$fg" = 'n/a' ]; then
    # the soak's restart fault cuts every dvpnd process short; too few idle samples is not a pass
    record FAIL 'enough idle samples of one dvpnd process to judge open-files growth' "longest-lived pid ($lpid) had fewer than 5 idle samples; lengthen the restart-fault interval"
  else
    check "dvpnd open files growth under 10 % ($fg %)" awk -v g="$fg" 'BEGIN{exit !(g < 10)}'
  fi
else
  record FAIL 'enough samples of one dvpnd process to judge growth' "longest-lived pid had ${lcount:-0}"
fi
crashes=$(find /Library/Logs/DiagnosticReports ~/Library/Logs/DiagnosticReports -newer "$START_MARK" -type f 2>/dev/null \
  | grep -iE 'dvpnd|xray|v2ray|openvpn|hysteria|wireguard|amnezia|awg|devnet' || true)
check 'no crash report for our processes' test -z "$crashes"
[ -n "$crashes" ] && info 'crash reports' "$crashes"
CASE=soak; P=-; health soak
# ─── money accuracy + reconnects (the last money sample after the last session's record is final) ───
sleep 60; money_sample
check 'money: tDVPN balances against history spend (soak-money.mjs check)' bash -c "node '$ORC/soak-money.mjs' check '$MONEY' | tee -a '$LOG' | tail -1 | grep -q '^PASS money'"
sudo cat "$DVPND_LOG" > "$OUT/soak-dvpnd.log" 2>/dev/null
check 'reconnects within the cap (soak-reconnects.mjs)' bash -c "node '$ORC/soak-reconnects.mjs' '$OUT/soak-dvpnd.log' '$CYCLES' | tee -a '$LOG' | tail -1 | grep -q '^PASS reconnects'"
rm -f "$OUT/soak-dvpnd.log"
summary
