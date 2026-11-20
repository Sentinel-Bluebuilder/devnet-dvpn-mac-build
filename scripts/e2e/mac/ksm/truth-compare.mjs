// ─── Q0508 ★★ screen truth: join what the app showed (ui/truth.json) with the harness's 1 s truth (shell.tsv) ───
// Usage: node truth-compare.mjs <transition dir> <direct ip>. Writes <dir>/joined.tsv and <dir>/verdict.txt.
// A sample FAILS when the screen contradicts the truth; a FLAP is a claim that changes and comes back within 5 s.
import fs from 'node:fs';
import path from 'node:path';

const [dir, direct] = process.argv.slice(2);
const screen = JSON.parse(fs.readFileSync(path.join(dir, 'ui', 'truth.json'), 'utf8'));
const shell = fs.readFileSync(path.join(dir, 'shell.tsv'), 'utf8').trim().split('\n').slice(1).map((l) => {
  const [t, egress, pf, socks, svc] = l.split('\t');
  return { t: Number(t), egress, pf: Number(pf) || 0, socks, svc: svc ?? '' };
});
const trig = Number((fs.readFileSync(path.join(dir, 'trigger.txt'), 'utf8').match(/TRIGGER (\d+)/) ?? [])[1] ?? 0);

// What the screen claims. Banners count first: a block banner is a claim even when the card is not shown.
function claim(s) {
  const all = `${s.card ?? ''} | ${(s.banners ?? []).join(' | ')}`;
  if (/VPN service is restarting/i.test(all)) return 'restarting';
  if (/blocking (the )?internet|(may still be|is still) blocking|internet (is|may be) blocked|restore network/i.test(all)) return 'blocked';
  if (s.card == null) return 'n/a';
  if (/protected/i.test(s.card)) return 'protected';
  if (/checking/i.test(s.card)) return 'checking';
  if (/connecting|paying|starting|reconnecting/i.test(s.card)) return 'connecting';
  if (/not connected|disconnected|connect/i.test(s.card)) return 'off';
  return 'other';
}
// What is true. blocked = pf rules held and nothing gets out; direct = the computer's own IP; node = another IP.
function truth(x) {
  if (!x) return 'n/a';
  if (x.egress === 'FAIL') return x.pf > 0 ? 'blocked' : 'no-net';
  return x.egress === direct ? 'direct' : 'node';
}
const near = (t) => shell.reduce((b, x) => (Math.abs(x.t - t) < Math.abs((b?.t ?? Infinity) - t) ? x : b), null);

const rows = [];
let fails = 0;
for (const s of screen) {
  const x = near(s.t);
  const skew = x ? Math.abs(x.t - s.t) : null;
  const c = claim(s); const tr = skew != null && skew <= 1000 ? truth(x) : 'n/a';
  let bad = '';
  if (tr !== 'n/a' && c !== 'n/a') {
    // V2Ray/Xray proxy + kill switch: the proxy is the only way out, so a blocked plain probe with the system
    // proxy on is a working session, not a contradiction.
    if (tr === 'blocked' && (c === 'off' || (c === 'protected' && x.socks !== 'Yes'))) bad = `screen "${c}" while blocked (Q0500 shape)`;
    else if (c === 'blocked' && (tr === 'direct' || tr === 'node') && x.pf === 0) bad = 'block shown while nothing is blocked (Q0518 shape)';
    else if (c === 'protected' && tr === 'direct' && x.socks !== 'Yes') bad = 'Protected while traffic exits direct';
    else if (c === 'off' && tr === 'node') bad = '"Not connected" while traffic exits via a node';
  }
  rows.push({ rel: trig ? ((s.t - trig) / 1000).toFixed(1) : '', claim: c, truth: tr, svc: x?.svc ?? '', pf: x?.pf ?? '', egress: x?.egress ?? '', socks: x?.socks ?? '', bad, card: s.card ?? '', banners: (s.banners ?? []).join(' / ') });
}
// DIR 11-12: a run of contradicting samples spanning under 2 s is the poll tick catching up (lag), not a FAIL.
let lags = 0;
for (let i = 0; i < rows.length;) {
  if (!rows[i].bad) { i++; continue; }
  let j = i;
  while (j + 1 < rows.length && rows[j + 1].bad) j++;
  const span = Number(rows[j].rel) - Number(rows[i].rel);
  if (rows[i].rel !== '' && span < 2) { for (let k = i; k <= j; k++) rows[k].bad = `lag (<2 s, PASS): ${rows[k].bad}`; lags++; }
  else fails += j - i + 1;
  i = j + 1;
}
// DIR 42f8f49 guard rule: "restarting" shown while the service is actually up for more than 6 s fails
// (the guard settles 4 s after the service is back; it must not hide the real state).
let upRun = 0;
for (const r of rows) {
  if (r.claim === 'restarting' && r.svc === 'up') {
    upRun++;
    if (upRun > 6 && (!r.bad || r.bad.startsWith('lag'))) { r.bad = '"restarting" shown while the service is up > 6 s (guard hides the state)'; fails++; }
  } else upRun = 0;
}
// flaps: A -> B -> A within 5 samples (ignoring n/a)
// "restarting" is the guard's intended in-between (its abuse is the > 6 s rule above), not a flap.
const seq = rows.map((r) => r.claim).filter((c) => c !== 'n/a' && c !== 'restarting');
const flaps = [];
for (let i = 0; i < seq.length; i++) {
  for (let j = i + 2; j < Math.min(seq.length, i + 6); j++) {
    if (seq[j] === seq[i] && seq.slice(i + 1, j).some((c) => c !== seq[i])) { flaps.push(`${seq.slice(i, j + 1).join('>')}`); i = j - 1; break; }
  }
}
const head = 'rel_s\tclaim\ttruth\tservice\tpf\tegress\tsocks\tbad\tcard\tbanners';
fs.writeFileSync(path.join(dir, 'joined.tsv'), [head, ...rows.map((r) => [r.rel, r.claim, r.truth, r.svc, r.pf, r.egress, r.socks, r.bad, r.card, r.banners].join('\t'))].join('\n') + '\n');
const states = (k) => [...new Set(rows.map((r) => r[k]))].join(',');
const verdict = fails || flaps.length ? 'FAIL' : 'PASS';
const msg = `${path.basename(dir)}\t${verdict}\tsamples=${rows.length}\tcontradictions=${fails}\tlags=${lags}\tflaps=${flaps.length}${flaps.length ? ` (${flaps.slice(0, 3).join('; ')})` : ''}\tclaims=${states('claim')}\ttruth=${states('truth')}`;
fs.writeFileSync(path.join(dir, 'verdict.txt'), msg + '\n');
console.log(msg);
