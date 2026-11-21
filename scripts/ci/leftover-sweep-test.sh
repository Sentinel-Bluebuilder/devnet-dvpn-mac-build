#!/bin/bash
# ─── scripts/ci/leftover-sweep-test.sh <repo>: gha-live.sh sweep_leftovers / CLEANUP_ONLY vs a stub CLI + fake Solana RPC (no chain) ───
set -uo pipefail
REPO=$1
T=$(mktemp -d); trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# fake RPC: getBalance answers the lamports in $T/bal.<address>; anything else = blockhash/ok
cat >"$T/rpc.py" <<'EOF'
import http.server, json, os, sys
D = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if req.get('method') == 'getBalance':
            f = os.path.join(D, 'bal.' + req['params'][0])
            res = {'context': {'slot': 1}, 'value': int(open(f).read()) if os.path.exists(f) else 0}
        else:
            res = None
        body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'result': res}).encode()
        self.send_response(200); self.send_header('content-type', 'application/json'); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
EOF
PORT=18899; python3 -I "$T/rpc.py" "$PORT" "$T" & SRV=$!; sleep 1

# stub CLI: agent status -> tDVPN from $T/tdv.<key-basename>; wallet send logs and (if $T/sendworks) empties the balance
cat >"$T/cli" <<EOF
#!/bin/bash
k=\$(basename "\${DVPN_KEYFILE:-none}" .json); a=\${k#b-}
echo "\$*" >>"$T/calls.log"
case "\$1 \$2" in
  'agent status') echo "{\"tdvpn\":\"\$(cat "$T/tdv.\$a" 2>/dev/null || echo 0)\",\"sol\":\"0.07\"}" ;;
  'wallet send')
    if [ -f "$T/sendworks" ]; then
      case " \$* " in *' --sol '*) echo 3000 >"$T/bal.\$a" ;; *' --tdvpn '*) echo 0 >"$T/tdv.\$a" ;; esac
      echo '{"signature":"stub"}'
    else echo '{"ok":false,"code":"low-sol-after"}'; exit 5; fi ;;
  'wallet show') echo '{"owner":"OWNERaddr111111111111111111111111111111111"}' ;;
  *) echo '{"ok":true}' ;;
esac
EOF
chmod +x "$T/cli"

setup() { # setup <address> <lamports> <tdvpn>
  rm -rf "$T/ev" "$T/lo"; mkdir -p "$T/ev" "$T/lo"
  printf 'owner=OWNERaddr111111111111111111111111111111111\ncleaned=1\n' >"$T/ev/.state"
  echo '{}' >"$T/lo/b-$1.json"; echo "$2" >"$T/bal.$1"; echo "$3" >"$T/tdv.$1"; : >"$T/calls.log"; echo '{}' >"$T/key.json"
}
runit() { CLEANUP_ONLY=1 CLI="$T/cli" DVPN_KEYFILE="$T/key.json" EVIDENCE_DIR="$T/ev" LEFTOVER_DIR="$T/lo" SOL_RPC="http://127.0.0.1:$PORT" \
  TX_GAP=0 bash "$REPO/scripts/e2e/mac/gha-live.sh" >"$T/out.txt" 2>&1; }

# 1. funds come back: tDVPN first, then SOL with --allow-empty to the owner; the key is deleted, PASS
touch "$T/sendworks"; setup BaddrOne 71796200 2; runit
check 'tDVPN all to the owner'        'grep -q -- "wallet send --to OWNERaddr111111111111111111111111111111111 --tdvpn 2 --yes --json" "$T/calls.log"'
check 'SOL all less dust, allow-empty' 'grep -q -- "--sol 0.071786200 --allow-empty --yes --json" "$T/calls.log"'
check 'key deleted once empty'        '[ ! -e "$T/lo/b-BaddrOne.json" ]'
check 'leftover_sweep PASS recorded'  'grep -q "\"row\":\"leftover_sweep\",\"verdict\":\"PASS\"" "$T/ev/rows.jsonl"'
# 2. negative control: the send is refused (as in runs 44843609674 / 44846196847): the key is KEPT, DIFFERS
rm -f "$T/sendworks"; setup BaddrTwo 39995000 0; runit
check 'refused send: key kept'        '[ -f "$T/lo/b-BaddrTwo.json" ]'
check 'leftover_sweep DIFFERS'        'grep -q "\"row\":\"leftover_sweep\",\"verdict\":\"DIFFERS\"" "$T/ev/rows.jsonl"'
check 'no tDVPN send when there is none' '! grep -q -- "--tdvpn" "$T/calls.log"'
# 3. no leftovers: nothing sent, no row
setup BaddrThree 0 0; rm -f "$T/lo/"*.json; runit
check 'no keys: no sends'             '! grep -q "wallet send" "$T/calls.log"'
check 'no keys: no row'               '! grep -q leftover_sweep "$T/ev/rows.jsonl"'
# 4. state + rows of the cleaned run are kept (CLEANUP_ONLY never truncates them)
setup BaddrFour 0 0; echo '{"row":"earlier","verdict":"PASS"}' >"$T/ev/rows.jsonl"; runit
check 'cleanup-only keeps rows.jsonl' 'grep -q "\"row\":\"earlier\"" "$T/ev/rows.jsonl"'
exit $fail
