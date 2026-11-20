#!/usr/bin/env node
// ─── soak-reconnects: reconnects and guard session ends inside soak cycles (SOAK-PLAN.md gap 2) ───
// Runs ON the soak host. Reads dvpnd's JSON log (one object per line, "time" with an offset) and the
// soak's cycle start times, and reports per cycle: reconnect attempts ("reconnecting") and session ends
// ("ending the session", with its reason). A cycle's own disconnect is not in this log; these lines are
// only the daemon healing or ending a session on its own.
//   node soak-reconnects.mjs <dvpnd.log> <cycles.csv> [--cap N] [--cap-cycle M] [--expect "<reason>|..."]
// cycles.csv: one line per cycle, "<cycle>,<ISO start>[,<fault>]" (header optional). The window ends
// 10 min after the last cycle start, or at --end <ISO>.
// Pass: total unexplained events <= --cap (default 3 per soak) and none of the cycles > --cap-cycle
// (default 2). Events in a cycle whose fault is one the soak injected (restart / flap / switch / airplane)
// are EXPECTED and counted apart (the fault is the cause); --expect adds reasons that never count.
import { readFileSync } from 'node:fs';

const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const [logFile, cyclesFile] = args.filter((a, i) => !a.startsWith('--') && !(i > 0 && args[i - 1].startsWith('--')));
if (!logFile || !cyclesFile) { console.error('usage: soak-reconnects.mjs <dvpnd.log> <cycles.csv> [--cap N] [--cap-cycle M] [--expect "a|b"] [--end ISO]'); process.exit(2); }
const cap = Number(opt('--cap', '3')); const capCycle = Number(opt('--cap-cycle', '2'));
const expect = (opt('--expect', '') || '').split('|').filter(Boolean);

const cycles = readFileSync(cyclesFile, 'utf8').split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !/^cycle\b/i.test(l)).map((l) => {
  const [n, at, fault] = l.split(',');
  const t = Date.parse(at);
  if (Number.isNaN(t)) throw new Error(`cycles.csv: not a time in "${l}"`);
  return { n: Number(n), t, fault: (fault ?? '').trim() };
}).sort((a, b) => a.t - b.t);
if (!cycles.length) { console.log('FAIL reconnects no cycles in cycles.csv'); process.exit(1); }
const end = opt('--end') ? Date.parse(opt('--end')) : cycles[cycles.length - 1].t + 600000;

const events = [];
for (const line of readFileSync(logFile, 'utf8').split(/\r?\n/)) {
  if (!line.includes('"reconnecting"') && !line.includes('"ending the session"')) continue;
  let j;
  try { j = JSON.parse(line); } catch (err) { console.error(`skip unparsable line (${err.message})`); continue; }
  const t = Date.parse(j.time);
  if (Number.isNaN(t) || t < cycles[0].t || t > end) continue;
  const kind = j.message === 'reconnecting' ? 'reconnect' : 'end';
  events.push({ t, kind, reason: kind === 'end' ? String(j.reason ?? j.error ?? 'no reason') : `attempt ${j.attempt ?? '?'}` });
}

const injected = /restart|flap|switch|airplane|nic|link/i;
let unexplained = 0; let worst = 0; let failed = 0;
const rows = cycles.map((c, i) => {
  const until = i + 1 < cycles.length ? cycles[i + 1].t : end;
  const ev = events.filter((e) => e.t >= c.t && e.t < until);
  const exp = ev.filter((e) => injected.test(c.fault) || expect.some((r) => e.reason.includes(r)));
  const un = ev.length - exp.length;
  unexplained += un; worst = Math.max(worst, un);
  return { c, ev, exp: exp.length, un };
});
console.log('cycle\tfault\treconnects\tends\texpected\tunexplained\treasons');
for (const r of rows) {
  const rec = r.ev.filter((e) => e.kind === 'reconnect').length; const ends = r.ev.filter((e) => e.kind === 'end');
  const why = [...new Set(ends.map((e) => e.reason.slice(0, 60)))].join('; ');
  if (r.ev.length) console.log(`${r.c.n}\t${r.c.fault || '-'}\t${rec}\t${ends.length}\t${r.exp}\t${r.un}\t${why}`);
}
const all = events.length;
console.log(`info reconnects ${all} events in ${cycles.length} cycles (${all - unexplained} expected from injected faults, ${unexplained} unexplained)`);
if (unexplained > cap) { failed++; console.log(`FAIL reconnects ${unexplained} unexplained > cap ${cap} per soak`); }
if (worst > capCycle) { failed++; console.log(`FAIL reconnects a cycle had ${worst} unexplained > cap ${capCycle} per cycle`); }
console.log(failed ? 'FAIL reconnects' : `PASS reconnects (${unexplained} unexplained, cap ${cap}; worst cycle ${worst}, cap ${capCycle})`);
process.exit(failed ? 1 : 0);
