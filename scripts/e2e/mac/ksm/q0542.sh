#!/bin/bash
# Q0542 proof, one try (guest). Usage: bash q0542.sh <try>. The app opens the Kill switch screen, then Diagnostics,
# waits for the service check, screenshots it, and stays open 75 s more (await=hold) so the laptop can take a
# framebuffer screenshot from the QEMU host. Then: no doctor/sfltool process may be left 70 s after the screens opened.
set -u
N=${1:-1}
export DVPN_KEYFILE=$HOME/ksm/ksm-wallet.json DVPN_DATA_DIR=$HOME/ksm/profile PATH=/usr/local/bin:$PATH
O=$HOME/ksm/out/q0542/try$N; rm -rf "$O"; mkdir -p "$O/sig"
before=$(pgrep -f "SecurityAgent" | tr '\n' ' ')
t0=$(date +%s)
DVPN_UI_SIG_DIR=$O/sig DVPN_UI_SCENARIO="nav=Kill switch;sleep=8;shot=killswitch;nav=Diagnostics;sleep=25;shot=diagnostics;signal=ready;await=hold:180" \
  UI_TIMEOUT=240 bash ~/rc-030/scripts/e2e/mac/ui-smoke.sh dark "$O/ui" > "$O/ui-smoke.log" 2>&1 &
UIP=$!
for i in $(seq 1 240); do [ -f "$O/sig/ready" ] && break; sleep 1; done
echo "ready_after_s=$(( $(date +%s) - t0 ))" > "$O/result.txt"
# ready = the scenario's Diagnostics screen (the last doctor run) is open: count leftovers 70 s after it, app still open.
sleep 70
echo "doctor_procs_after_70s=$(pgrep -f 'sentinel-dvpnd doctor' | wc -l | tr -d ' ')" >> "$O/result.txt"
echo "sfltool_procs_after_70s=$(pgrep -f 'sfltool dumpbtm' | wc -l | tr -d ' ')" >> "$O/result.txt"
echo "securityagent_before=$before after=$(pgrep -f SecurityAgent | tr '\n' ' ')" >> "$O/result.txt"
echo ok > "$O/sig/hold.ack"; wait $UIP
grep -iE "doctor|service check" "$DVPN_DATA_DIR/logs/app.log" | tail -5 >> "$O/result.txt"
echo "DONE try $N" >> "$O/result.txt"
