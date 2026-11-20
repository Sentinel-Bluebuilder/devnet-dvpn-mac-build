#!/usr/bin/env node
// ─── CLI fuzz (run IN the guest from the repo): hostile values into every command and flag ───
// Every command in src/cli/catalogue.ts gets: no args, each hostile value as a positional, each
// hostile value for each documented flag, and one unknown flag. Asserted per run:
//   exit 0/1/2/3 (never a signal or a hang), no stack trace / fatal / raw JS error text,
//   an unknown flag exits 3, a secret in a URL is never printed back, no input is ever executed.
// Asserted after: dvpnd settings, the pf rules, the system proxy and the key file are unchanged.
// Safety: --yes / -y are never passed, so nothing confirm-gated acts. App state goes to a throwaway
// data dir whose RPC is a dead local address: the fuzz makes no chain calls at all.
// Commands that change the system WITHOUT --yes are skipped (listed in SKIP, with the reason).
// Usage: node scripts/e2e/mac/fuzz.mjs [--quick]   → ~/sweep/fuzz.tsv + fuzz.log
import { spawnSync, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { buildSync } from 'esbuild';

const QUICK = process.argv.includes('--quick');
const CLI = '/Applications/Devnet dVPN.app/Contents/Resources/bin/devnet-dvpn';
const OUT = path.join(os.homedir(), 'sweep');
const PWNED = path.join(os.tmpdir(), 'ddv-fuzz-pwned');
const SECRET = 'FUZZSECRET0123';

// ─── What is fuzzed ───
const SKIP = {
  'daemon init': 'creates the service home (root)',
  'daemon restore-network': 'changes the network now',
  'disconnect': 'ends a live session',
  'proxy off': 'changes the system proxy',
  'proxy browser': 'opens a browser',
  'quality speed': 'downloads 25 MB',
  'quality ip': 'calls an outside service',
  'poll watch': 'runs until stopped',
  'poll run': 'runs the pollers (RPC)',
  'test stop': 'stops a running test',
  'wallet export': 'prints key material (with --yes)',
};
const VALUES = [
  '', '0', '-1', '1e309', '99999999999999999999999999', 'NaN', 'é漢🙂',
  `'"\`$(touch ${PWNED})\`;|&`, 'x'.repeat(5000), '../../../../etc/passwd',
  `https://u:p@127.0.0.1:9/?api-key=${SECRET}`, ' lead space', 'two\nlines', '-',
];
const FLAG_VALUES = QUICK ? VALUES.slice(0, 5) : VALUES;

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ddv-fuzz-'));
buildSync({ entryPoints: ['src/cli/catalogue.ts'], bundle: true, platform: 'node', format: 'cjs', outfile: path.join(tmp, 'catalogue.cjs'), logLevel: 'error' });
const { CATALOGUE } = await import(path.join(tmp, 'catalogue.cjs'));

const dataDir = path.join(tmp, 'data');
const cwd = path.join(tmp, 'cwd');
fs.mkdirSync(cwd, { recursive: true });
const env = { ...process.env, DVPN_DATA_DIR: dataDir };

function run(argv, timeout = 60_000) {
  const t0 = Date.now();
  const r = spawnSync(CLI, argv, { cwd, env, encoding: 'utf8', timeout, maxBuffer: 16 << 20 });
  return { code: r.status, signal: r.signal, out: `${r.stdout ?? ''}${r.stderr ?? ''}`, ms: Date.now() - t0, err: r.error };
}

// ─── Before ───
const sh = (cmd) => { try { return execFileSync('/bin/bash', ['-c', cmd], { encoding: 'utf8' }); } catch (e) { return `ERR ${e.status}`; } };
const keyHash = () => { const f = process.env.DVPN_KEYFILE; return f && fs.existsSync(f) ? createHash('sha256').update(fs.readFileSync(f)).digest('hex') : 'none'; };
const snapshot = () => ({
  daemon: run(['daemon', 'settings', '--json']).out,
  pf: sh('sudo pfctl -sr 2>/dev/null; sudo pfctl -a dvpnd -sr 2>/dev/null'),
  proxy: sh("networksetup -listallnetworkservices | tail -n +2 | grep -v '^\\*' | while read -r s; do networksetup -getsocksfirewallproxy \"$s\"; networksetup -getdnsservers \"$s\"; done"),
  key: keyHash(),
});
const set = run(['rpc', 'set', 'https://127.0.0.1:9']);
if (set.code !== 0) { console.error(`could not point the throwaway data dir at a dead RPC: ${set.out}`); process.exit(1); }
const before = snapshot();

// ─── Cases ───
const cases = [];
for (const e of CATALOGUE) {
  if (SKIP[e.cmd] !== undefined) continue;
  const words = e.cmd.split(' ').filter((w) => !w.startsWith('--'));
  const flags = [...new Set((e.usage.match(/--[a-z0-9-]+/g) ?? []).filter((f) => f !== '--yes'))];
  cases.push({ e, argv: words, what: 'no args' });
  cases.push({ e, argv: [...words, '--zz-not-a-flag', '1'], what: 'unknown flag', unknown: true });
  for (const v of VALUES) cases.push({ e, argv: [...words, v], what: `positional ${JSON.stringify(v.slice(0, 24))}` });
  for (const f of flags) for (const v of FLAG_VALUES) cases.push({ e, argv: [...words, f, v], what: `${f} ${JSON.stringify(v.slice(0, 24))}` });
}

// ─── Run ───
fs.mkdirSync(OUT, { recursive: true });
const tsv = fs.openSync(path.join(OUT, 'fuzz.tsv'), 'w');
const log = fs.openSync(path.join(OUT, 'fuzz.log'), 'w');
let pass = 0; let fail = 0;
const perCmd = {};
const rec = (ok, name, detail = '') => {
  if (ok) pass++; else { fail++; console.log(`FAIL ${name} :: ${detail.slice(0, 200)}`); }
  fs.writeSync(tsv, `${ok ? 'PASS' : 'FAIL'}\t${name}\t${detail.replace(/[\t\n]/g, ' ').slice(0, 300)}\n`);
};
const STACK = /\n\s+at .+:\d+:\d+|^fatal:|\b(TypeError|ReferenceError|RangeError|SyntaxError)\b|\[object Object\]/m;
console.log(`fuzz: ${cases.length} runs over ${CATALOGUE.length - Object.keys(SKIP).length} commands`);
for (const c of cases) {
  if (c.argv.includes('--yes') || c.argv.includes('-y')) throw new Error('a fuzz case must never carry --yes');
  const r = run(c.argv);
  const name = `${c.e.cmd} · ${c.what}`;
  fs.writeSync(log, `\n### ${name}\n(exit ${r.code}${r.signal ? ` signal ${r.signal}` : ''}, ${r.ms} ms)\n${r.out.slice(0, 2000)}\n`);
  const problems = [];
  if (r.signal || r.code === null) problems.push(`no exit code (${r.signal ?? r.err?.message ?? 'timeout'})`);
  else if (![0, 1, 2, 3].includes(r.code)) problems.push(`exit ${r.code}`);
  // `logs` prints the app log, which records the dead RPC's "TypeError: fetch failed" by design
  if (c.e.cmd !== 'logs' && STACK.test(r.out)) problems.push(`raw error text: ${r.out.match(STACK)[0]}`);
  if (r.out.includes(SECRET) || r.out.includes('u:p@')) problems.push('printed a URL credential back');
  if (c.unknown && r.code !== 3) problems.push(`unknown flag gave exit ${r.code}`);
  rec(problems.length === 0, name, problems.join('; ') || `exit ${r.code}`);
  const t = (perCmd[c.e.cmd] ??= { runs: 0, ok: 0, codes: new Set() });
  t.runs++; if (!problems.length) t.ok++; t.codes.add(r.signal ? `sig:${r.signal}` : String(r.code));
}
// CLI effect lines (FINAL-PASS-EFFECT-SPEC.md CLI group): one per fuzzed command, what was asserted and what came back
for (const [cmd, t] of Object.entries(perCmd)) {
  console.log(`CHECK ${cmd.replace(/\s+/g, '_')} expect exit in 0-3, no raw error, no credential echo, over ${t.runs} runs got ${t.ok}/${t.runs} ok, exits {${[...t.codes].join(',')}}`);
}

// ─── After ───
const after = snapshot();
rec(!fs.existsSync(PWNED), 'no input was ever executed (planted $(touch) never ran)');
for (const k of Object.keys(before)) {
  rec(before[k] === after[k], `unchanged after the fuzz: ${k}`, before[k] === after[k] ? '' : 'differs');
  console.log(`CHECK unchanged:${k} expect same as before the fuzz got ${before[k] === after[k] ? 'same' : 'DIFFERENT'}`);
}
fs.rmSync(tmp, { recursive: true, force: true });
console.log(`fuzz: passed ${pass}  failed ${fail}  (details ${OUT}/fuzz.log)`);
process.exitCode = fail === 0 ? 0 : 1;
