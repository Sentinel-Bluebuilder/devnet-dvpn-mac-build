#!/bin/bash
# Q0508 KSM sampler (Agent M, #33 guest). One block per step: ./ksm-sample.sh <label> [>> run.log]
# Needs: DVPN_DATA_DIR exported by the caller, Keychain unlocked, sudo -n.
L="${1:-step}"
SVC=Ethernet
ANCHOR=sentinel-dvpn-c0
DLOG=/Library/Logs/DevnetDVPN/dvpnd.log
OFF=/tmp/ksm-dlog.off
CLI=/usr/local/bin/devnet-dvpn
t() { /usr/bin/curl -s -m "$1" "${@:2}" 2>/dev/null; }

echo "=== $(date -u +%H:%M:%S) $L"
# 1. egress the normal way (routing table) and a forced en0 probe (bypasses the tunnel's routes;
#    the kill switch must drop it when it blocks). A forced-en0 answer while "Protected" + KS on = LEAK.
echo "egress_route  $(t 6 https://api.ipify.org || echo FAIL)"
echo "egress_en0    $(t 5 --interface en0 https://api.ipify.org || echo blocked)"
echo "dns_en0_udp   $(dig +short +time=2 +tries=1 -b "$(ipconfig getifaddr en0)" @1.1.1.1 example.com A 2>/dev/null | head -1 || true)"
# 2. pf: is the anchor loaded, how many rules, packets its block rules dropped so far, pf enabled
R=$(sudo -n pfctl -a "$ANCHOR" -vsr 2>/dev/null)
echo "pf_enabled    $(sudo -n pfctl -s info 2>/dev/null | awk '/^Status:/{print $2}')"
echo "pf_rules      $(printf '%s\n' "$R" | grep -cE '^(block|pass)')"
echo "pf_block_pkts $(printf '%s\n' "$R" | awk '/^block/{b=1;next} /^(pass|anchor)/{b=0} b&&/Packets:/{for(i=1;i<=NF;i++) if($i=="Packets:") s+=$(i+1)} END{print s+0}')"
echo "en0_obytes    $(netstat -ibn -I en0 | awk 'NR==2{print $10}')"
# 3. system proxy + DNS (what the OS will actually use)
echo "socks_proxy   $(networksetup -getsocksfirewallproxy "$SVC" | awk -F': ' '/^Enabled|^Server|^Port/{printf "%s ", $2}')"
echo "dns_set       $(networksetup -getdnsservers "$SVC" | tr '\n' ' ')"
echo "dns_scutil    $(scutil --dns | awk '/nameserver\[0\]/{print $3; exit}')"
echo "resolve       $(dscacheutil -q host -a name example.com 2>/dev/null | awk '/ip_address/{print $2; exit}' || true)"
# 4. what the app/CLI says vs the setting; Solana reachable (status reads balances over RPC)
S=$("$CLI" status 2>&1)
echo "app_session   $(printf '%s\n' "$S" | awk '/^Session/{$1="";print}' | cut -c1-110)"
echo "app_daemon    $(printf '%s\n' "$S" | awk '/^Daemon/{$1="";print}' | cut -c1-90)"
echo "app_wallet    $(printf '%s\n' "$S" | awk '/^Wallet/{print $3,$4,$5,$6}')"
echo "ks_setting    $("$CLI" daemon settings 2>&1 | awk '/^killSwitch/{print $2}')"
echo "solana_rpc    $(t 6 -X POST -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' https://api.devnet.solana.com | cut -c1-60 || echo FAIL)"
# 5. dvpnd log lines at warn/error since the last sample
SZ=$(sudo -n stat -f %z "$DLOG"); O=$(cat "$OFF" 2>/dev/null || echo "$SZ"); [ "$O" -gt "$SZ" ] && O=0
echo "dvpnd_errs    $(sudo -n tail -c +$((O + 1)) "$DLOG" | grep -cE '"level":"(warn|error|fatal)"')"
sudo -n tail -c +$((O + 1)) "$DLOG" | grep -E '"level":"(warn|error|fatal)"' | cut -c1-200 | tail -3 | sed 's/^/  dlog /'
echo "$SZ" > "$OFF"
# keep the guest deadman from undoing a block the test wants (honoured 4 min)
sudo -n touch /var/run/ddv-deadman.hold
