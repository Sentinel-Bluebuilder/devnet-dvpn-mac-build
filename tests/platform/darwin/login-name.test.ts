// ─── The account that gets the service socket (Q0572, Mac upgrade test 11-14) ───
// An app started through `sudo -u <user>` from a root shell carries SUDO_USER=root. loginName() used to return '' then,
// so setup passed no User and the account got no group membership or socket ACL. It must fall back to USER / LOGNAME.
import { describe, expect, it, vi } from 'vitest';

vi.mock('electron', () => ({ app: { getPath: () => '/tmp', isPackaged: false }, safeStorage: {} }));

import { loginName } from '../../../src/main/daemon/manager';

describe('loginName', () => {
  it('prefers SUDO_USER when it is a real user', () => {
    expect(loginName({ SUDO_USER: 'zoe', USER: 'root', LOGNAME: 'root' })).toBe('zoe');
  });

  it('falls back to USER when SUDO_USER is root (Q0572)', () => {
    expect(loginName({ SUDO_USER: 'root', USER: 'ddvup', LOGNAME: 'ddvup' })).toBe('ddvup');
  });

  it('falls back to LOGNAME when SUDO_USER and USER are root or invalid', () => {
    expect(loginName({ SUDO_USER: 'root', USER: 'bad name', LOGNAME: 'Zoe.Lee' })).toBe('Zoe.Lee');
  });

  it('a plain desktop launch uses USER', () => {
    expect(loginName({ USER: 'zoe', LOGNAME: 'zoe' })).toBe('zoe');
  });

  it('negative control: only root or nothing gives no one', () => {
    expect(loginName({ SUDO_USER: 'root', USER: 'root', LOGNAME: 'root' })).toBe('');
    expect(loginName({})).toBe('');
    expect(loginName({ USER: '-rf', LOGNAME: 'a;b' })).toBe('');
  });
});
