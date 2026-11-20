// ─── Q0507: a fresh install starts with the kill switch off; an upgrade keeps the user's value — macOS ───
// dvpnd init writes kill_switch = 'on' and setup-daemon.sh's migration turns it into 'persist' ("Always").
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, it, vi } from 'vitest';

vi.mock('../../../src/main/logger', () => ({ log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() } }));

import { killSwitchOffByDefault } from '../../../src/main/daemon/manager';

const INIT = "[network]\nallow_lan = false\nkill_switch = 'on'\n\n[split]\nmode = ''\n";

const mk = (root: string, files: Record<string, string>): void => {
  for (const [f, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(root, f)), { recursive: true });
    fs.writeFileSync(path.join(root, f), text);
  }
};
const ks = (root: string): string => /kill_switch = '([a-z]+)'/.exec(fs.readFileSync(path.join(root, 'config.toml'), 'utf8'))?.[1] ?? '';

// every case injects the installed + pre-cb33 homes: never read the machine's real ones
function dirs(): { staging: string; live: string; legacy: string } {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'ddv-ks-'));
  return { staging: path.join(d, 'staging'), live: path.join(d, 'live'), legacy: path.join(d, 'legacy') };
}

describe('kill switch on a fresh install (Q0507)', () => {
  it('a fresh install writes off, not the init default on (which the migration makes persist)', () => {
    const { staging, live, legacy } = dirs();
    mk(staging, { 'config.toml': INIT });
    killSwitchOffByDefault(staging, live, legacy);
    expect(ks(staging)).toBe('off');
    expect(fs.readFileSync(path.join(staging, 'config.toml'), 'utf8')).toContain('[split]');
  });

  it('negative control: an upgrade over an installed home leaves the carried value alone', () => {
    const { staging, live, legacy } = dirs();
    mk(staging, { 'config.toml': INIT.replace("'on'", "'persist'") });
    mk(live, { 'config.toml': "[network]\nkill_switch = 'persist'\n" });
    killSwitchOffByDefault(staging, live, legacy);
    expect(ks(staging)).toBe('persist');
  });

  it('a first cb33 install over a pre-cb33 home keeps its value too', () => {
    const { staging, live, legacy } = dirs();
    mk(staging, { 'config.toml': INIT });
    mk(legacy, { 'config.toml': "[network]\nkill_switch = 'on'\n" });
    killSwitchOffByDefault(staging, live, legacy);
    expect(ks(staging)).toBe('on');
  });

  it('runs after the settings carry in initDevice', () => {
    const src = fs.readFileSync('src/main/daemon/manager.ts', 'utf8');
    expect(src).toContain('carryLiveSettings(staging);\n        wholeDeviceByDefault(staging);\n        killSwitchOffByDefault(staging);');
  });
});
