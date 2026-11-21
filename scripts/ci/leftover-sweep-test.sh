#!/bin/bash
# ─── leftover-sweep-test.sh <repo>: sweep_leftovers / verdict_gate / CLEANUP_ONLY against a stub CLI + a fake Solana RPC ───
# Linux (ctl), no chain. Needs python3 + OpenSSL 3. The fake RPC models what stranded run 44862462145 (R10-9):
# a transfer that leaves 0 < balance < 890880 lamports (rent minimum) is refused (InsufficientFundsForRent); one that
# leaves exactly 0 closes the account. The SOL leg is our own one-signature transfer (soltx.py + openssl), so it is
# built, checked against the intent, signed and decoded here exactly as on the runner.
set -uo pipefail
REPO=$1
T=$(mktemp -d); SRV=''
trap '[ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
SOLTX="$REPO/scripts/e2e/mac/soltx.py"

# ─── fake RPC: balances in $T/bal.<address>; every sendTransaction is logged to $T/sent.log ───
cat >"$T/rpc.py" <<'EOF'
import base64, http.server, json, os, sys
D = sys.argv[2]
RENT_MIN, FEE = 890880, 5000
B58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
def b58e(b):
    n = int.from_bytes(b, 'big'); s = ''
    while n: n, r = divmod(n, 58); s = B58[r] + s
    return '1' * (len(b) - len(b.lstrip(b'\0'))) + s
def bal(a):
    f = os.path.join(D, 'bal.' + a)
    return int(open(f).read()) if os.path.exists(f) else 0
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        m, p = req.get('method'), req.get('params', [])
        err, res = None, None
        if m == 'getBalance':
            res = {'context': {'slot': 1}, 'value': bal(p[0])}
        elif m == 'getLatestBlockhash':
            res = {'context': {'slot': 1}, 'value': {'blockhash': b58e(bytes(range(1, 33))), 'lastValidBlockHeight': 9}}
        elif m == 'sendTransaction' and os.path.exists(os.path.join(D, 'fail_once')):
            os.remove(os.path.join(D, 'fail_once')); open(os.path.join(D, 'sent.log'), 'a').write('transient\n')
            err = {'code': -32005, 'message': 'Node is behind (transient)'}
        elif m == 'sendTransaction':
            raw = base64.b64decode(p[0]); msg = raw[1 + 64:]
            # message: header(3) | shortvec n | n*32 keys | blockhash(32) | ix...; System transfer data = u32 2 + u64 lamports
            n = msg[3]; keys = [msg[4 + 32 * i: 4 + 32 * (i + 1)] for i in range(n)]
            frm, to, lam = b58e(keys[0]), b58e(keys[1]), int.from_bytes(msg[-8:], 'little')
            left = bal(frm) - lam - FEE
            open(os.path.join(D, 'sent.log'), 'a').write(f'{frm} {to} {lam} left={left}\n')
            if left < 0: err = {'code': -32002, 'message': 'insufficient funds'}
            elif 0 < left < RENT_MIN: err = {'code': -32002, 'message': 'Transaction results in an account (0) with insufficient funds for rent'}
            else:
                open(os.path.join(D, 'bal.' + frm), 'w').write(str(left))
                credit = bal(to) + lam  # read before open('w') truncates the file
                open(os.path.join(D, 'bal.' + to), 'w').write(str(credit))
                res = 'fakeSig' + str(lam)
        elif m == 'getSignatureStatuses':
            res = {'context': {'slot': 1}, 'value': [{'confirmationStatus': 'confirmed', 'err': None}]}
        body = json.dumps({'jsonrpc': '2.0', 'id': 1, **({'error': err} if err else {'result': res})}).encode()
        self.send_response(200); self.send_header('content-type', 'application/json'); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
EOF
PORT=18899; python3 -I "$T/rpc.py" "$PORT" "$T" & SRV=$!; sleep 1

# a real Solana key file (64 numbers: seed + public key) so soltx.py can build and openssl can sign
mkkey() { # mkkey <out.json>: prints its address
  local pem="$T/k.pem" der
  openssl genpkey -algorithm ed25519 -out "$pem" 2>/dev/null
  der=$(openssl pkey -in "$pem" -outform DER 2>/dev/null | tail -c 32 | od -An -tu1 | tr -s ' \n' ' ')
  pub=$(openssl pkey -in "$pem" -pubout -outform DER 2>/dev/null | tail -c 32 | od -An -tu1 | tr -s ' \n' ' ')
  echo "[$(echo $der $pub | tr ' ' ',')]" >"$1"; rm -f "$pem"
  python3 -I "$SOLTX" pubkey "$1"
}
OWNER=$(mkkey "$T/owner.json")
# ─── stub CLI: agent status -> tDVPN from $T/tdv.<address>; wallet send --tdvpn logs and empties it ───
cat >"$T/cli" <<EOF
#!/bin/bash
k=\$(basename "\${DVPN_KEYFILE:-none}" .json); a=\${k#b-}
echo "\$*" >>"$T/calls.log"
case "\$1 \$2" in
  'agent status') echo "{\"tdvpn\":\"\$(cat "$T/tdv.\$a" 2>/dev/null || echo 0)\"}" ;;
  'wallet send') case " \$* " in *' --tdvpn '*) echo 0 >"$T/tdv.\$a"; echo '{"signature":"stub"}' ;; *) echo '{"ok":false}'; exit 1 ;; esac ;;
  'wallet show') echo '{"owner":"$OWNER"}' ;;
  *) echo '{"ok":true}' ;;
esac
EOF
chmod +x "$T/cli"

setup() { # setup <lamports> <tdvpn>: one leftover wallet with a real key; sets ADDR
  rm -rf "$T/ev" "$T/lo"; mkdir -p "$T/ev" "$T/lo"; : >"$T/calls.log"; : >"$T/sent.log"; echo 0 >"$T/bal.$OWNER"
  printf 'owner=%s\ncleaned=1\n' "$OWNER" >"$T/ev/.state"
  ADDR=$(mkkey "$T/lo/new.json"); mv "$T/lo/new.json" "$T/lo/b-$ADDR.json"
  echo "$1" >"$T/bal.$ADDR"; echo "$2" >"$T/tdv.$ADDR"; echo '{}' >"$T/key.json"
}
# M33-15: a test escrow key pair (the real one: private half on ctl only, public half scripts/e2e/mac/leftover-escrow-pub.txt)
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$T/esc.key" 2>/dev/null; openssl pkey -in "$T/esc.key" -pubout -out "$T/esc.pub"
RUN_BASH=${RUN_BASH:-bash}
runit() { CLEANUP_ONLY=1 CLI="$T/cli" DVPN_KEYFILE="$T/key.json" EVIDENCE_DIR="$T/ev" LEFTOVER_DIR="$T/lo" \
  SOL_RPC="http://127.0.0.1:$PORT" TX_GAP=0 CONFIRM_POLL_S=0 LEFTOVER_ESCROW_PUB="$T/esc.pub" "$@" "$RUN_BASH" "$REPO/scripts/e2e/mac/gha-live.sh" >"$T/out.txt" 2>&1; echo $? >"$T/rc"; }
row_is() { grep -q "\"row\":\"$1\",\"verdict\":\"$2\"" "$T/ev/rows.jsonl"; }

# 1. run 44862462145's wallet: 79995000 lamports + 2 tDVPN: tDVPN by the CLI, then ONE transfer of balance - fee -> 0
setup 79995000 2; runit env
check 'tDVPN all to the owner'               'grep -q -- "wallet send --to $OWNER --tdvpn 2 --yes --json" "$T/calls.log"'
check 'SOL: one transfer of 79990000 (to 0)'  'grep -q "^$ADDR $OWNER 79990000 left=0$" "$T/sent.log"'
check 'no CLI SOL send (priority fee)'       '! grep -q -- "--sol" "$T/calls.log"'
check 'balance reads 0, owner credited'      '[ "$(cat "$T/bal.$ADDR")" = 0 ] && [ "$(cat "$T/bal.$OWNER")" = 79990000 ]'
check 'key deleted once 0 reads back'        '[ ! -e "$T/lo/b-$ADDR.json" ]'
check 'leftover_sweep PASS'                  'row_is leftover_sweep PASS'
check 'gate: all PASS, step exit 0'          '[ "$(cat "$T/rc")" = 0 ]'
# 2. negative control (R10-9): the chain refuses dust under rent: simulate by a balance the fake cannot close to 0
setup 79995000 0; echo 2000 >"$T/bal.$OWNER"
runit env SWEEP_FEE=10000   # the old rule: leaves 5000 lamports, under rent
check 'dust under rent refused: key KEPT'    '[ -f "$T/lo/b-$ADDR.json" ] && grep -q "left=5000" "$T/sent.log"'
check 'leftover_sweep DIFFERS'               'row_is leftover_sweep DIFFERS'
check 'gate: unexpected DIFFERS, exit 1'     '[ "$(cat "$T/rc")" = 1 ] && grep -q "UNEXPECTED non-PASS row: leftover_sweep" "$T/out.txt"'
# 3. the gate: a declared DIFFERS with a row id + reason passes; an entry without them does not
setup 79995000 0; runit env SWEEP_FEE=10000 EXPECTED_DIFFERS='leftover_sweep=R10-9:negative control'
check 'declared DIFFERS: exit 0'             '[ "$(cat "$T/rc")" = 0 ] && grep -q "expected DIFFERS: leftover_sweep (R10-9: negative control)" "$T/out.txt"'
setup 79995000 0; runit env SWEEP_FEE=10000 EXPECTED_DIFFERS='leftover_sweep'
check 'declared without id/reason: exit 1'   '[ "$(cat "$T/rc")" = 1 ]'
check 'verdict counts printed'               'grep -q "^VERDICTS: {" "$T/out.txt"'
# 3b. M33-18: an entry with a row id but no reason is refused
setup 79995000 0; runit env SWEEP_FEE=10000 EXPECTED_DIFFERS='leftover_sweep=R10-9'
check 'declared id without reason: exit 1'   '[ "$(cat "$T/rc")" = 1 ] && grep -q "UNEXPECTED non-PASS row: leftover_sweep" "$T/out.txt"'
# 3c. M33-15: a transient RPC failure is retried; the wallet still ends at 0 and the key is deleted
setup 79995000 0; touch "$T/fail_once"; runit env
check 'transient failure retried, ends at 0' 'grep -q transient "$T/sent.log" && grep -q "^$ADDR $OWNER 79990000 left=0$" "$T/sent.log" && [ ! -e "$T/lo/b-$ADDR.json" ] && row_is leftover_sweep PASS'
# 3d. M33-15: a wallet that cannot be emptied leaves an ENCRYPTED copy in the uploaded evidence that ctl can open,
# and no plaintext key anywhere in the evidence
setup 79995000 0; cp "$T/lo/b-$ADDR.json" "$T/orig.json"; runit env SWEEP_FEE=10000
E="$T/ev/leftover-escrow/b-$ADDR.json.enc"
check 'escrow: encrypted copy in the evidence' '[ -s "$E" ]'
check 'escrow: ctl key opens it to the same key' 'openssl pkeyutl -decrypt -inkey "$T/esc.key" -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 -in "$E" 2>/dev/null | cmp -s - "$T/orig.json"'
check 'escrow: no plaintext key in the evidence' '! grep -rqF "$(head -c 40 "$T/orig.json")" "$T/ev"'
check 'escrow: the row says so'              'grep -q "escrowed" "$T/ev/rows.jsonl"'
# 3e. M33-19: Apple bash 3.2 (set -u, empty EXPECTED_DIFFERS) reaches the gate message (BASH32 = a bash 3.2 binary)
if [ -n "${BASH32:-}" ]; then
  setup 79995000 0; RUN_BASH="$BASH32" runit env SWEEP_FEE=10000
  check 'bash 3.2: gate message, exit 1'     '[ "$(cat "$T/rc")" = 1 ] && grep -q "UNEXPECTED non-PASS row: leftover_sweep" "$T/out.txt"'
else echo "SKIP bash 3.2 case (no BASH32 here): the macOS build job runs it with BASH32=/bin/bash"; fi
# 4. no leftovers: nothing sent, no row
setup 0 0; rm -f "$T/lo/"*.json; runit env
check 'no keys: no sends, no row'            '! grep -q . "$T/sent.log" && ! grep -q leftover_sweep "$T/ev/rows.jsonl"'
# 5. CLEANUP_ONLY keeps the earlier rows
setup 0 0; rm -f "$T/lo/"*.json; echo '{"row":"earlier","verdict":"PASS"}' >"$T/ev/rows.jsonl"; runit env
check 'cleanup-only keeps rows.jsonl'        'row_is earlier PASS'
exit $fail
