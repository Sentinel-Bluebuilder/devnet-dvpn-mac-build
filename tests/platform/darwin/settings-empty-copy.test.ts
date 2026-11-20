// ─── Q0544 (Mac): an empty service config is never read as "no settings"; root writes are atomic ───
// DVPN-LINUX hunt1: a spot preemption cut a root write in place; the copy stayed 0 bytes. `daemon set
// --kill-switch on` then said "Basis must be per_gb or per_hour." and Apply never finished. On macOS the app reads
// <instance>/config.toml itself, and apply-daemon-config.sh / migrate-daemon-config.sh wrote it in place
// (`cat src > dst`): the same cut (power loss mid-apply) must give the same plain refusal, and the scripts now
// write through atomic_write (temp in the same folder, cp -p for owner/mode/ACL, rename).
import { afterAll, describe, expect, it, vi } from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dvpn-q0544-'));
vi.mock('../../../src/main/daemon/manager', () => ({
  DEFAULT_DAEMON_HOME: dir, SERVICE_NAME: 'x', daemonInfo: () => ({ reachable: true, version: null }),
  deviceRecord: () => ({ home: dir }), relinkDaemon: vi.fn(), scriptPath: () => 'x',
}));
vi.mock('../../../src/main/system/elevate', () => ({ runElevated: vi.fn(async () => { throw new Error('must not elevate'); }) }));
vi.mock('../../../src/main/host', () => ({ getHost: () => ({ dataDir: dir }) }));
vi.mock('../../../src/main/logger', () => ({ log: { warn: vi.fn(), info: vi.fn(), error: vi.fn(), debug: vi.fn() } }));

const { getDaemonSettings, applyDaemonSettings, EMPTY_SETTINGS_COPY } = await import('../../../src/main/daemon/settings');
afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

describe('an empty service config (Q0544, macOS)', () => {
  it('reads as empty and unreadable, never as a config with no settings', () => {
    fs.writeFileSync(path.join(dir, 'config.toml'), '  \n');
    const s = getDaemonSettings();
    expect(s.readable).toBe(false);
    expect(s.empty).toBe(true);
    expect(s.settings).toEqual({});
  });
  it('Apply refuses it with plain words before validating or elevating', async () => {
    fs.writeFileSync(path.join(dir, 'config.toml'), '');
    const r = await applyDaemonSettings({ killSwitch: 'on' } as never);
    expect(r).toEqual({ ok: false, error: EMPTY_SETTINGS_COPY });
    expect(r.error).not.toMatch(/Basis must be/);
  });
  it('negative control: a missing config is "missing", not "empty"', () => {
    fs.rmSync(path.join(dir, 'config.toml'), { force: true });
    const s = getDaemonSettings();
    expect(s.empty).toBeUndefined();
    expect(s.missing).toBe(true);
  });
  it('uses the same words as #31/#32', () => {
    expect(EMPTY_SETTINGS_COPY).toMatch(/^The copy of the VPN service settings this app reads is empty \(the computer stopped while it was being written\)\./);
  });
  it('root scripts write config.toml through atomic_write, never in place', () => {
    const rd = (f: string): string => fs.readFileSync(path.join('resources/scripts', f), 'utf8');
    expect(rd('_lib.sh')).toMatch(/atomic_write\(\) \{[\s\S]*cp -p "\$dst" "\$tmp"[\s\S]*mv -f "\$tmp" "\$dst"/);
    const apply = rd('apply-daemon-config.sh');
    expect(apply).toContain('atomic_write "$snap/$i" "${DST[$i]}"');
    expect(apply).toContain('atomic_write "${DST[$i]}.bak" "${DST[$i]}"');
    expect(apply).not.toMatch(/cat "\$\{(SRC|DST)\[\$i\]\}(\.bak)?" > "\$\{DST/);
    expect(rd('migrate-daemon-config.sh')).toContain('atomic_write "$tmp" "$f"');
    expect(rd('migrate-daemon-config.sh')).not.toMatch(/cat "\$tmp" > "\$f"/);
  });
});
