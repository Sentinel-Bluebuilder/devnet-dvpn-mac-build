#!/usr/bin/env node
// ─── Parity check: shared files must be byte-identical in all four Devnet dVPN repos ───
// Usage: node scripts/parity.mjs            (files in the 2026-11-12 port list)
//        node scripts/parity.mjs --all      (every file under the shared folders, informational)
//        node scripts/parity.mjs --strict   (the port gate: every file under src/ and tests/unit,
//                                            fails on any difference not in PLATFORM or the clone's
//                                            PLATFORM-EXCEPTIONS.txt, `path | reason` per line)
//        node scripts/parity.mjs --repo linux   (only compare #31 with one repo)
// Exit 1 when a listed shared file differs or is missing, outside that repo's allow-list.
// Source of truth = #31 (this repo). Platform files are never compared (see PLATFORM).

import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const DESKTOP = resolve(ROOT, '..');
const REPOS = {
  linux: join(DESKTOP, 'devnet-dvpn-linux'),
  mac: join(DESKTOP, 'devnet-dvpn-mac'),
  android: join(DESKTOP, 'devnet-dvpn-android'),
};

// ─── Shared files changed by e569565..HEAD (docs/PORT-2026-11-12.md) ───
const SHARED = [
  'src/core/app/device-setup.ts',
  'src/core/app/wallet-status.ts',
  'src/core/chain/errors.ts',
  'src/core/daemon/link-copy.ts',
  'src/core/nodes/recent-order.ts',
  'src/core/session/coverage.ts',
  'src/core/session/device-limit.ts',
  'src/core/session/open-deposit.ts',
  'src/core/session/refund-copy.ts',
  'src/core/session/setup-gate.ts',
  'src/core/session/state.ts',
  'src/core/settlement/auto-refund.ts',
  'src/shared/format.ts',
  'src/shared/money-toast.ts',
  'src/shared/prepay-cap.ts',
  'src/shared/os-words.ts',
  'vitest.config.ts',
  'src/main/logger.ts',
  'src/main/services/daemon-apply.ts',
  'src/main/services/service-transition.ts',
  'tests/unit/service-transition.test.ts',
  'src/renderer/src/lib/use-daemon-settings.ts',
  'src/core/daemon/draft.ts',
  'src/cli/daemon-cmd.ts',
  'src/main/ipc.ts',
  'tests/unit/settings-apply-parity.test.ts',
  'tests/unit/daemon-apply.test.ts',
  'tests/unit/draft-shared.test.ts',
  'src/shared/types.ts',
  'src/main/scheduler.ts',
  'src/main/runtime.ts',
  'src/main/app-state.ts',
  'src/main/services/connect-checks.ts',
  'src/main/services/connection.ts',
  'src/main/services/history.ts',
  'src/main/services/settlement.ts',
  'src/main/services/wallet.ts',
  'src/cli/commands.ts',
  'src/cli/test-cmd.ts',
  'src/renderer/src/App.tsx',
  'src/renderer/src/components/ConnectSheet.tsx',
  'src/renderer/src/components/ErrorBoundary.tsx',
  'src/renderer/src/components/ui.tsx',
  'src/renderer/src/screens/Activity.tsx',
  'src/renderer/src/screens/Cli.tsx',
  'src/renderer/src/screens/Diagnostics.tsx',
  'src/renderer/src/screens/Home.tsx',
  'src/renderer/src/screens/KillSwitch.tsx',
  'src/renderer/src/screens/NodeTest.tsx',
  'src/renderer/src/screens/Nodes.tsx',
  'src/renderer/src/screens/Onboarding.tsx',
  'src/renderer/src/screens/Plans.tsx',
  'src/renderer/src/screens/Settings.tsx',
  'src/renderer/src/screens/SplitTunnel.tsx',
  'src/renderer/src/screens/Wallet.tsx',
  'src/renderer/src/styles/index.css',
  'tests/unit/auto-refund.test.ts',
  'tests/unit/coverage.test.ts',
  'tests/unit/device-limit.test.ts',
  'tests/unit/first-connect-permission.test.ts',
  'tests/unit/money-toast.test.ts',
  'tests/unit/open-deposit.test.ts',
  'tests/unit/other-device.test.ts',
  'tests/unit/page-subtitles.test.ts',
  'tests/unit/plan-cards.test.ts',
  'tests/unit/plan-dialog.test.ts',
  'tests/unit/recent-order.test.ts',
  'tests/unit/refund-copy.test.ts',
  'tests/unit/rpc-busy-start.test.ts',
  'tests/unit/settle-reuse.test.ts',
  'tests/unit/setup-gate.test.ts',
  'tests/unit/ui-polish.test.ts',
  'tests/unit/wallet-switch-ux.test.ts',
];

// ─── Never compared: each OS writes its own ───
const PLATFORM = [
  // OS seams: elevate, tunnels, drivers, apps, browser, autostart, proxy. settings.ts is NOT a seam:
  // its sanitizer decides which settings survive a write, and a port that missed one line of it
  // silently dropped a setting on three systems.
  /^src\/main\/system\/(?!settings\.ts$)/,
  /^src\/main\/daemon\//,
  /^src\/cli\/keystore\.ts$/,
  /^src\/main\/wallet\/electron-keystore\.ts$/,
  /^src\/main\/dev\/ui-scenario\.ts$/,
  /^tests\/platform\//,
  /^tests\/unit\/android-platform[^/]*\.test\.ts$/, // imports #34's drivers/manager platform bits
  /^src\/main\/index\.ts$/,
  /^resources\//,
  /^tools\//,
  /^scripts\/e2e\//,
  /^docs\//,
  /^memory\//,
];

// ─── Per-repo allow-list: a listed shared file that may differ, with the reason. Keep it short. ───
// Add an entry only with a reason and a row in docs/PORT-2026-11-12.md; empty = fully uniform.
const ALLOW = {
  linux: {},
  mac: {},
  android: {
    // Android has no service install; e569565's UAC branch and the pipe grant do not apply.
  },
};

// Every source folder. A file under these is shared unless PLATFORM or the repo's exceptions say otherwise.
const SHARED_DIRS = ['src', 'tests/unit'];

// ─── --strict: every file under SHARED_DIRS must be identical, or be listed with a reason ───
// Each clone may carry PLATFORM-EXCEPTIONS.txt at its root: one `path | reason` per line, # = comment.
// A line without a reason is ignored, so a difference can never be waved through silently.
function exceptions(dir) {
  const p = join(dir, 'PLATFORM-EXCEPTIONS.txt');
  const out = {};
  if (!existsSync(p)) return out;
  for (const line of readFileSync(p, 'utf8').split(/\r?\n/)) {
    if (!line.trim() || line.trim().startsWith('#')) continue;
    const [path, ...why] = line.split('|');
    const reason = why.join('|').trim();
    if (path.trim() && reason) out[path.trim()] = reason;
  }
  return out;
}

const hash = (p) => createHash('sha256').update(readFileSync(p)).digest('hex').slice(0, 12);

function walk(dir, out = []) {
  if (!existsSync(dir)) return out;
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else out.push(relative(ROOT, p).split('\\').join('/'));
  }
  return out;
}

const args = process.argv.slice(2);
const all = args.includes('--all');
const only = args.includes('--repo') ? args[args.indexOf('--repo') + 1] : null;
const strict = args.includes('--strict');
const files = all || strict ? SHARED_DIRS.flatMap((d) => walk(join(ROOT, d))) : SHARED;
const repos = Object.entries(REPOS).filter(([k]) => !only || k === only);
// A gate that checked nothing must never say OK: an unknown --repo is a usage error.
if (!repos.length) {
  console.error(`parity: unknown --repo "${only ?? ''}"; use one of: ${Object.keys(REPOS).join(', ')}`);
  process.exit(2);
}

let bad = 0;
for (const [name, dir] of repos) {
  if (!existsSync(dir)) { console.log(`${name}: repo not found at ${dir}`); bad++; continue; }
  const diffs = [];
  const listed = strict ? exceptions(dir) : {};
  for (const f of files) {
    if (PLATFORM.some((r) => r.test(f))) continue;
    const src = join(ROOT, f);
    if (!existsSync(src)) { diffs.push(`  ${f}: missing in #31 (stale list?)`); continue; }
    const dst = join(dir, f);
    const allowed = ALLOW[name]?.[f] ?? listed[f];
    let differs = false;
    if (!existsSync(dst)) { differs = true; diffs.push(`  ${f}: MISSING${allowed ? ` (allowed: ${allowed})` : ''}`); }
    else if (hash(src) !== hash(dst)) { differs = true; diffs.push(`  ${f}: DIFFERS ${hash(src)} vs ${hash(dst)}${allowed ? ` (allowed: ${allowed})` : ''}`); }
    if (differs && !allowed && (strict || !all)) bad++;
  }
  console.log(`${name}: ${diffs.length ? `${diffs.length} difference(s)` : 'identical'} (${files.length} files checked${all && !strict ? ', --all is informational' : ''})`);
  for (const d of diffs) console.log(d);
}
console.log(bad ? `PARITY FAIL: ${bad} shared file(s) differ outside the allow-list` : 'PARITY OK');
process.exit(bad ? 1 : 0);
