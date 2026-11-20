#!/usr/bin/env node
// ─── soak-money: money-accuracy oracle for every desktop soak (SOAK-PLAN.md gap 1) ───
// Runs ON the soak host (never on the laptop). Two steps:
//   node soak-money.mjs sample --cli "<devnet-dvpn command>" --out <samples.jsonl>   (every 10 min + at start/end)
//   node soak-money.mjs check <samples.jsonl> [--tol <base units>] [--sol-cap <lamports>]
// The CLI is the lane's own: `devnet-dvpn` (Mac/Linux, with DVPN_KEYFILE/DVPN_DATA_DIR set),
// `devnet-dvpn.cmd` (Windows). Each sample reads three CLI JSON views and stores numbers only
// (no keys, no addresses beyond deposit ids):
//   status --json        wallet.ownerTdvpn, wallet.userBalance (refundable pool), ownerLamports, deviceLamports
//   settle list --json   every deposit: escrow, redeemed (paid to the node), refundable (= escrow - redeemed), status
//   history list --json  sessions: spent (base units), startedAt, endedAt, closeReason
// tDVPN conservation (all amounts in base units, 6 decimals):
//   H = ownerTdvpn + userBalance + sum(refundable of every listed deposit)
//   H_first - H_last  must equal  sum(spent of the sessions that started at/after the first sample)
// A deposit only moves money between the owner, its escrow and the refundable pool (all inside H);
// the only tDVPN that leaves H is what the nodes are paid, which history records per session.
// So any difference is unexplained money: FAIL if |drift| > tol. Default tol = 10 + 1 per session
// (each session's spent is rounded to one base unit; a node may redeem its last unit after the record).
// Network fees are SOL, not tDVPN: reported separately, FAIL only above --sol-cap (default 0.05 SOL).
// The last sample must be taken disconnected, after the last session has ended (its spent is final).
import { execSync } from 'node:child_process';
import { appendFileSync, readFileSync } from 'node:fs';

const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const B = (v) => { try { return BigInt(String(v ?? '0')); } catch (err) { throw new Error(`not an integer amount: ${v} (${err.message})`); } };
const tdvpn = (u) => { const n = u < 0n ? -u : u; const s = `${n / 1000000n}.${String(n % 1000000n).padStart(6, '0')}`; return u < 0n ? `-${s}` : s; };

function cliJson(cli, sub) {
  let out;
  try {
    out = execSync(`${cli} ${sub} --json`, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 120000 });
  } catch (err) {
    throw new Error(`"${sub} --json" failed: ${String(err.stderr ?? err.message).trim().slice(0, 200)}`);
  }
  try { return JSON.parse(out); } catch (err) { throw new Error(`"${sub} --json" is not JSON (${err.message})`); }
}

function sample() {
  const cli = opt('--cli'); const out = opt('--out');
  if (!cli || !out) { console.error('usage: sample --cli "<cmd>" --out <file.jsonl>'); process.exit(2); }
  const st = cliJson(cli, 'status');
  const w = st.wallet;
  if (!w) throw new Error('status --json has no wallet (the network could not be reached?)');
  const deps = cliJson(cli, 'settle list');
  const hist = cliJson(cli, 'history list');
  const sessions = (Array.isArray(hist) ? hist : (hist.entries ?? hist.rows ?? []));
  const row = {
    t: Date.now(),
    connected: Boolean(st.session),
    ownerTdvpn: String(w.ownerTdvpn ?? '0'),
    userBalance: String(w.userBalance ?? '0'),
    ownerLamports: String(w.ownerLamports ?? '0'),
    deviceLamports: String(w.deviceLamports ?? '0'),
    deposits: (Array.isArray(deps) ? deps : []).map((d) => ({ id: d.channel, escrow: String(d.escrow), redeemed: String(d.redeemed), refundable: String(d.refundable), status: d.status })),
    sessions: sessions.map((s) => ({ id: s.id, spent: String(s.spent ?? '0'), startedAt: s.startedAt, endedAt: s.endedAt ?? null, closeReason: s.closeReason ?? null })),
  };
  appendFileSync(out, `${JSON.stringify(row)}\n`);
  console.log(`sample ${new Date(row.t).toISOString()} H=${tdvpn(holdings(row))} deposits=${row.deposits.length} connected=${row.connected}`);
}

function holdings(r) {
  return B(r.ownerTdvpn) + B(r.userBalance) + r.deposits.reduce((a, d) => a + B(d.refundable), 0n);
}

function check() {
  const file = args[1];
  if (!file) { console.error('usage: check <samples.jsonl> [--tol N] [--sol-cap lamports]'); process.exit(2); }
  const rows = readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l, i) => {
    try { return JSON.parse(l); } catch (err) { throw new Error(`line ${i + 1}: ${err.message}`); }
  });
  let failed = 0;
  const ok = (m) => console.log(`ok   money ${m}`);
  const bad = (m) => { failed++; console.log(`FAIL money ${m}`); };
  if (rows.length < 2) { bad(`only ${rows.length} sample(s): need a first and a last`); process.exit(1); }
  const first = rows[0]; const last = rows[rows.length - 1];
  if (last.connected) bad('the last sample was taken while connected (its session spend is not final)');
  // sessions of the soak window: started at/after the first sample; the last sample has the final records
  const win = last.sessions.filter((s) => s.startedAt >= first.t);
  const open = win.filter((s) => !s.endedAt);
  if (open.length) bad(`${open.length} soak session(s) never ended in history`);
  const spent = win.reduce((a, s) => a + B(s.spent), 0n);
  const h0 = holdings(first); const h1 = holdings(last);
  const drop = h0 - h1;
  const drift = drop - spent;
  const tol = opt('--tol') !== undefined ? B(opt('--tol')) : 10n + BigInt(win.length);
  const line = `start ${tdvpn(h0)} end ${tdvpn(h1)} drop ${tdvpn(drop)} = spent ${tdvpn(spent)} over ${win.length} sessions, drift ${drift} units (tol ${tol})`;
  (drift <= tol && drift >= -tol ? ok : bad)(`tDVPN balances: ${line}`);
  // cross-check: what the nodes were paid on chain (redeemed growth per deposit) vs what history says
  const red0 = new Map(first.deposits.map((d) => [d.id, B(d.redeemed)]));
  let redeemed = 0n;
  for (const d of last.deposits) redeemed += B(d.redeemed) - (red0.get(d.id) ?? 0n);
  const gone = first.deposits.filter((d) => !last.deposits.some((x) => x.id === d.id)).length;
  console.log(`info money nodes redeemed +${tdvpn(redeemed)} on deposits still listed (${gone} settled away during the soak); history spent ${tdvpn(spent)}`);
  if (redeemed > spent + tol) bad(`nodes redeemed ${tdvpn(redeemed)} but history records only ${tdvpn(spent)} spent`);
  // no sample may show money below the start that the spend so far does not explain
  for (const r of rows) {
    const s = r.sessions.filter((x) => x.startedAt >= first.t).reduce((a, x) => a + B(x.spent), 0n);
    const d = h0 - holdings(r) - s;
    // a live session is redeemed before its record is final: allow one open deposit's escrow in flight
    const inflight = r.connected ? r.deposits.filter((x) => x.status === 'open').reduce((a, x) => a + B(x.escrow), 0n) : 0n;
    if (d > tol + inflight) { bad(`sample ${new Date(r.t).toISOString()}: ${tdvpn(d)} unexplained below the start`); break; }
  }
  // SOL: fees + rent; reported, FAIL only above the cap
  const sol0 = B(first.ownerLamports) + B(first.deviceLamports); const sol1 = B(last.ownerLamports) + B(last.deviceLamports);
  const cap = B(opt('--sol-cap', '50000000'));
  const solDrop = sol0 - sol1;
  (solDrop <= cap ? ok : bad)(`SOL spent on fees/rent ${Number(solDrop) / 1e9} SOL (cap ${Number(cap) / 1e9} SOL)`);
  console.log(failed ? `FAIL money (${failed} check(s))` : 'PASS money');
  process.exit(failed ? 1 : 0);
}

try {
  if (args[0] === 'sample') sample();
  else if (args[0] === 'check') check();
  else { console.error('usage: soak-money.mjs sample --cli "<cmd>" --out <file> | check <file> [--tol N] [--sol-cap L]'); process.exit(2); }
} catch (err) {
  console.error(`soak-money: ${err.message}`);
  process.exit(3);
}
