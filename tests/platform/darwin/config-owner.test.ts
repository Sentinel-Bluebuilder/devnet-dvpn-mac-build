// ─── E-ST owner (#38 rc.9 blocker, macOS twin of the Windows wallet-switch bug) ───
// The service was set up for owner A; a fresh data dir loads wallet B and E-ST adopts the service's device key (the
// same key). The re-install kept the home, so config.toml still said owner = A and dvpnd checked A's grant: wallet B
// never ran. Now the install step passes --Owner (the wallet recorded for the device) and the kept home is set to it.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import { adoptInstalledDevice, type AdoptDeps } from '../../../src/main/daemon/manager';

const A = '9enW4xCJ6pQwq7Yb3NzfL1kRtUvXy2Hs4M8dA5BcDeFg';
const B = 'FD64HCu5KCyPozf1on1r6GQj4PLLoWo69BQMMzoMo9zr';
const lib = path.resolve('resources/scripts/_lib.sh');
const read = (f: string): string => fs.readFileSync(`resources/scripts/${f}`, 'utf8');
const code = (s: string): string => s.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');

function setOwner(file: string, owner: string): { out: string; code: number } {
  try {
    return { out: execFileSync('/bin/bash', ['-c', `source "${lib}"; set_config_owner "$1" "$2"`, 'x', file, owner], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim(), code: 0 };
  } catch (err) {
    return { out: String((err as { stdout?: string }).stdout ?? '').trim(), code: (err as { status?: number }).status ?? 1 };
  }
}
function home(text: string): { dir: string; file: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'owner-'));
  const file = path.join(dir, 'config.toml');
  fs.writeFileSync(file, text);
  return { dir, file };
}
const CONFIG = (o: string): string => `instance = "c0"\nowner = "${o}"\nrpc = ["https://api.devnet.solana.com"]\n\n[provider]\nowner = "${A}"\n`;

describe('set_config_owner (setup-daemon.sh, a kept service home)', () => {
  it('owner A, wallet B, same key: the top-level owner becomes B; a [section] owner and the rest stay', () => {
    const h = home(CONFIG(A));
    expect(setOwner(h.file, B)).toEqual({ out: 'changed', code: 0 });
    expect(fs.readFileSync(h.file, 'utf8')).toBe(`instance = "c0"\nowner = "${B}"\nrpc = ["https://api.devnet.solana.com"]\n\n[provider]\nowner = "${A}"\n`);
    expect(fs.readdirSync(h.dir)).toEqual(['config.toml']); // no temp file left
    fs.rmSync(h.dir, { recursive: true, force: true });
  });
  it('negative control: already the owner -> same, the file is untouched', () => {
    const h = home(CONFIG(B));
    const before = fs.readFileSync(h.file, 'utf8');
    expect(setOwner(h.file, B)).toEqual({ out: 'same', code: 0 });
    expect(fs.readFileSync(h.file, 'utf8')).toBe(before);
    fs.rmSync(h.dir, { recursive: true, force: true });
  });
  it('refuses a value that is not an address (exit 2) and a config that is a link; nothing changes', () => {
    const h = home(CONFIG(A));
    expect(setOwner(h.file, 'B"; rm -rf /').code).toBe(2);
    expect(fs.readFileSync(h.file, 'utf8')).toBe(CONFIG(A));
    const link = path.join(h.dir, 'link.toml');
    fs.symlinkSync(h.file, link);
    expect(setOwner(link, B).code).toBe(2);
    expect(fs.readFileSync(h.file, 'utf8')).toBe(CONFIG(A));
    fs.rmSync(h.dir, { recursive: true, force: true });
  });
});

describe('the install path passes the owner', () => {
  it('setup-daemon.sh sets it on the kept home after the cb33 migrate and before root owns + locks the home', () => {
    const s = code(read('setup-daemon.sh'));
    const at = s.indexOf('set_config_owner "$HOME_DIR/config.toml" "$ARG_Owner"');
    expect(at).toBeGreaterThan(s.indexOf('migrate-daemon-config.sh'));
    expect(at).toBeLessThan(s.indexOf('chown -R root:"$GROUP" "$DAEMON_ROOT"'));
    expect(s).toMatch(/\|\| die "could not set the service owner to \$ARG_Owner"/);
  });
  it('manager.ts: installService passes Owner = the recorded owner; an adopted key makes an install pending', () => {
    const m = fs.readFileSync('src/main/daemon/manager.ts', 'utf8');
    expect(m).toMatch(/Owner: rec\.owner,/);
    expect(m).toMatch(/fs\.existsSync\(path\.join\(stagingHome\(\), 'config\.toml'\)\) \|\| ownerPending\(\) !== null/);
  });
  it('adoptInstalledDevice for wallet B records B and marks the service owner pending for B', async () => {
    const mark = vi.fn();
    const deps: AdoptDeps = { record: () => null, home: '/h', has: () => true, detect: async () => ({ ok: true, device: 'SvcKey' }), register: vi.fn(), markOwnerPending: mark };
    expect(await adoptInstalledDevice(B, deps)).toBe('SvcKey');
    expect(deps.register).toHaveBeenCalledWith('SvcKey', B, '/h');
    expect(mark).toHaveBeenCalledWith(B);
  });
});
