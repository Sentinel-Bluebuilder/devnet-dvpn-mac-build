// ─── The macOS LaunchDaemon: installed, loaded, running (#38 rc.8, the macOS twin of Linux RC8 W47) ───
// An installed but STOPPED service was told `daemon install --yes` (a reinstall, root, a minute) where one launchctl
// line brings it back; and `daemon doctor` passed the root-only rows with "it is running, so they passed" while
// nothing ran. The plist has RunAtLoad + KeepAlive, so "stopped" is one of two states:
//   - booted out (plist on disk, `launchctl print` exit 113): `sudo launchctl bootstrap system <plist>`;
//   - loaded but not running (crash throttle, or killed between KeepAlive restarts): `sudo launchctl kickstart -k system/<label>`.
// Pure: the caller runs `launchctl print system/<label>` (no root needed to read).

export interface LaunchdState { installed: boolean | null; loaded: boolean; running: boolean }
export const LAUNCHD_UNKNOWN: LaunchdState = { installed: null, loaded: false, running: false };

/** `launchctl print system/<label>` exit code + stdout/stderr, and whether the plist is on disk -> the state. */
export function parseLaunchd(code: number, out: string, plistExists: boolean): LaunchdState {
  const t = String(out ?? '');
  if (code === 113 || /could not find service/i.test(t)) return { installed: plistExists, loaded: false, running: false };
  if (code !== 0) return { ...LAUNCHD_UNKNOWN };
  const m = /^\s*state = (\S+)/m.exec(t);
  return { installed: true, loaded: true, running: !!m && m[1] === 'running' };
}

/** Installed and not running: the one launchctl line that starts it. null = running, not installed, or unknown. */
export function launchdStartNext(s: LaunchdState, label: string, plist: string): string | null {
  if (s.installed !== true || s.running) return null;
  return s.loaded ? `sudo launchctl kickstart -k system/${label}` : `sudo launchctl bootstrap system ${plist}`;
}

/** RC9 PF-DEAD (#33 run 44808199308): Restore network with the service not answering said "Restart the Mac" with
 *  next:null. On macOS one launchctl line restarts the daemon, then the restore runs again. Pure. */
export function restoreUnavailableNext(platform: string, label: string, cli: string): string {
  return platform === 'darwin' ? `sudo launchctl kickstart -k system/${label}, then ${cli} daemon restore-network` : `${cli} daemon doctor`;
}

export interface DoctorRowLite { name: string; ok: boolean; level: 'ok' | 'warn' | 'fail' | 'skip'; detail: string }
const PASSED_BY_SERVICE = /it is running, so they passed/i;

/** Doctor, macOS: a `service` row from launchd AND whether the socket answered; rows dvpnd passed "because it is
 *  running" read as not checked while it does not run. Unknown launchd state (a test daemon): rows unchanged. Pure. */
export function darwinDoctorRows<R extends DoctorRowLite>(rows: R[], s: LaunchdState, answered: boolean, label: string, plist: string): DoctorRowLite[] {
  if (s.installed === null) return rows;
  const up = answered && s.running;
  const start = launchdStartNext(s, label, plist);
  let svcRow: DoctorRowLite;
  if (up) svcRow = { name: 'service', ok: true, level: 'ok', detail: `${label} is running and its socket answered.` };
  else if (s.installed === false) svcRow = { name: 'service', ok: false, level: 'fail', detail: 'The VPN service is not installed. Install it: devnet-dvpn daemon install --yes' };
  else if (start) svcRow = { name: 'service', ok: false, level: 'fail', detail: `The VPN service is installed but stopped. Start it: ${start}` };
  else svcRow = { name: 'service', ok: false, level: 'fail', detail: `${label} is running but its socket did not answer. Restart it: sudo launchctl kickstart -k system/${label}` };
  const out = rows.map((r): DoctorRowLite => (!up && PASSED_BY_SERVICE.test(r.detail)
    ? { ...r, level: 'skip', detail: 'Not checked: the service is not running (it checks its own settings when it starts).' }
    : r));
  return [svcRow, ...out];
}
