// ─── Mac builds sign with ONE stable self-signed identity (DIR 11-13, Mac rc.2) ───
// Ad hoc, the designated requirement is the cdhash, so each build was a new app to the Keychain and the first start
// after an update asked for the login keychain password (safeStorage blocked the app meanwhile).
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

const require = createRequire(import.meta.url);
const { signer, codesignArgs } = require('../../../build/mac/adhoc-sign.cjs') as {
  signer: (env: Record<string, string>) => { kind: string; identity?: string; keychain?: string; passFile?: string };
  codesignArgs: (s: object, target: string, deep: boolean) => string[];
};

describe('Mac signing identity', () => {
  it('release: signs with the stable identity from its own keychain', () => {
    const s = signer({ DVPN_MAC_SIGN_IDENTITY: 'ABC123', DVPN_MAC_SIGN_KEYCHAIN: '/k/ddv-signing.keychain-db', DVPN_MAC_SIGN_KEYCHAIN_PASS_FILE: '/k/pass' });
    expect(s).toEqual({ kind: 'identity', identity: 'ABC123', keychain: '/k/ddv-signing.keychain-db', passFile: '/k/pass' });
    expect(codesignArgs(s, '/a/X.app', true)).toEqual(['--force', '--deep', '--sign', 'ABC123', '--keychain', '/k/ddv-signing.keychain-db', '--timestamp=none', '/a/X.app']);
  });
  it('an identity without its keychain is refused', () => {
    expect(() => signer({ DVPN_MAC_SIGN_IDENTITY: 'ABC123' })).toThrow(/DVPN_MAC_SIGN_KEYCHAIN/);
  });
  it('negative control: no identity and no explicit ad-hoc opt-in fails the build', () => {
    expect(() => signer({})).toThrow(/no Mac signing identity/);
  });
  it('dev builds may sign ad hoc only when asked', () => {
    const s = signer({ DVPN_MAC_ADHOC: '1' });
    expect(codesignArgs(s, '/a/bin', false)).toEqual(['--force', '--sign', '-', '--timestamp=none', '/a/bin']);
  });
  it('the build hook still verifies the bundle and prints the designated requirement', () => {
    const src = readFileSync('build/mac/adhoc-sign.cjs', 'utf8');
    expect(src).toContain("['--verify', '--deep', '--strict', app]");
    expect(src).toContain("['-d', '-r-', app]");
  });
});

describe('Mac signing keychain search list', () => {
  const { parseSearchList } = require('../../../build/mac/adhoc-sign.cjs') as { parseSearchList: (o: string) => string[] };
  it('reads `security list-keychains -d user` output', () => {
    expect(parseSearchList('    "/Users/user/Library/Keychains/login.keychain-db"\n    "/Users/user/ddv-signing/ddv-signing.keychain-db"\n'))
      .toEqual(['/Users/user/Library/Keychains/login.keychain-db', '/Users/user/ddv-signing/ddv-signing.keychain-db']);
    expect(parseSearchList('')).toEqual([]);
  });
  it('the hook puts the old list back after signing (finally)', () => {
    const src = readFileSync('build/mac/adhoc-sign.cjs', 'utf8');
    expect(src).toMatch(/try \{ return fn\(\); \}\s*finally \{ execFileSync\('\/usr\/bin\/security', \['list-keychains', '-d', 'user', '-s', \.\.\.before\]\); \}/);
  });
});
