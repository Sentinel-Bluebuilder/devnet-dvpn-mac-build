// ─── adhoc-sign.cjs says what the published build is: ad hoc (AC-MAC-1 C8) — macOS ───
// The published v0.3.0-rc8 is ad hoc by owner decision (GitHub macos-15 has no signing identity), yet the header
// said "a release must not" and the error offered ad hoc "for a dev build" only.
import fs from 'node:fs';
import { describe, expect, it } from 'vitest';

const src = fs.readFileSync('build/mac/adhoc-sign.cjs', 'utf8');

describe('adhoc-sign.cjs text', () => {
  it('no longer calls ad hoc dev-only', () => {
    expect(src).not.toMatch(/a release must not/);
    expect(src).not.toMatch(/DVPN_MAC_ADHOC=1 for a dev build/);
    expect(src).not.toMatch(/AD-HOC signed \(dev build\)/);
  });

  it('names ad hoc as the published CI signing', () => {
    expect(src).toMatch(/DVPN_MAC_ADHOC=1 to sign ad hoc \(as the published CI release does\)/);
  });

  it('negative control: the no-identity error is still thrown with its pinned words', () => {
    expect(src).toMatch(/no Mac signing identity/);
  });
});
