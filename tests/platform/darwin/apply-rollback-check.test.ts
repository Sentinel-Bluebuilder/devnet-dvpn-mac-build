// ─── AUDIT-FINAL-MACOS M2: apply-daemon-config.sh checks the rollback start and says the service's state — macOS ───
import fs from 'node:fs';
import { describe, expect, it } from 'vitest';

const src = fs.readFileSync('resources/scripts/apply-daemon-config.sh', 'utf8');
const lines = src.split('\n').filter((l) => !/^\s*#/.test(l));
const idx = (re: RegExp): number => lines.findIndex((l) => re.test(l));

describe('apply-daemon-config.sh rollback', () => {
  it('the rollback start is no longer a bare "svc_stop; svc_start" left unchecked', () => {
    expect(idx(/^\s*svc_stop; svc_start\s*$/)).toBe(-1);
  });
  it('after the rollback it waits for the socket + running, then names running or NOT running with a next', () => {
    const restore = idx(/atomic_write "\$\{DST\[\$i\]\}\.bak"/);
    const wait = lines.findIndex((l, i) => i > restore && /daemon\.sock.*svc_running.*back=1/.test(l));
    expect(restore).toBeGreaterThan(-1);
    expect(wait).toBeGreaterThan(restore);
    expect(src).toMatch(/service is running again/);
    expect(src).toMatch(/service is NOT running .*Next: devnet-dvpn daemon doctor, then sudo launchctl kickstart -k system\/\$LABEL/);
  });
  it('negative control: the success path still writes "applied and restarted"', () => {
    expect(src).toMatch(/write_result ok 'applied and restarted'/);
  });
});
