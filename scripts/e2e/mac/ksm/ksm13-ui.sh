#!/bin/bash
# Q0508 KSM13 CLI arm (guest, run DETACHED: nohup bash ksm13-cli.sh <label> [state-filter] [change-filter] &).
# 7 states x 10 changes (DIR lists 9 + the split-mode cell). One TSV row per cell + full samples in the log.
# Wallet = key file (no Keychain), so it runs without an SSH session. Baseline allow_lan=true keeps SSH up.
set -u
LABEL=${1:-r1}; SF=${2:-.}; CF=${3:-.}; ARM=${ARM:-cli}
export DVPN_KEYFILE=$HOME/ksm/ksm-wallet.json DVPN_DATA_DIR=$HOME/ksm/profile PATH=/usr/local/bin:$PATH
OUT=$HOME/ksm/out/ksm13-$LABEL; mkdir -p "$OUT"; LOG=$OUT/$ARM.log; TSV=$OUT/grid-$ARM.tsv
DIRECT=${DIRECT_IP:-104.196.36.139}
A=/Applications/Firefox.app/Contents/MacOS/firefox
B="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
H="/Library/Application Support/sentinel-dvpn/c0"
STATES="dis v2p v2w xrp xrw wg blk"
CHANGES="ks_on ks_persist ks_off wd_toggle split_mode appA_on appB_on appA_off lan dns"
[ -s "$TSV" ] || printf 'arm\tstate\tchange\tset_exit\tcfg_after\tsession_after_set\treconnect\tegress_route\tegress_en0\tpf_rules\tsocks\tdns_set\tsolana\tapp_session\tverdict\twhy\n' > "$TSV"

node_of() { case $1 in v2*) echo Di5V9K2Vt5uptJUk7oVVnkDRXt9qWy5HhLbkEJMxEuM2 ;; xr*) echo E9RG1iZJjsLfEuLfDYTHM4yXCjyFE21jBbJLFvGoL2FD ;; *) echo 85UXF7JoeojwCe3vBEQsu8A3iBhqtggi1n828Lq84K3q ;; esac; }
wd_of() { case $1 in v2w|xrw) echo true ;; *) echo false ;; esac; }
conn_of() { case $1 in dis|blk) echo 0 ;; *) echo 1 ;; esac; }
d() { echo "> daemon set $*" >> "$LOG"; devnet-dvpn daemon set "$@" --yes >> "$LOG" 2>&1; local e=$?; echo "exit=$e" >> "$LOG"; return $e; }
conn() { echo "> connect $1" >> "$LOG"; devnet-dvpn connect "$(node_of "$1")" --basis per_gb --yes >> "$LOG" 2>&1; local e=$?; echo "exit=$e" >> "$LOG"; sleep 5; return $e; }
snap() { ~/ksm/sample.sh "$1" > "$OUT/.s" 2>&1; cat "$OUT/.s" >> "$LOG"; }
f() { awk -v k="$1" '$1==k{$1=""; sub(/^ +/,""); print; exit}' "$OUT/.s"; }
cfgv() { sudo -n awk -F"'" -v k="$1" '$0 ~ "^"k" *="{print $2; exit}' "$H/config.toml"; }
reset() {
  devnet-dvpn disconnect >> "$LOG" 2>&1; devnet-dvpn daemon restore-network >> "$LOG" 2>&1
  d --kill-switch off --split-mode off --split-apps none --allow-lan true --dns cloudflare --whole-device "$1"
}

for S in $STATES; do echo "$S" | grep -qE "$SF" || continue
for C in $CHANGES; do echo "$C" | grep -qE "$CF" || continue
  # Resume: a cell already in this arm's table is not run again (the grid can be stopped and restarted).
  awk -F'\t' -v a="$ARM" -v s="$S" -v c="$C" '$1==a && $2==s && $3==c {f=1} END{exit !f}' "$TSV" && continue
  echo; echo "########## $(date -u +%T) CELL $ARM $S x $C" >> "$LOG"
  WD=$(wd_of "$S"); reset "$WD"
  # pre-state for the change
  case $C in
    ks_persist) d --kill-switch on ;; ks_off) d --kill-switch persist ;;
    appB_on) d --split-mode include --split-apps "$A" ;;
    appA_off) d --split-mode include --split-apps "$A;$B" ;;
  esac
  [ "$S" = blk ] && case $C in ks_on|ks_persist|ks_off) ;; *) d --kill-switch persist ;; esac
  # establish the state
  case $S in
    dis) ;;
    blk) [ "$(cfgv kill_switch)" = persist ] || d --kill-switch persist
         conn wg; sudo -n launchctl kill SIGKILL system/co.sentinel.sentinel-dvpnd.c0 >> "$LOG" 2>&1; sleep 20 ;;
    *) conn "$S" ;;
  esac
  snap "$ARM $S x $C : pre"
  # the change
  if [ "$ARM" = ui ]; then
    case $C in
      ks_on) SC="nav=Kill switch;ks-mode=on" ;; ks_persist) SC="nav=Kill switch;ks-mode=persist" ;; ks_off) SC="nav=Kill switch;ks-mode=off" ;;
      wd_toggle) SC="nav=Split tunnelling;check=[aria-label=\"Whole computer\"]:$([ "$WD" = true ] && echo off || echo on);split-apply" ;;
      split_mode) SC="nav=Split tunnelling;split-mode=exclude;split-app=Firefox:on;split-apply" ;;
      appA_on) SC="nav=Split tunnelling;split-mode=include;split-app=Firefox:on;split-apply" ;; appB_on) SC="nav=Split tunnelling;split-app=Google Chrome:on;split-apply" ;;
      appA_off) SC="nav=Split tunnelling;split-app=Firefox:off;split-apply" ;;
      lan) SC="nav=Kill switch;check=[aria-label=\"Allow local network\"]:off;click=[data-ks-apply] .btn-primary;sleep=30" ;;
      dns) SC="nav=Settings;select=DNS while connected:custom;fill=Custom DNS servers:9.9.9.9, 149.112.112.112;click=text:Apply;sleep=30" ;;
    esac
    if [ -z "$SC" ]; then echo "UI: no scenario step for this change (DNS select)" >> "$LOG"; SE=NOUI
    else
      UO=$OUT/ui-$S-$C; echo "> ui scenario: $SC" >> "$LOG"
      DVPN_UI_SCENARIO="$SC;sleep=4;shot=after" UI_TIMEOUT=300 bash ~/rc-030/scripts/e2e/mac/ui-smoke.sh dark "$UO" >> "$LOG" 2>&1
      SE=$("$HOME/node/bin/node" -e "const r=require(process.argv[1]);const s=r.steps||r;process.stdout.write(s.every(x=>x.ok)?\"0\":\"UI:\"+s.filter(x=>!x.ok).map(x=>x.step).join(\",\"))" "$UO/scenario.json" 2>/dev/null || echo UI-noresult)
      echo "ui result $SE" >> "$LOG"
    fi
  else
    case $C in
      ks_on) d --kill-switch on ;; ks_persist) d --kill-switch persist ;; ks_off) d --kill-switch off ;;
      wd_toggle) [ "$WD" = true ] && d --whole-device false || d --whole-device true ;;
      split_mode) d --split-mode exclude --split-apps "$A" ;;
      appA_on) d --split-mode include --split-apps "$A" ;; appB_on) d --split-apps "$A;$B" ;; appA_off) d --split-apps "$B" ;;
      lan) d --allow-lan false ;; dns) d --dns 9.9.9.9,149.112.112.112 ;;
    esac
  SE=$?
  fi
  sleep 5
  snap "$ARM $S x $C : after set"; SESS_SET=$(f app_session)
  KS=$(cfgv kill_switch)
  case $C in
    ks_on) EXP=$([ "$KS" = on ] || [ "$KS" = persist ] && echo ok || echo "ks=$KS") ;;
    ks_persist) EXP=$([ "$KS" = persist ] && echo ok || echo "ks=$KS") ;; ks_off) EXP=$([ "$KS" = off ] && echo ok || echo "ks=$KS") ;;
    split_mode) EXP=$([ "$(sudo -n awk -F"'" '/^\[split\]/{p=1} p&&/^mode/{print $2; exit}' "$H/config.toml")" = exclude ] && echo ok || echo split-mode) ;;
    lan) EXP=$(sudo -n grep -qE '^allow_lan *= *false' "$H/config.toml" && echo ok || echo lan) ;;
    dns) EXP=$(sudo -n grep -q '9.9.9.9' "$H/config.toml" && echo ok || echo dns) ;;
    *) EXP=ok ;;
  esac
  CFG="ks=$KS $(sudo -n shasum -a 256 "$H/config.toml" | cut -c1-10)"
  RC=-
  # A change that needed no service restart keeps the session (11-13: ks on -> persist is a no-op since the one
  # "On" became persist): reconnecting then fails with "Disconnect the current session first" and is no verdict.
  if [ "$(conn_of "$S")" = 1 ]; then
    if f app_session | grep -q Protected; then RC=kept; echo "session kept through the change: no reconnect" >> "$LOG"
    else conn "$S" && RC=ok || RC=FAIL; fi
    snap "$ARM $S x $C : reconnected"
  fi
  # verdict on the last sample
  ER=$(f egress_route); EN=$(f egress_en0); PF=$(f pf_rules); SO=$(f socks_proxy); DN=$(f dns_set); SOL=$(f solana_rpc); AS=$(f app_session)
  WHY=""
  [ "$SE" = 0 ] || [ "$SE" = NOUI ] || WHY="$WHY set_exit=$SE;"
  [ "$EXP" = ok ] || WHY="$WHY readback:$EXP;"
  if [ "$RC" = ok ] || [ "$RC" = kept ]; then
    echo "$AS" | grep -q Protected || WHY="$WHY app not Protected after reconnect;"
    if [ "$KS" != off ] && [ "$EN" != blocked ]; then WHY="$WHY LEAK en0=$EN with KS $KS;"; fi
    echo "$SOL" | grep -q '"ok"' || WHY="$WHY solana unreachable while connected;"
  elif [ "$RC" = FAIL ]; then WHY="$WHY reconnect failed;"
  else # no session at the end
    if [ "$KS" = persist ] && [ "$S" = blk ]; then
      [ "$ER" = "$DIRECT" ] && WHY="$WHY block lifted with KS persist (egress direct);"
    else
      [ "$ER" = "$DIRECT" ] || WHY="$WHY internet not back (egress=$ER);"
      [ "${PF:-0}" = 0 ] || WHY="$WHY stale pf rules=$PF;"
      echo "$SO" | grep -q '^No' || WHY="$WHY system proxy left on;"
    fi
  fi
  V=PASS; [ -n "$WHY" ] && V=FAIL
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ARM" "$S" "$C" "$SE" "$CFG" "$(echo "$SESS_SET" | cut -c1-40)" "$RC" "$ER" "$EN" "$PF" "$(echo "$SO" | cut -c1-12)" "$(echo "$DN" | cut -c1-30)" "$(echo "$SOL" | grep -q '"ok"' && echo ok || echo FAIL)" "$(echo "$AS" | cut -c1-60)" "$V" "$WHY" >> "$TSV"
done; done
reset false; snap "cli END"; echo "GRID_DONE $(date -u +%T)" >> "$LOG"
