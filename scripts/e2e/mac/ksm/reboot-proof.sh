#!/bin/bash
# ─── Mac rc.2 respin proof (DIR 11-13): kill switch on + reboot while connected, N times, plus the negative ───
# Runs on the LAPTOP (ssh only; the guest reboots under it). Per KS cell: the app is running (so macOS relaunches it as
# well as the LaunchAgent: the rc.2 reboot 1 double start), WireGuard connected under persist, reboot, OpenCore picker,
# then after log-in: app.log (log-in item, block at start, second launch, page guard), pf rules, 10 direct-egress
# probes, a host screenshot; then Restore network (CLI) for the next cell. Negative: kill switch off, app quit, reboot:
# no app start, no block, direct egress. The guest deadman is disabled for the run (its /var/run hold is wiped at boot).
# Usage: bash reboot-proof.sh <out dir on laptop> <direct ip> [ks cells, default 3]
set -u
OUT=$1; DIRECT=$2; N=${3:-3}; mkdir -p "$OUT"
WG=85UXF7JoeojwCe3vBEQsu8A3iBhqtggi1n828Lq84K3q
G='export PATH=/usr/local/bin:$PATH DVPN_KEYFILE=$HOME/ksm/ksm-wallet.json DVPN_DATA_DIR=$HOME/ksm/profile; AL="$HOME/Library/Application Support/Devnet dVPN/logs/app.log"'
LOG=$OUT/run.log
g() { ssh -o BatchMode=yes -o ConnectTimeout=15 ddv-mac-dv "$G; $1" >> "$LOG" 2>&1; }
h() { ssh -o BatchMode=yes ddv-mac-host-dv "$1"; }
say() { echo "$(date -u +%T) $*" | tee -a "$LOG"; }

reboot_and_wait() {
  ssh -o BatchMode=yes ddv-mac-dv 'sudo -n shutdown -r now' > /dev/null 2>&1
  sleep 40
  h 'python3 /home/ubuntu/vmctl.py key right; sleep 1; python3 /home/ubuntu/vmctl.py key ret' > /dev/null
  local t=0
  until ssh -o BatchMode=yes -o ConnectTimeout=8 ddv-mac-dv true 2>/dev/null; do
    sleep 10; t=$((t + 10))
    if [ $t -eq 120 ]; then h 'python3 /home/ubuntu/vmctl.py key right; sleep 1; python3 /home/ubuntu/vmctl.py key ret' > /dev/null; fi
    [ $t -gt 420 ] && { say "guest did not come back"; return 1; }
  done
  say "guest back"; sleep 100
}

after_boot() { # $1 label
  # A KS cell counts direct egress as a leak; in the negative (kill switch off) direct egress is the expected result.
  local tag=leaks; [ "$1" = neg ] && tag='direct(expected)'
  g "echo '== $1 after boot'; ps -axo lstart=,rss=,args= | grep 'Devnet dVPN' | grep -v grep | grep -E 'MacOS/Devnet dVPN( --hidden)?\$|Renderer' | cut -c1-120; B=\$(sysctl -n kern.boottime | awk '{print \$4}' | tr -d ,); awk -v b=\"\$(date -u -r \$B +%Y-%m-%dT%H:%M)\" 'substr(\$1,2,16) >= b' \"\$AL\" | grep -E 'app start|log-in item|blocks the internet at app start|second launch|start-up window|reloading' | cut -c1-230; echo \"pf anchor rules: \$(sudo -n pfctl -a sentinel-dvpn-c0 -sr 2>/dev/null | wc -l | tr -d ' ')\"; n=0; l=0; for k in \$(seq 1 10); do e=\$(curl -s -m 4 https://api.ipify.org); n=\$((n+1)); [ \"\$e\" = $DIRECT ] && l=\$((l+1)); sleep 2; done; echo \"direct-egress probes=\$n $tag=\$l\""
  h "python3 /home/ubuntu/vmctl.py shot /tmp/$1.png > /dev/null" && scp -q -o BatchMode=yes "ddv-mac-host-dv:/tmp/$1.png" "$OUT/$1.png"
}

say "reboot proof: $N KS cells + negative, direct=$DIRECT"
g 'sudo -n launchctl disable system/network.sentinel.ddv-deadman; echo "deadman: $(sudo -n launchctl print-disabled system | grep deadman)"'
for i in $(seq 1 "$N"); do
  say "cell ks$i: connect under persist, app running"
  g "echo '== ks$i setup'; open -a '/Applications/Devnet dVPN.app'; sleep 8; devnet-dvpn daemon restore-network 2>&1 | tail -1; devnet-dvpn daemon set --kill-switch persist --split-mode off --split-apps none --allow-lan true --dns cloudflare --whole-device false --yes 2>&1 | tail -1; sleep 7; devnet-dvpn connect $WG --basis per_gb --yes 2>&1 | tail -1; for k in 1 2 3 4; do curl -s -m 5 -o /dev/null https://www.google.com; sleep 2; done; devnet-dvpn status 2>&1 | grep -E 'Session'; echo \"egress: \$(curl -s -m 8 https://api.ipify.org)\"; echo \"LaunchAgent: \$(ls ~/Library/LaunchAgents/network.sentinel.devnet-dvpn.app.plist 2>&1)\""
  reboot_and_wait || exit 1
  after_boot "ks$i"
done
say "negative: kill switch off, app quit, connected, reboot"
g "echo '== neg setup'; devnet-dvpn daemon restore-network 2>&1 | tail -1; devnet-dvpn daemon set --kill-switch off --yes 2>&1 | tail -1; sleep 25; echo \"LaunchAgent: \$(ls ~/Library/LaunchAgents/network.sentinel.devnet-dvpn.app.plist 2>&1)\"; osascript -e 'quit app \"Devnet dVPN\"'; sleep 8; pgrep -f 'MacOS/Devnet dVPN' || echo 'app quit'; sleep 7; devnet-dvpn connect $WG --basis per_gb --yes 2>&1 | tail -1; sleep 20; devnet-dvpn status 2>&1 | grep -E 'Session'"
reboot_and_wait || exit 1
after_boot neg
g "echo \"neg egress: \$(curl -s -m 8 https://api.ipify.org)\"; pgrep -fl 'MacOS/Devnet dVPN' || echo 'neg: app not running'"
g 'sudo -n launchctl enable system/network.sentinel.ddv-deadman; sudo -n launchctl bootstrap system /Library/LaunchDaemons/network.sentinel.ddv-deadman.plist 2>&1 | tail -1; echo "deadman: $(sudo -n launchctl print-disabled system | grep deadman)"'
say "REBOOT_PROOF_DONE"
