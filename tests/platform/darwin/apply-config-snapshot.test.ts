// ─── apply-daemon-config.sh reads only a root-owned snapshot of the staged files (AC-MAC-1 P2-2) — macOS ───
// The staged folder is the user's. The old step checked `[ ! -L src ]`, then stopped the service (up to 30 s)
// and only then `cat src` into the daemon config: a file swapped for a link in that window put a root-only
// file into config.toml, which carries the setup user's read ACE. Now each staged file is copied with
// `cp -RP` (a link stays a link) into a root-owned folder first, a link is refused, and only the snapshot
// is ever read again.
import fs from 'node:fs';
import { describe, expect, it } from 'vitest';

const src = fs.readFileSync('resources/scripts/apply-daemon-config.sh', 'utf8');
const lines = src.split('\n');
const at = (re: RegExp): number => lines.findIndex((l) => re.test(l) && !/^\s*#/.test(l));

describe('apply-daemon-config.sh staged snapshot', () => {
  it('snapshots every staged file with cp -RP into a root-owned folder before the service stops', () => {
    const snap = at(/cp -RP -- "\$\{SRC\[\$i\]\}" "\$snap\//);
    expect(snap).toBeGreaterThan(-1);
    expect(at(/mktemp -d "\$HOME_DIR\/\.staged\./)).toBeLessThan(snap);
    expect(snap).toBeLessThan(at(/\[ \$has_svc = 1 \] && svc_stop/));
  });

  it('refuses a snapshot that is a link and writes only from the snapshot', () => {
    expect(at(/\[ -L "\$snap\/\$i" \]/)).toBeGreaterThan(-1);
    expect(at(/atomic_write "\$snap\/\$i" "\$\{DST\[\$i\]\}"/)).toBeGreaterThan(-1);
    expect(at(/atomic_write "\$\{SRC\[\$i\]\}"/)).toBe(-1);
  });

  it('negative control: the rollback still restores the .bak copies', () => {
    expect(at(/atomic_write "\$\{DST\[\$i\]\}\.bak" "\$\{DST\[\$i\]\}"/)).toBeGreaterThan(-1);
  });
});
