// ─── The notices call "bundled" only what the packages carry (I-17b, RC10-WORK-ORDER row 81) ───
// THIRD-PARTY-NOTICES.md and README.md listed wireguard-tools, OpenVPN, GNU Bash and AmneziaWG as
// bundled, with a GPL written offer, while build/deps.lock.json ships none of them (Repair drivers
// installs them from Homebrew). Every program those pages call bundled must be a deps.lock entry.
import fs from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';

const ROOT = path.join(__dirname, '../../..');
const read = (f: string): string => fs.readFileSync(path.join(ROOT, f), 'utf8');
const lock = JSON.parse(read('build/deps.lock.json')) as {
  deps: { name: string }[];
  local: { name: string }[];
};
const LOCKED = new Set([...lock.deps, ...lock.local].map((d) => d.name));

// Every program a page may name, by the deps.lock name it would need.
const PROGRAMS: { re: RegExp; lockName: string }[] = [
  { re: /sentinel-dvpnd/i, lockName: 'dvpnd' },
  { re: /xray/i, lockName: 'xray' },
  { re: /hysteria/i, lockName: 'hysteria2' },
  { re: /v2ray/i, lockName: 'v2ray' },
  { re: /wireguard-tools|`wg`|wg-quick/i, lockName: 'wg' },
  { re: /wireguard-go/i, lockName: 'wireguard-go' },
  { re: /openvpn/i, lockName: 'openvpn' },
  { re: /\bbash\b/i, lockName: 'bash' },
  { re: /amneziawg|`awg`|awg-quick/i, lockName: 'awg' },
];

const notices = read('THIRD-PARTY-NOTICES.md');
const readme = read('README.md');

// The tables under a "(bundled binaries)" heading: their first cells.
const bundledRows = (md: string): string[] => {
  const out: string[] = [];
  let inBundled = false;
  for (const line of md.split('\n')) {
    if (line.startsWith('#')) { inBundled = /bundled binaries/i.test(line); continue; }
    if (!inBundled || !line.startsWith('|') || /^\|\s*-/.test(line)) continue;
    const first = line.split('|')[1]?.trim() ?? '';
    if (first && !/^(component|font|package)$/i.test(first)) out.push(first);
  }
  return out;
};

const unlocked = (text: string): string[] =>
  PROGRAMS.filter((p) => p.re.test(text) && !LOCKED.has(p.lockName)).map((p) => p.lockName);

describe('THIRD-PARTY-NOTICES.md bundles only deps.lock entries', () => {
  it('has bundled-binary rows to check (control)', () => {
    expect(bundledRows(notices).length).toBeGreaterThan(0);
  });

  it('every bundled-binary row is in deps.lock', () => {
    const bad = bundledRows(notices).filter((r) => {
      const hit = PROGRAMS.find((p) => p.re.test(r));
      return hit ? !LOCKED.has(hit.lockName) : !/geoip|geosite/i.test(r);
    });
    expect(bad).toEqual([]);
  });

  it('carries a GPL written offer only when deps.lock ships a GPL program', () => {
    const offer = /^## Written offer/m.test(notices);
    const gplLocked = ['wg', 'openvpn', 'bash', 'awg'].some((n) => LOCKED.has(n));
    expect(offer).toBe(gplLocked);
  });
});

describe('README.md bundles only deps.lock entries', () => {
  it('the "bundle third-party software" sentence names only deps.lock programs', () => {
    const m = readme.match(/packages bundle third-party software[^.]*\./s);
    expect(m, 'the bundle sentence is missing').not.toBeNull();
    expect(unlocked(m![0])).toEqual([]);
  });

  it('does not promise a written offer the package does not carry', () => {
    const gplLocked = ['wg', 'openvpn', 'bash', 'awg'].some((n) => LOCKED.has(n));
    if (!gplLocked) expect(readme).not.toMatch(/written offer/i);
  });
});

describe('the Xray patch is in the source tree (MPL-2.0 modified file)', () => {
  it('docs/patches/xray-0001-darwin-find-process.patch exists when xray is a local build', () => {
    if (lock.local.some((l) => l.name === 'xray')) {
      expect(fs.existsSync(path.join(ROOT, 'docs/patches/xray-0001-darwin-find-process.patch'))).toBe(true);
    }
  });
});
