// ─── DVPND_BIN never picks the root service binary in a packaged build (AC-MAC-1 C3) — macOS ───
// setup-daemon.sh installs `Dvpnd` as the root LaunchDaemon binary and checks only its basename. dvpndPath()
// honoured DVPND_BIN everywhere, so whoever set the app's / CLI's environment chose what root installs.
import { describe, expect, it, vi } from 'vitest';

vi.mock('../../../src/main/logger', () => ({ log: { info: vi.fn(), warn: vi.fn(), error: vi.fn(), debug: vi.fn() } }));

import { dvpndPathFor, packagedBuild } from '../../../src/main/daemon/manager';

const PKG = '/Applications/Devnet dVPN.app/Contents/Resources/resources';
const DEV = '/Users/dev/devnet-dvpn-mac/resources';
const evil = '/tmp/x/sentinel-dvpnd';
const always = (): boolean => true;

describe('dvpndPathFor', () => {
  it('packaged: DVPND_BIN is ignored, the bundled binary is used', () => {
    expect(dvpndPathFor({ DVPND_BIN: evil }, PKG, always)).toBe(`${PKG}/bin/sentinel-dvpnd`);
  });

  it('packaged: also for an app outside /Applications (Downloads)', () => {
    const res = '/Users/u/Downloads/Devnet dVPN.app/Contents/Resources/resources';
    expect(packagedBuild(res)).toBe(true);
    expect(dvpndPathFor({ DVPND_BIN: evil }, res, always)).toBe(`${res}/bin/sentinel-dvpnd`);
  });

  it('negative control: a dev tree still honours DVPND_BIN when the file exists', () => {
    expect(packagedBuild(DEV)).toBe(false);
    expect(dvpndPathFor({ DVPND_BIN: evil }, DEV, always)).toBe(evil);
    expect(dvpndPathFor({ DVPND_BIN: evil }, DEV, () => false)).toBe(`${DEV}/bin/sentinel-dvpnd`);
  });

  it('no DVPND_BIN: the bundled binary', () => {
    expect(dvpndPathFor({}, PKG, always)).toBe(`${PKG}/bin/sentinel-dvpnd`);
  });
});
