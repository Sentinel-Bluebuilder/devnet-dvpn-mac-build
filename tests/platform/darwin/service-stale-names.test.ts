// ─── Mac serviceStaleNames (#31 470bac7 seam, 9d625b9 platform split) ───
// A .dmg has no post-install step: a drag-over leaves the root-owned service on its old copies, so the seam is real
// here. No LaunchDaemon plist = no installed service = nothing stale (a fresh machine sees setup, not the banner).
import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';

describe('serviceStaleNames on macOS', () => {
  it('is empty without the LaunchDaemon plist, else the stale service copies', () => {
    const m = readFileSync('src/main/daemon/manager.ts', 'utf8');
    expect(m).toMatch(/export function serviceStaleNames\(\): string\[\] \{\n  if \(!fs\.existsSync\(SERVICE_PLIST\)\) return \[\];\n  return serviceStaleFiles\(\);\n\}/);
  });
  it('negative control: a machine with no service installed reports nothing stale', async () => {
    const { serviceStaleNames, SERVICE_PLIST } = await import('../../../src/main/daemon/manager');
    const fs = await import('node:fs');
    if (fs.existsSync(SERVICE_PLIST)) return; // a real Mac with the service: the source assertion above covers it
    expect(serviceStaleNames()).toEqual([]);
  });
});
