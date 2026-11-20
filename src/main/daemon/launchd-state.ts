// ─── Read the LaunchDaemon's state for status / doctor (#38 rc.8, macOS twin of Linux RC8 W47) ───
// Its own module so the many tests that mock manager.ts need no new export; tests mock this file instead.
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import { parseLaunchd, LAUNCHD_UNKNOWN, type LaunchdState } from '../../core/daemon/darwin-launchd';
import { CLIENT_INSTANCE, serviceName } from '../../core/daemon/layout';
import { log } from '../logger';

/** Same label + plist as manager.ts SERVICE_LABEL / SERVICE_PLIST (cb33: co.sentinel.sentinel-dvpnd.c0). */
export const LAUNCHD_LABEL = serviceName('darwin', CLIENT_INSTANCE);
export const LAUNCHD_PLIST = `/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist`;

/** `launchctl print system/<label>` -> the state. Off macOS, or with a test daemon (DVPN_DAEMON_TARGET /
 *  DVPN_DAEMON_SOCKET), there is no LaunchDaemon to ask: unknown. Never throws. */
export function launchdState(): Promise<LaunchdState> {
  if (process.platform !== 'darwin' || process.env.DVPN_DAEMON_TARGET || process.env.DVPN_DAEMON_SOCKET) return Promise.resolve({ ...LAUNCHD_UNKNOWN });
  return new Promise((resolve) => {
    execFile('launchctl', ['print', `system/${LAUNCHD_LABEL}`], { timeout: 10_000 }, (err, stdout, stderr) => {
      const code = err ? (typeof (err as { code?: unknown }).code === 'number' ? Number((err as { code?: unknown }).code) : 1) : 0;
      if (err && code !== 113) log.debug('launchctl print failed', { err: err.message });
      let plist = false;
      try { plist = fs.existsSync(LAUNCHD_PLIST); } catch (e) { log.debug('plist check failed', { err: (e as Error).message }); }
      resolve(parseLaunchd(code, `${String(stdout)}${String(stderr)}`, plist));
    });
  });
}
