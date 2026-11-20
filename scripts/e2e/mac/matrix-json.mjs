// ─── matrix.json from the pulled ~/matrix/<case>.tsv files ───
// node scripts/e2e/mac/matrix-json.mjs <dir>  → <dir>/matrix.json + a table on stdout
// A cell (case × protocol) is PASS only when it has checks and none failed.
import fs from 'node:fs';
import path from 'node:path';

const ROWS = {
  'pay-gb': 'A1 A8 A25', 'pay-hour': 'A2', adopt: 'A5', whole: 'A7', switch: 'A9', 'ks-switch': 'A9 gap67', topup: 'A10', 'ks-connfail': 'A11 edge', 'ks-nodedown': 'A11 edge', 'ks-rpcdown': 'A11 edge', 'safety-drivers': 'F1 F17', 'safety-armed': 'A12 safety',
  'ks-on': 'A11 A13 A14', 'ks-persist': 'A12', dns: 'A15 A16 A17', lan: 'A18', 'split-app': 'A20',
  'split-route': 'A21', 'split-ks': 'A22', reconnect: 'A28', flap: 'A28', pause: 'A28',
  coverage: 'A6 A23', throughput: 'A24', close: 'A26', crash: 'A29', test: 'A30', money: 'A27',
  slowread: 'A24 gap73', keepalive: 'CF6', wipe: 'T13', rival: 'D6', 'proxy-crash': 'T10 T11',
  loss5: 'edge', loss20: 'edge', lat300: 'edge', bw1m: 'edge', mtu1280: 'A24 edge', udpblock: 'edge', tcp443: 'edge',
  'sdyn-toggle': 'A23 split-dyn', 'sdyn-switch-proxy': 'A23 split-dyn', 'sdyn-switch-full': 'A23 split-dyn',
  'sdyn-user-change': 'A23 split-dyn', 'sdyn-user-pac': 'A23 split-dyn', 'sdyn-svc-restart': 'A23 split-dyn',
  'sdyn-browser': 'A23 split-dyn', 'sdyn-port-taken': 'A23 split-dyn', 'sdyn-races': 'A23 split-dyn', 'sdyn-nodedown': 'A23 split-dyn',
};
const PROTOCOLS = ['wireguard', 'amneziawg', 'openvpn', 'hysteria2', 'v2ray', 'xray', 'all'];

const dir = process.argv[2];
if (!dir) throw new Error('usage: matrix-json.mjs <dir>');
const cases = {};
for (const f of fs.readdirSync(dir).filter((n) => n.endsWith('.tsv')).sort()) {
  const name = f.replace(/\.tsv$/, '');
  // a case missing from ROWS still counts (it used to vanish from the evidence silently)
  const cells = {};
  for (const line of fs.readFileSync(path.join(dir, f), 'utf8').split('\n')) {
    const [res, proto, check, detail] = line.split('\t');
    if (!PROTOCOLS.includes(proto) || (res !== 'PASS' && res !== 'FAIL')) continue;
    const c = (cells[proto] ??= { pass: 0, fail: 0, failures: [] });
    if (res === 'PASS') c.pass += 1;
    else { c.fail += 1; c.failures.push(`${check} :: ${(detail ?? '').slice(0, 200)}`); }
  }
  for (const c of Object.values(cells)) c.result = c.fail === 0 && c.pass > 0 ? 'PASS' : 'FAIL';
  cases[name] = { rows: ROWS[name] ?? '(unmapped)', cells };
}
const out = { at: new Date().toISOString(), host: 'macOS guest on ddv-mac-host-1 (x64)', cases };
fs.writeFileSync(path.join(dir, 'matrix.json'), JSON.stringify(out, null, 2) + '\n');

const pad = (s, n) => String(s).padEnd(n);
console.log(pad('case', 19) + PROTOCOLS.map((p) => pad(p, 11)).join(''));
let red = 0;
for (const [name, c] of Object.entries(cases)) {
  console.log(pad(name, 19) + PROTOCOLS.map((p) => {
    const cell = c.cells[p];
    if (!cell) return pad('-', 11);
    if (cell.result !== 'PASS') red += 1;
    return pad(`${cell.result} ${cell.pass}/${cell.pass + cell.fail}`, 11);
  }).join(''));
}
console.log(`\nred cells: ${red}`);
