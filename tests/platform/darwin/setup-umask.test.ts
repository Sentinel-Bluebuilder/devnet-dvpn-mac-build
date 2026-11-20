// ─── setup-daemon.sh pins umask 022 before it writes anything (Q0508 guest, 11-12) — macOS ───
// The admin step inherits the caller's umask; under 077 the CLI link came out lrwx------ and the
// user's `devnet-dvpn` said "the app is not at /".
import fs from 'node:fs';
import { describe, expect, it } from 'vitest';

const src = fs.readFileSync('resources/scripts/setup-daemon.sh', 'utf8');
const lines = src.split('\n');
const at = (re: RegExp): number => lines.findIndex((l) => re.test(l) && !/^\s*#/.test(l));

describe('setup-daemon.sh umask', () => {
  it('sets umask 022 before the first install, copy or CLI link', () => {
    const umask = at(/^\s*umask 022\s*$/);
    expect(umask).toBeGreaterThan(-1);
    for (const re of [/\binstall -/, /\bcp -R/, /\bln -sf\b/, /\bmkdir\b/]) {
      const first = at(re);
      if (first > -1) expect(first).toBeGreaterThan(umask);
    }
  });

  it('negative control: the CLI link is still made with ln -sf to /usr/local/bin', () => {
    expect(at(/ln -sf "\$CLI" \/usr\/local\/bin\/devnet-dvpn/)).toBeGreaterThan(-1);
  });
});
