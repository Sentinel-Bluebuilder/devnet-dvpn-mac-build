// ─── Every app setting survives sanitize() (E-19, AC-WIN; macOS rc2 dropped autoDevicePermission) ───
// rc2's src/main/system/settings.ts (a platform file, so scripts/parity.mjs never compared it) had no
// `out.autoDevicePermission = bool(...)`: every write of it was dropped, `device revoke`'s included, so after a revoke
// the app could set the device up again. This pins every AppSettings key: read by sanitize(), and a changed boolean kept.
import fs from 'node:fs';
import { describe, it, expect, vi } from 'vitest';

vi.mock('../../../src/main/store', () => ({ readJson: () => null, writeJson: vi.fn() }));

const { sanitize } = await import('../../../src/main/system/settings');
const { DEFAULT_SETTINGS } = await import('../../../src/shared/types');

const SRC = 'src/main/system/settings.ts';
const keysReadBy = (src: string): string[] => Object.keys(DEFAULT_SETTINGS).filter((k) => new RegExp(`\\binput\\.${k}\\b`).test(src));

describe('sanitize() keeps every app setting', () => {
  it('reads every key of DEFAULT_SETTINGS (a new setting must be handled here)', () => {
    expect(Object.keys(DEFAULT_SETTINGS).filter((k) => !keysReadBy(fs.readFileSync(SRC, 'utf8')).includes(k))).toEqual([]);
  });

  it('negative control: the rc2 sanitize without the autoDevicePermission line fails the check', () => {
    const rc2 = fs.readFileSync(SRC, 'utf8').replace(/^.*out\.autoDevicePermission = .*$/m, '');
    expect(Object.keys(DEFAULT_SETTINGS).filter((k) => !keysReadBy(rc2).includes(k))).toEqual(['autoDevicePermission']);
  });

  it('autoDevicePermission: false is stored, and true again after it', () => {
    const off = sanitize({ autoDevicePermission: false });
    expect(off.autoDevicePermission).toBe(false);
    expect(sanitize({ autoDevicePermission: true }, off).autoDevicePermission).toBe(true);
    expect(sanitize({ autoDevicePermission: 'false' as unknown as boolean }, off).autoDevicePermission).toBe(false); // not a boolean: kept
  });

  it('every boolean setting keeps a flipped value', () => {
    const bools = Object.entries(DEFAULT_SETTINGS).filter(([, v]) => typeof v === 'boolean').map(([k]) => k);
    expect(bools).toContain('autoDevicePermission');
    for (const k of bools) {
      const flipped = !(DEFAULT_SETTINGS as unknown as Record<string, boolean>)[k];
      expect([k, (sanitize({ [k]: flipped }) as unknown as Record<string, boolean>)[k]]).toEqual([k, flipped]);
    }
  });
});
