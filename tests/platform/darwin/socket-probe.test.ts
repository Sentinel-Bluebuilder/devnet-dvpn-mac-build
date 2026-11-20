// Q0484 H1 (guest, 11-12): a second macOS account (not in the sentinel-dvpn group) cannot enter the
// root-owned service folder. existsSync() said "no socket", so the app and CLI said "The VPN service is
// not running" while it ran, and Connect never offered the one-prompt grant. EACCES now reads as refused.
import { describe, expect, it, vi } from 'vitest';

vi.mock('../../../src/main/logger', () => ({ log: { info: vi.fn(), warn: vi.fn(), error: vi.fn(), debug: vi.fn() } }));

const { socketProbe } = await import('../../../src/main/daemon/manager');
const fail = (code: string) => () => { throw Object.assign(new Error(code), { code }); };

describe('socketProbe', () => {
  it('a socket in a folder this account may not enter is "denied", not missing', () => {
    expect(socketProbe('/x/daemon.sock', fail('EACCES'))).toBe('denied');
    expect(socketProbe('/x/daemon.sock', fail('EPERM'))).toBe('denied');
  });
  it('negative control: no socket at all is "missing"; a readable one is "present"', () => {
    expect(socketProbe('/x/daemon.sock', fail('ENOENT'))).toBe('missing');
    expect(socketProbe('/x/daemon.sock', fail('ENOTDIR'))).toBe('missing');
    expect(socketProbe('/x/daemon.sock', () => ({}))).toBe('present');
  });
});
