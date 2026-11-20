#!/bin/bash
# T10 takedown verdict (DIR r7, option 1): "Not connected" within 6 s after the block LIFTS (first shell sample after
# kill switch Off with no pf rules and a working exit), not after the Off command. "Restarting" while the Apply
# restarts the service is true and allowed. Usage: bash t10-takedown.sh <transition dir>. Appends to verdict.txt.
set -u
O=$1
ko=$(awk '{print $2}' "$O/ksoff.txt"); tg=$(grep -o 'TRIGGER [0-9]*' "$O/trigger.txt" | awk '{print $2}')
# block lift = first shell sample after Off with pf 0 and egress not FAIL
lift=$(awk -F'\t' -v k="$ko" 'NR>1 && $1>=k && $3==0 && $2!="FAIL" {print $1; exit}' "$O/shell.tsv")
grep -v '^takedown' "$O/verdict.txt" > "$O/verdict.tmp" && mv "$O/verdict.tmp" "$O/verdict.txt"
if [ -z "$lift" ]; then
  sed -i '' '1s/	PASS	/	FAIL	/' "$O/verdict.txt"; echo "takedown FAIL: the block never lifted after kill switch Off" >> "$O/verdict.txt"; exit 0
fi
lrel=$(awk -v l="$lift" -v t="$tg" 'BEGIN{printf "%.1f", (l - t) / 1000}')
off=$(awk -v k="$ko" -v t="$tg" 'BEGIN{printf "%.1f", (k - t) / 1000}')
td=$(awk -F'\t' -v l="$lrel" 'NR>1 && $1>=l && $2!="blocked" && $2!="restarting" {printf "%.1f", $1 - l; f=1; exit} END{if(!f) print "never"}' "$O/joined.tsv")
if [ "$td" = never ] || awk -v t="$td" 'BEGIN{exit !(t>6)}'; then
  sed -i '' '1s/	PASS	/	FAIL	/' "$O/verdict.txt"
  echo "takedown FAIL: Not connected $td s after the block lifted (Off at +$off s, lift at +$lrel s; budget 6 s)" >> "$O/verdict.txt"
else
  echo "takedown ok: Not connected $td s after the block lifted (Off at +$off s, lift at +$lrel s; budget 6 s)" >> "$O/verdict.txt"
fi
