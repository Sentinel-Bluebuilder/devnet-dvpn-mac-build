// ─── setup-daemon.sh never lets a link from the user's staging folder steer a root write (AC-MAC-1 P2-1) — macOS ───
// The staging home is user-writable. `cp -Rp` keeps symlinks, and root then wrote `device.pub` with `>`
// + `chmod` and migrate-daemon-config.sh read/replaced `config.toml`: both follow a link, so a planted
// `device.pub -> /etc/…` clobbered a root file and `config.toml -> /etc/…` copied a root-only file into
// the home with the setup user's read ACE. The copy now lands in a root-owned folder first, is refused
// when it holds any link, and device.pub is unlinked before it is written.
import fs from 'node:fs';
import { describe, expect, it } from 'vitest';

const src = fs.readFileSync('resources/scripts/setup-daemon.sh', 'utf8');
const lines = src.split('\n');
const at = (re: RegExp): number => lines.findIndex((l) => re.test(l) && !/^\s*#/.test(l));

describe('setup-daemon.sh staging links', () => {
  it('refuses a staged copy that holds a symlink, before it reaches the home', () => {
    const check = at(/find "\$copy" -type l/);
    expect(check).toBeGreaterThan(-1);
    expect(at(/cp -Rp "\$STAGING\/\." "\$copy\/"/)).toBeLessThan(check);
    expect(at(/cp -Rp "\$copy\/\." "\$HOME_DIR\/"/)).toBeGreaterThan(check);
  });

  it('no root copy goes straight from staging into the home', () => {
    expect(at(/cp -Rp "\$STAGING\/\." "\$HOME_DIR\/"/)).toBe(-1);
  });

  it('the link check runs before the config migration', () => {
    expect(at(/find "\$copy" -type l/)).toBeLessThan(at(/migrate-daemon-config\.sh/));
  });

  it('device.pub is unlinked before root writes it', () => {
    const rm = at(/rm -f -- "\$HOME_DIR\/device\.pub"/);
    const write = at(/> "\$HOME_DIR\/device\.pub"/);
    expect(rm).toBeGreaterThan(-1);
    expect(write).toBeGreaterThan(rm);
  });

  it('negative control: the staging folder is still deleted at the end', () => {
    expect(at(/rm -rf -- "\$STAGING"/)).toBeGreaterThan(-1);
  });
});
