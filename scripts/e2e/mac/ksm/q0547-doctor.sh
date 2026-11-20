#!/bin/bash
# Q0547 / Q0542 doctor check on the installed service (guest, after an upgrade). Usage: bash q0547-doctor.sh <out dir>
# User run: background, privileges, key and kill_switch rows are skip or a real ok/warn, never a green tick that
# hides a permission denial; no sfltool or SecurityAgent prompt; the run ends inside its budget. Root run: background
# is a real result (never skip). Writes <out>/result.txt and the two JSON outputs.
set -u
O=$1; mkdir -p "$O"
B=/Library/devnet-dvpn/sentinel-dvpnd
H="/Library/Application Support/sentinel-dvpn/c0"
ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }
sa0=$(pgrep -f SecurityAgent | wc -l | tr -d ' ')
t0=$(ms); "$B" doctor --instance c0 --home "$H" --output json > "$O/doctor-user.json" 2> "$O/doctor-user.err"; ue=$?; t1=$(ms)
t2=$(ms); sudo -n "$B" doctor --instance c0 --home "$H" --output json > "$O/doctor-root.json" 2> "$O/doctor-root.err"; re=$?; t3=$(ms)
sleep 2
row() { "$HOME/node/bin/node" -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const x=(Array.isArray(r)?r:r.checks||[]).find(c=>c.name===process.argv[2]);console.log(x?`${x.severity}\t${x.ok}\t${(x.detail||"").slice(0,110)}`:"absent")' "$1" "$2"; }
{
  echo "user_run exit=$ue ms=$((t1 - t0))"
  echo "root_run exit=$re ms=$((t3 - t2))"
  for n in background privileges key kill_switch; do
    echo "user $n	$(row "$O/doctor-user.json" $n)"
    echo "root $n	$(row "$O/doctor-root.json" $n)"
  done
  echo "sfltool_procs_after=$(pgrep -f 'sfltool dumpbtm' | wc -l | tr -d ' ')"
  echo "doctor_procs_after=$(pgrep -f 'sentinel-dvpnd doctor' | wc -l | tr -d ' ')"
  echo "securityagent_before=$sa0 after=$(pgrep -f SecurityAgent | wc -l | tr -d ' ')"
} > "$O/result.txt"
# verdict: user background must be skip; root background must not be skip; no green 'ok' with a denial in its detail
v=PASS
grep -q '^user background	skip	' "$O/result.txt" || v=FAIL
grep -qE '^root background	skip	' "$O/result.txt" && v=FAIL
grep -qiE '^user [a-z_]+	ok	true	.*(permission denied|must run as root|unable to open)' "$O/result.txt" && v=FAIL
grep -q 'sfltool_procs_after=0' "$O/result.txt" || v=FAIL
[ $((t1 - t0)) -lt 15000 ] && [ $((t3 - t2)) -lt 15000 ] || v=FAIL
echo "VERDICT $v" >> "$O/result.txt"
