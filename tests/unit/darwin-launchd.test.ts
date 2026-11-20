// #38 rc.8, macOS twin of Linux RC8 W47 (T-C rows 16/17): an installed but stopped LaunchDaemon, and doctor while it is stopped.
import { describe, expect, it } from 'vitest';
import { parseLaunchd, launchdStartNext, darwinDoctorRows } from '../../src/core/daemon/darwin-launchd';

const L = 'co.sentinel.sentinel-dvpnd.c0';
const P = `/Library/LaunchDaemons/${L}.plist`;
const print = (state: string): string => `system/${L} = {\n\tactive count = 0\n\tpath = ${P}\n\tstate = ${state}\n\tprogram = /Library/devnet-dvpn/dvpnd\n}\n`;
const NOT_FOUND = `Could not find service "${L}" in domain for system`;
const PASSED = { name: 'service_settings', ok: true, level: 'skip' as const, detail: 'run by the service itself (its settings are readable by root only); it is running, so they passed' };

describe('row 16: an installed but stopped LaunchDaemon gets one launchctl line, not a reinstall', () => {
  it('booted out (exit 113, plist on disk) -> sudo launchctl bootstrap system <plist>', () => {
    const s = parseLaunchd(113, NOT_FOUND, true);
    expect(s).toEqual({ installed: true, loaded: false, running: false });
    expect(launchdStartNext(s, L, P)).toBe(`sudo launchctl bootstrap system ${P}`);
  });
  it('loaded but not running -> sudo launchctl kickstart -k system/<label>', () => {
    const s = parseLaunchd(0, print('not running'), true);
    expect(s).toEqual({ installed: true, loaded: true, running: false });
    expect(launchdStartNext(s, L, P)).toBe(`sudo launchctl kickstart -k system/${L}`);
  });
  it('running -> no start command', () => {
    expect(launchdStartNext(parseLaunchd(0, print('running'), true), L, P)).toBeNull();
  });
  it('not installed (113, no plist) -> no start command (daemon install stays the fix)', () => {
    const s = parseLaunchd(113, NOT_FOUND, false);
    expect(s.installed).toBe(false);
    expect(launchdStartNext(s, L, P)).toBeNull();
  });
  it('launchctl failed some other way -> unknown, no start command', () => {
    const s = parseLaunchd(1, 'Bad request.', true);
    expect(s.installed).toBeNull();
    expect(launchdStartNext(s, L, P)).toBeNull();
  });
});

describe('row 17: doctor checks the LaunchDaemon runs and the socket answers', () => {
  it('booted out: a fail row with the bootstrap line, and "it is running, so they passed" is not a pass', () => {
    const rows = darwinDoctorRows([PASSED], parseLaunchd(113, NOT_FOUND, true), false, L, P);
    expect(rows[0]).toMatchObject({ name: 'service', level: 'fail' });
    expect(rows[0].detail).toContain(`sudo launchctl bootstrap system ${P}`);
    expect(rows[1].detail).not.toMatch(/it is running/);
    expect(rows[1].detail).toMatch(/Not checked/);
  });
  it('running and answering: an ok service row, the service rows untouched', () => {
    const rows = darwinDoctorRows([PASSED], parseLaunchd(0, print('running'), true), true, L, P);
    expect(rows[0]).toMatchObject({ name: 'service', level: 'ok' });
    expect(rows[1]).toEqual(PASSED);
  });
  it('running but the socket does not answer: fail, kickstart named', () => {
    const rows = darwinDoctorRows([], parseLaunchd(0, print('running'), true), false, L, P);
    expect(rows[0].level).toBe('fail');
    expect(rows[0].detail).toContain(`sudo launchctl kickstart -k system/${L}`);
  });
  it('not installed: fail, daemon install named', () => {
    const rows = darwinDoctorRows([], parseLaunchd(113, NOT_FOUND, false), false, L, P);
    expect(rows[0].detail).toContain('daemon install --yes');
  });
  it('unknown (a test daemon, or not macOS): rows unchanged, no service row', () => {
    expect(darwinDoctorRows([PASSED], parseLaunchd(1, '', true), false, L, P)).toEqual([PASSED]);
  });
});

