// ─── `daemon drivers` on macOS: a missing driver names the servers it affects (#31 tests/unit/cli-drivers-tail) ───
// The shared copy pins Windows' labels (DRIVER_LABELS lives in the platform file src/main/system/drivers.ts); this
// is the same check with the macOS labels. The tail logic itself (src/cli/daemon-cmd.ts) is the shared file.
import { describe, it, expect } from 'vitest';
import { driversMissingTail } from '../../../src/cli/daemon-cmd';

const report = (rows: [string, string][]) => ({ at: '', ok: false, rebootRequired: false, deps: rows.map(([name, status]) => ({ name, status })) }) as never;

describe('driversMissingTail (macOS labels)', () => {
  it('only AmneziaWG missing: says only AmneziaWG servers need it', () => {
    expect(driversMissingTail(report([['wireguard', 'present'], ['amneziawg', 'missing'], ['openvpn', 'installed']])))
      .toBe('Some drivers are missing: AmneziaWG (userspace). Only AmneziaWG servers need it; the others work now. To fix it: "daemon repair-drivers --yes".');
  });
  it('two protocols joined with "and"', () => {
    expect(driversMissingTail(report([['wireguard', 'missing'], ['amneziawg', 'missing']])))
      .toContain('Only WireGuard and AmneziaWG servers need it');
  });
  it('negative control: a row that is not a protocol driver (the macOS version) blocks everything', () => {
    expect(driversMissingTail(report([['macos', 'incompatible'], ['amneziawg', 'missing']])))
      .toBe('Some drivers are missing: macOS 12 or newer, AmneziaWG (userspace). No server can be used until it is fixed: run "daemon repair-drivers --yes".');
  });
});
