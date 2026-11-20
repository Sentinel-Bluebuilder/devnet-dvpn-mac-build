// ─── AUDIT-FINAL-MACOS M9, M11, M12, M13 (low/nit) — macOS ───
import fs from 'node:fs';
import { describe, expect, it } from 'vitest';

const read = (f: string): string => fs.readFileSync(f, 'utf8');
const code = (s: string): string => s.split('\n').filter((l) => !/^\s*(#|\/\/)/.test(l)).join('\n');

describe('M9: setup stops the old job before it loads the new plist', () => {
  const s = code(read('resources/scripts/setup-daemon.sh'));
  it('a bare svc_stop is gone; a failed stop dies with a next', () => {
    expect(s).not.toMatch(/^svc_stop\s*$/m);
    expect(s).toMatch(/^svc_stop \|\| die "the old VPN service did not stop.*Next: sudo launchctl bootout system\/\$LABEL/m);
  });
  it('the guarded stop comes before the new plist is written', () => {
    expect(s.indexOf('svc_stop || die "the old VPN service')).toBeLessThan(s.indexOf('cat > "$PLIST.new"'));
  });
});

describe('M8: staging is checked on its canonical path, under the --User home', () => {
  const s = code(read('resources/scripts/setup-daemon.sh'));
  it('the real path must equal the given one and end in daemon-staging | daemon-switch', () => {
    expect(s).toMatch(/staging_real="\$\(cd -P -- "\$STAGING" 2>\/dev\/null && pwd -P\)"/);
    expect(s).toMatch(/\[ "\$staging_real" = "\$STAGING" \] \|\| die "unsafe staging folder/);
    expect(s).toMatch(/case "\$\(basename -- "\$staging_real"\)" in daemon-staging\|daemon-switch\) ;;/);
    expect(s).toMatch(/case "\$staging_real" in "\$user_home_real"\/\?\*\) ;;/);
  });
  it('all of it runs before the staged home is copied or removed', () => {
    const check = s.indexOf('[ "$staging_real" = "$STAGING" ]');
    expect(check).toBeGreaterThan(-1);
    expect(check).toBeLessThan(s.indexOf('cp -Rp "$STAGING/."'));
    expect(check).toBeLessThan(s.indexOf('rm -rf -- "$STAGING"'));
  });
});

describe('M11: a failed DNS restore keeps the backup and says so', () => {
  const s = code(read('resources/scripts/remove-tunnels.sh'));
  it('failed services are collected, the backup is removed only when none failed', () => {
    expect(s).toMatch(/else dns_failed\+=\("\$svc"\); fi/);
    expect(s).toMatch(/\[ \$\{#dns_failed\[@\]\} -eq 0 \] && rm -f "\$bf"/);
    expect(s).not.toMatch(/^\s*rm -f "\$bf"\s*$/m);
  });
  it('the result names them', () => {
    expect(s).toMatch(/dns not restored on: /);
  });
  it('negative control: a restored service is still listed as removed', () => {
    expect(s).toMatch(/then removed\+=\("dns \$svc"\)/);
  });
});

describe('M12: comments name the real paths', () => {
  it('setup-daemon.sh and manager.ts no longer name /usr/local/lib/devnet-dvpn or /var/db/dvpnd as current', () => {
    expect(read('resources/scripts/setup-daemon.sh').split('\n')[7]).not.toMatch(/\/usr\/local\/lib\/devnet-dvpn/);
    expect(read('src/main/daemon/manager.ts')).not.toMatch(/copy into \/var\/db\/dvpnd/);
  });
});

describe('M13: keyfileModeProblem never swallows a stat error silently', () => {
  it('the catch logs', () => {
    expect(read('src/cli/keystore.ts')).toMatch(/catch \(err\) \{ log\.debug\('key file stat failed'/);
  });
});
