// ─── doctor judges the protocol copies the service runs, not the app bundle (Q0508 guest T1) — macOS ───
import path from 'node:path';
import { describe, expect, it, vi } from 'vitest';

vi.mock('../../../src/main/logger', () => ({ log: { info: vi.fn(), warn: vi.fn(), error: vi.fn(), debug: vi.fn() } }));

const { doctorProtocolDirs } = await import('../../../src/main/daemon/manager');
const BUNDLE = ['/Applications/Devnet dVPN.app/Contents/Resources/resources/bin/v2ray'];

describe('doctorProtocolDirs', () => {
  it('installed: the root-owned /Library/devnet-dvpn copies, never /Applications', () => {
    const lib = '/Library/devnet-dvpn';
    const dirs = doctorProtocolDirs(lib, BUNDLE, () => true);
    expect(dirs).toEqual(['v2ray', 'xray', 'hysteria2'].map((d) => path.join(lib, d)));
    expect(dirs.some((d) => d.startsWith('/Applications'))).toBe(false);
  });

  it('negative control: not installed yet, the bundle copies are what there is', () => {
    expect(doctorProtocolDirs('/Library/devnet-dvpn', BUNDLE, () => false)).toEqual(BUNDLE);
  });

  it('only the protocols the service has', () => {
    const dirs = doctorProtocolDirs('/L', BUNDLE, (p) => p.endsWith('xray'));
    expect(dirs).toEqual([path.join('/L', 'xray')]);
  });
});
