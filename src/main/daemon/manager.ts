// ─── Daemon manager (D1, D5, F1, F4.5) — macOS ───
// The app runs as the desktop user; sentinel-dvpnd runs as root under launchd (LaunchDaemon
// `co.sentinel.sentinel-dvpnd.c0`). The daemon serves gRPC on <instance dir>/daemon.sock with
// mode 0660 and gives it to the group `sentinel-dvpn`; setup adds the user to that group and puts
// an inherited ACL for the user on the home, so the app dials the socket directly.
// cb33 (26de5240): the binary is `sentinel-dvpnd`, the client is instance c0, its home is the real
// instance dir `/Library/Application Support/sentinel-dvpn/c0` (ONE config.toml), and the daemon
// runs as `run --instance c0` (no --home) so it reads that dir and gives the socket its group.
// No bridge process: the link is a health probe that re-attaches when the socket comes back.
import { levelFromSeverity, type CheckLevel } from '../../shared/check-level';
import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { DaemonClient, DaemonError, pipeTarget, type DaemonVersion } from '../../core/daemon/client';
import { MINT, PROGRAM_ID } from '../../core/chain/idl';
import type { DaemonInfo } from '../../shared/types';
import { readJson, writeJson } from '../store';
import { ROOT_SCRIPTS_DIR, runElevated, type ElevatedResult } from '../system/elevate';
import { log } from '../logger';
import { getHost } from '../host';
import {
  linkFault, OS_STATE_UNKNOWN, retryDelayMs, serviceView, serviceViewFor,
  type LinkFault, type OsServiceState, type ServiceFacts, type ServiceView,
} from '../../core/daemon/service-state';
import { carrySettingsInto, patchToml, readToml, renderServiceConfig, TUN_SERVICES } from '../../core/daemon/config';
import {
  CLIENT_INSTANCE, DAEMON_GROUP, SOCKET_FILE,
  daemonBinaryName, daemonEndpoint, doctorArgs, initArgs, instanceDir,
  keyListArgs, legacyHome, operatorKey, serviceName,
} from '../../core/daemon/layout';

/** The client instance's real home: /Library/Application Support/sentinel-dvpn/c0 (overridable in tests). */
export const DEFAULT_DAEMON_HOME = process.env.DVPN_DAEMON_HOME || instanceDir('darwin');
/** The pre-cb33 client home; carryLiveSettings reads its settings into the new instance. */
export const LEGACY_DAEMON_HOME = legacyHome('darwin');
/** The group the daemon gives its socket to; setup adds the desktop user to it. */
export const SOCKET_GROUP = DAEMON_GROUP;
/** Short service name passed to the helper steps (kept from #31/#32; the macOS steps use the label). */
export const SERVICE_NAME = 'dvpnd-client';
/** The LaunchDaemon label (cb33: co.sentinel.sentinel-dvpnd.c0). */
export const SERVICE_LABEL = serviceName('darwin', CLIENT_INSTANCE);
export const SERVICE_PLIST = `/Library/LaunchDaemons/${SERVICE_LABEL}.plist`;
const DEVICE_FILE = 'device.json';
const HEALTH_MS = 15_000;

// ─── Paths ───
export function resourcesDir(): string {
  return getHost().resourcesDir;
}
export const binPath = (name: string): string => path.join(resourcesDir(), 'bin', name);
export const scriptPath = (name: string): string => path.join(resourcesDir(), 'scripts', name);
export const protoPath = (): string => path.join(resourcesDir(), 'daemon.proto');
export function dvpndPath(): string {
  return process.env.DVPND_BIN && fs.existsSync(process.env.DVPND_BIN) ? process.env.DVPND_BIN : binPath(daemonBinaryName('darwin'));
}

// dvpnd finds V2Ray/Xray/Hysteria2 only on PATH (go-sdk service.LookPath). Each lives in its own
// folder because V2Ray and Xray ship different geoip/geosite files under the same names. The
// service gets these on its own PATH (the LaunchDaemon's EnvironmentVariables, setup-daemon.sh).
export const PROTOCOL_BIN_DIRS = ['v2ray', 'xray', 'hysteria2'];
export const protocolBinDirs = (): string[] => PROTOCOL_BIN_DIRS.map((d) => binPath(d)).filter((d) => fs.existsSync(d));
/** The root-owned tools the service runs (WireGuard, AmneziaWG, OpenVPN, bash 5): install-deps.sh. */
export const SERVICE_TOOLS_DIR = '/Library/devnet-dvpn/tools';
/**
 * PATH for `dvpnd doctor` run as the user: the service's own PATH first (its tools folder, then the
 * protocol folders), the user's PATH last. With the user's PATH first, a Homebrew wg in
 * /usr/local/bin read as "present" while AmneziaWG (only in the tools folder) read as missing,
 * so doctor disagreed with the service (exported for tests).
 */
export function servicePathFor(userPath: string, toolsDir: string | null, protocolDirs: string[]): string {
  return [...(toolsDir ? [toolsDir] : []), ...protocolDirs, ...(userPath ? [userPath] : [])].join(path.delimiter);
}
/**
 * The protocol folders doctor should judge: the root-owned copies the service runs
 * (/Library/devnet-dvpn/<protocol>, setup-daemon.sh) once installed, else this app's bundle. Judging the
 * bundle on an installed Mac gave three "refused (/Applications drwxrwxr-x)" warnings on a healthy
 * install (Q0508 guest T1, 11-12): /Applications is admin-writable, the service's copies are not.
 * `exists` is injectable for tests.
 */
export function doctorProtocolDirs(serviceLib: string, bundleDirs: string[], exists: (p: string) => boolean = fs.existsSync): string[] {
  const installed = PROTOCOL_BIN_DIRS.map((d) => path.join(serviceLib, d)).filter(exists);
  return installed.length ? installed : bundleDirs;
}
const withProtocolPath = (): NodeJS.ProcessEnv => ({
  ...process.env,
  PATH: servicePathFor(process.env.PATH ?? '', fs.existsSync(SERVICE_TOOLS_DIR) ? SERVICE_TOOLS_DIR : null, doctorProtocolDirs(SERVICE_LIB, protocolBinDirs())),
});

interface DeviceRecord { device: string; home: string; owner: string; at: number }

// ─── State ───
let client: DaemonClient | null = null;
let retryTimer: NodeJS.Timeout | null = null;
let healthTimer: NodeJS.Timeout | null = null;
/** Failed link attempts in a row; decides the wait before the next one (core/daemon/service-state retryDelayMs). */
let attempts = 0;
let stopping = false;
const info: DaemonInfo = { reachable: false, bridge: 'stopped', version: null, networkOk: null, error: null, home: null, device: null };
const listeners = new Set<() => void>();

export const onDaemonChange = (fn: () => void): (() => void) => { listeners.add(fn); return () => listeners.delete(fn); };
const emit = (): void => { for (const l of listeners) l(); };

export function daemonInfo(): DaemonInfo {
  const d = readJson<DeviceRecord | null>(DEVICE_FILE, null);
  return { ...info, home: d?.home ?? null, device: d?.device ?? null, service: serviceNow() };
}

// ─── Service state (#31 490af3e / baff369, UI pass rows 119-142) ───
// The facts behind the one sentence: how the last link attempt failed, what launchd says about the service, and
// when it was last started. The sentence itself comes from the shared core/daemon/service-state.ts.
let lastFault: LinkFault = 'unknown';
let osState: OsServiceState = { ...OS_STATE_UNKNOWN };
let startedAt: number | null = null;
let transitionProbe: () => boolean = () => false;
/** services/service-transition.ts tells the link whether a restart is in progress (it imports this module). */
export function setTransitionProbe(fn: () => boolean): void { transitionProbe = fn; }

export function serviceFacts(): ServiceFacts {
  let transition = false;
  try { transition = transitionProbe(); } catch (err) { log.warn('service state: the restart check failed', { err: (err as Error).message }); }
  return {
    answered: info.reachable, networkOk: info.networkOk, transition,
    installed: osState.installed, running: osState.running, startPending: osState.startPending,
    link: info.reachable ? 'none' : lastFault,
    startedAgoMs: startedAt === null ? null : Date.now() - startedAt,
  };
}

/** The service's state now: one title, one sentence, one action. */
export function serviceNow(): ServiceView { return serviceViewFor(serviceFacts()); }

/** The service was just asked to start (this app, an install, a grant): link failures inside the grace read "starting". */
export function noteServiceStarting(): void { startedAt = Date.now(); }

const setError = (): void => { info.error = serviceNow().sentence || null; };

/**
 * `launchctl print system/<label>` (no root needed to read) -> the OS facts. Exit 113 / "Could not find service" =
 * not loaded: installed only if its plist is still there (then it is off). Any other text = unknown (exported for tests).
 */
export function parseLaunchctlPrint(code: number, out: string, plistExists: boolean): OsServiceState {
  const t = String(out ?? '');
  if (code === 113 || /could not find service/i.test(t)) return { installed: plistExists, running: false, startPending: false };
  if (code !== 0) return { ...OS_STATE_UNKNOWN };
  const m = /^\s*state = (\S+)/m.exec(t);
  if (!m) return { installed: true, running: null, startPending: false };
  return { installed: true, running: m[1] === 'running', startPending: false };
}

let osBusy = false;
/** Ask launchd about the service (read-only). DVPN_DAEMON_TARGET (a test daemon) has no service to ask: unknown. */
async function refreshOsState(): Promise<void> {
  if (process.platform !== 'darwin' || process.env.DVPN_DAEMON_TARGET || osBusy) return;
  osBusy = true;
  try {
    const r = await new Promise<{ code: number; out: string }>((resolve) => {
      execFile('launchctl', ['print', `system/${SERVICE_LABEL}`], { timeout: 10_000 }, (err, stdout, stderr) => {
        const code = err ? (typeof (err as { code?: unknown }).code === 'number' ? Number((err as { code?: unknown }).code) : 1) : 0;
        resolve({ code, out: `${String(stdout)}${String(stderr)}` });
      });
    });
    osState = parseLaunchctlPrint(r.code, r.out, fs.existsSync(SERVICE_PLIST));
  } finally {
    osBusy = false;
  }
}

/** Row 139: the same failure every second is one log line, then one a minute (kept per kind of failure). A service
 *  that is not installed, off, starting or restarting is not a fault of the link: info, not warn. */
const lastLogged = new Map<string, number>();
function logLinkFailure(what: string, raw: string): void {
  const state = serviceNow().state;
  const key = `${what}:${linkFault(raw)}:${state}`;
  const t = Date.now();
  if (t - (lastLogged.get(key) ?? 0) < 60_000) return;
  lastLogged.set(key, t);
  if (lastLogged.size > 64) for (const [k, at] of lastLogged) if (t - at > 60_000) lastLogged.delete(k);
  const expected = state === 'not-installed' || state === 'stopped' || state === 'starting' || state === 'restarting';
  log[expected ? 'info' : 'warn'](what, { err: raw.slice(0, 1500), state, attempts });
}

/** A link attempt failed: record how, say the state at once, then ask launchd and say it again if that changed it. */
function linkFailed(raw: string): void {
  lastFault = linkFault(raw);
  info.reachable = false;
  setError();
  void refreshOsState().then(() => {
    if (info.reachable) return;
    const before = info.error;
    setError();
    if (info.error !== before) emit();
  }).catch((err) => log.warn('could not ask launchd about the VPN service', { err: (err as Error).message }));
}

/** An install or reinstall of the service is running (its admin step): shared callers wait for it. */
let installing = 0;
export const serviceInstallRunning = (): boolean => installing > 0;

// ─── Retry speed (row 121) ───
// Someone is looking at the app or waiting on a button: try the link every second. Otherwise back off.
// (No automatic start here, unlike #31 rows 120/125: launchd's KeepAlive restarts the daemon itself, and a
// non-admin cannot kickstart a system daemon.)
let watching = false;
let watchers = 0;
/** The window is visible (true) or hidden (false). */
export function setLinkWatching(v: boolean): void {
  const was = watching || watchers > 0;
  watching = v;
  if (v && !was) retryNow();
}
/** Run `fn` with the fast retry on (Connect, Restore network, Diagnostics waiting for the service). */
export async function withLinkWatch<T>(fn: () => Promise<T>): Promise<T> {
  watchers += 1;
  if (watchers === 1 && !watching) retryNow();
  try { return await fn(); } finally { watchers -= 1; }
}
const nextDelay = (): number => retryDelayMs(attempts, watching || watchers > 0);

/** Tests only. */
export function resetLinkState(): void {
  attempts = 0; lastFault = 'unknown'; osState = { ...OS_STATE_UNKNOWN }; startedAt = null;
  watching = false; watchers = 0; lastLogged.clear();
  transitionProbe = () => false;
}

/** A button was pressed that needs the service: a waiting retry runs now. */
export function retryNow(): void {
  if (stopping || info.reachable || !retryTimer) return;
  clearTimeout(retryTimer);
  retryTimer = null;
  startDaemonLink();
}

export function deviceRecord(): DeviceRecord | null {
  return readJson<DeviceRecord | null>(DEVICE_FILE, null);
}

/** The connected gRPC client, or a clear error the UI can show. */
export function daemon(): DaemonClient {
  if (!client || !info.reachable) {
    const said = serviceNow().sentence || serviceView('stopped').sentence;
    throw new DaemonError(Object.assign(new Error(said), { code: 14, details: said }) as Error, 'daemon');
  }
  return client;
}

// ─── Link lifecycle ───
/** DVPN_DAEMON_SOCKET overrides the control socket (a foreground test daemon). */
export const daemonSocket = (): string =>
  process.env.DVPN_DAEMON_SOCKET || path.join(deviceRecord()?.home ?? DEFAULT_DAEMON_HOME, SOCKET_FILE);

/**
 * Whether this account can reach the service socket. existsSync() says false for a socket in a folder this
 * account may not enter, so a second Mac user (not in the socket group) was told "The VPN service is not
 * running" while it ran, and Connect never offered the one-prompt grant (Q0484 H1, 11-12). Exported for tests.
 */
export function socketProbe(sock: string, stat: (p: string) => unknown = fs.statSync): 'present' | 'missing' | 'denied' {
  try {
    stat(sock);
    return 'present';
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    return code === 'EACCES' || code === 'EPERM' ? 'denied' : 'missing';
  }
}

/** Resolves once the first attach attempt finished (success or not). */
let firstAttach: Promise<void> = Promise.resolve();
let resolveFirst: (() => void) | null = null;
export const daemonReady = (timeoutMs = 10_000): Promise<void> => Promise.race([firstAttach, new Promise<void>((r) => setTimeout(r, timeoutMs).unref())]);

const settleFirst = (): void => { if (resolveFirst) { resolveFirst(); resolveFirst = null; } };

export function startDaemonLink(): void {
  stopping = false;
  firstAttach = new Promise((r) => { resolveFirst = r; });
  // DVPN_DAEMON_TARGET=host:port — a TCP-bridged daemon (netns test rig). Test/dev only.
  if (process.env.DVPN_DAEMON_TARGET) {
    info.bridge = 'running';
    void attach(process.env.DVPN_DAEMON_TARGET);
    return;
  }
  const sock = daemonSocket();
  const probe = socketProbe(sock);
  if (probe !== 'present') {
    info.bridge = 'missing';
    // denied: installed for another account -> 'no-permission' (Finish setup runs grantPipeAccess, one prompt).
    const raw = probe === 'denied' ? `EACCES ${sock}` : `ENOENT ${sock}`;
    linkFailed(raw);
    logLinkFailure('daemon socket not reachable', raw);
    emit();
    settleFirst();
    scheduleRetry();
    return;
  }
  info.bridge = 'running';
  void attach(pipeTarget(sock));
}

/** True from the moment the app closes its own link (quit): a link going down then is not a service restart. */
export function linkStopping(): boolean { return stopping; }

function scheduleRetry(): void {
  if (retryTimer || stopping) return;
  retryTimer = setTimeout(() => {
    retryTimer = null;
    startDaemonLink();
  }, nextDelay());
  retryTimer.unref(); // the CLI must be able to exit while the service is down
  attempts += 1;
}

/** While attached, re-check every 15 s: a restarted service gets a new socket, a stopped one none. */
function startHealth(): void {
  if (healthTimer) return;
  healthTimer = setInterval(() => {
    const c = client;
    if (!c || stopping) return;
    c.getVersion().catch((err: Error) => {
      if (client !== c || stopping) return;
      log.warn('daemon stopped answering', { err: err.message });
      detach();
      info.bridge = 'stopped';
      linkFailed(err.message);
      emit();
      scheduleRetry();
    });
  }, HEALTH_MS);
  healthTimer.unref();
}

async function attach(target: string): Promise<void> {
  detach();
  client = new DaemonClient(target, protoPath());
  try {
    const v = await client.getVersion();
    info.reachable = true;
    info.version = v.tag || v.commit || 'unknown';
    info.networkOk = networkMatches(v);
    lastFault = 'none';
    osState = { installed: true, running: true, startPending: false };
    setError();
    attempts = 0;
    lastLogged.clear();
    log.info('daemon attached', { version: info.version, network: v.network, networkOk: info.networkOk });
    startHealth();
  } catch (err) {
    info.bridge = 'error';
    linkFailed((err as Error).message);
    logLinkFailure('daemon attach failed', (err as Error).message);
    // Busy starting or a slow machine: retry (#31 2169efe; here the retry also re-checks that the socket still exists).
    scheduleRetry();
  }
  emit();
  settleFirst();
}

export function networkMatches(v: Pick<DaemonVersion, 'programId' | 'mint'>): boolean {
  return v.programId === PROGRAM_ID.toBase58() && v.mint === MINT.toBase58();
}

function detach(): void {
  if (client) {
    client.close();
    client = null;
  }
  info.reachable = false;
}

export function stopDaemonLink(): void {
  stopping = true;
  if (retryTimer) { clearTimeout(retryTimer); retryTimer = null; }
  if (healthTimer) { clearInterval(healthTimer); healthTimer = null; }
  detach();
  info.bridge = 'stopped';
}

/** Re-probe now (after setup or a settings restart). */
export function relinkDaemon(): void {
  attempts = 0;
  if (retryTimer) { clearTimeout(retryTimer); retryTimer = null; }
  stopping = false;
  startDaemonLink();
}

/**
 * During a service transition (#31 1b591b0, Agent M Mac T3 r6): fire a WAITING link retry now instead of after its
 * backoff, so the guard settles from the real reattach (r6c: dvpnd ready at +3 s, attach only at +6.25 s). Never
 * one in flight, never while stopping or already linked; startDaemonLink re-probes the socket (one stat per call).
 */
let verifying = false;
export function reattachSoon(): void {
  if (stopping) return;
  // #31 3af3c39 (DVPN-WIN tr-kill-down r51): a transition that began on an event (the session stream dropped) while
  // the link still read up waited for the 15 s health check before the link read down. While a transition runs, a
  // link that reads up is asked again now: one GetVersion at a time; a miss takes the health check's path at once.
  if (info.reachable) {
    const c = client;
    if (!c || verifying) return;
    verifying = true;
    c.getVersion().then(
      () => { verifying = false; },
      (err: Error) => {
        verifying = false;
        if (client !== c || !info.reachable || stopping) return;
        log.warn('daemon did not answer during a service transition', { err: err.message });
        detach();
        info.bridge = 'stopped';
        linkFailed(err.message);
        emit();
        scheduleRetry();
      },
    );
    return;
  }
  retryNow();
}

// ─── Doctor (F1.6) ───
// dvpnd reports advisories as OK=true with a Detail (e.g. a protocol binary missing): that is a warning.
export interface DoctorCheck { name: string; ok: boolean; level: CheckLevel; detail: string }
/** dvpnd's real advisories (OK=true + Detail): a protocol program or adapter missing, plan delegate. */
const ADVISORY = /^(service_|delegate$)/;

/**
 * `dvpnd doctor` runs as the desktop user, who by design cannot read the device key
 * (root 0700) or the service's database. When the service is up and answering it has
 * already loaded both, so those two denials are not failures (exported for tests). Q0547: nobody checked them
 * here either, so they are 'skip' (grey, no tick), in the fork 6.10 words; a row the fork already marks skip
 * passes through unchanged.
 */
export const SKIP_DETAIL = 'Checked by the VPN service when it starts (needs its rights)';
export function doctorForUser(rows: DoctorCheck[], serviceAnswers: boolean, isRoot: boolean): DoctorCheck[] {
  if (isRoot || !serviceAnswers) return rows;
  const denied = /permission denied|unable to open database/i;
  return rows.map((r) => {
    if (r.level === 'skip') return r;
    if (['key', 'kill_switch'].includes(r.name) && denied.test(r.detail)) {
      return { ...r, ok: true, level: 'skip', detail: SKIP_DETAIL };
    }
    // The privileges check asks whether THIS process is root; the service that answered is.
    if (r.name === 'privileges' && !r.ok && /must run as root/i.test(r.detail)) {
      return { ...r, ok: true, level: 'skip', detail: SKIP_DETAIL };
    }
    return r;
  });
}

export async function runDoctor(home = deviceRecord()?.home ?? DEFAULT_DAEMON_HOME): Promise<DoctorCheck[]> {
  const rows = await rawDoctor(home);
  let answers = false;
  try {
    await daemon().getVersion();
    answers = true;
  } catch (err) {
    log.debug('doctor: service not answering', { err: (err as Error).message });
  }
  const out = doctorForUser(rows, answers, process.getuid?.() === 0);
  if (fs.existsSync(SERVICE_PLIST)) {
    const stale = serviceStaleFiles();
    const names = stale.slice(0, 3).join(', ') + (stale.length > 3 ? ' …' : '');
    out.push(stale.length
      ? { name: 'service_update', ok: false, level: 'warn', detail: `The VPN service runs a different copy of ${names} than this app. Update it: devnet-dvpn daemon install --yes (one administrator prompt).` }
      : { name: 'service_update', ok: true, level: 'ok', detail: '' });
  }
  return out;
}

// ─── Service copies vs this app (a .dmg update has no post-install step) ───
/** Where setup-daemon.sh puts the root-owned copies the service runs. */
export const SERVICE_LIB = '/Library/devnet-dvpn';

function filesUnder(dir: string, rel = ''): string[] {
  const out: string[] = [];
  for (const e of fs.readdirSync(path.join(dir, rel), { withFileTypes: true })) {
    const r = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) out.push(...filesUnder(dir, r));
    else if (e.isFile()) out.push(r);
  }
  return out;
}

function sha(p: string): string | null {
  try {
    return createHash('sha256').update(fs.readFileSync(p)).digest('hex');
  } catch (err) {
    log.debug('service copy unreadable', { p, err: (err as Error).message });
    return null;
  }
}

/**
 * Files this app ships that the installed service runs from a different copy: dvpnd, the protocol
 * binaries and the root helper scripts (later prompts run the ROOT copy of the scripts).
 * Empty = up to date. Roots are parameters for tests.
 */
export function serviceStaleFiles(lib = SERVICE_LIB, bundleBin = path.dirname(binPath('x')), bundleScripts = path.dirname(scriptPath('x')), daemonBin = dvpndPath()): string[] {
  const bin = daemonBinaryName('darwin');
  const pairs: Array<[string, string, string]> = [[bin, daemonBin, path.join(lib, bin)]];
  for (const d of PROTOCOL_BIN_DIRS) {
    const src = path.join(bundleBin, d);
    if (fs.existsSync(src)) for (const r of filesUnder(src)) pairs.push([`${d}/${r}`, path.join(src, r), path.join(lib, d, r)]);
  }
  if (fs.existsSync(bundleScripts)) for (const r of filesUnder(bundleScripts)) pairs.push([`scripts/${r}`, path.join(bundleScripts, r), path.join(lib, 'scripts', r)]);
  return pairs.filter(([, a, b]) => {
    const ha = sha(a);
    return ha !== null && ha !== sha(b);
  }).map(([n]) => n);
}

/**
 * #31 470bac7 seam (Agent M): which service files run an older copy than this app ships. A .dmg update has no
 * post-install step, so a plain drag-over leaves dvpnd, the protocol binaries, the root scripts and (through
 * setup-daemon.sh) the LaunchDaemon plist on their old copies until Update the VPN service. Empty when the service
 * is not installed (no plist: a fresh machine sees setup, not this banner) or when every copy matches.
 */
export function serviceStaleNames(): string[] {
  if (!fs.existsSync(SERVICE_PLIST)) return [];
  return serviceStaleFiles();
}

/**
 * `dvpnd doctor` JSON rows. cf4c372 prints `name/ok/detail`; dfe36c7 printed `Name/OK/Detail`
 * (a v1 binary may still be on disk until the service is set up again). Exported for tests.
 */
export function parseDoctorRows(json: string): DoctorCheck[] {
  const rows = JSON.parse(json) as Array<Record<string, unknown>>;
  if (!Array.isArray(rows)) throw new Error('doctor output is not a list'); // copy:internal
  return rows.map((r) => {
    const ok = (r.ok ?? r.OK) === true;
    const name = String(r.name ?? r.Name ?? '?');
    let detail = String(r.detail ?? r.Detail ?? '');
    // dvpnd prints a raw `dvpnctl grant open-grant …` command here; say it in the app's words (idea from #32).
    if (name === 'grant' && !ok) detail = 'This computer has no spending limit yet. Set one: Wallet → Set spending limit, or devnet-dvpn device setup --yes.';
    // The kill-switch row is OK with a status note; "nothing held" is the normal state, not a warning
    // (owner's laptop 2026-10-22 showed it as "!").
    if (name === 'kill_switch' && ok && /no persisted kill switch/i.test(detail)) detail = 'Nothing held: internet is not blocked.';
    // cb33 rows carry a severity (ok = severity != "error"): it decides. Its normal kill-switch note
    // ("belongs to the running daemon's session; checks run unpinned") is severity ok, and a real
    // leftover says "left over" (two words), so text matching got both wrong. FLX, Linux port.
    const sev = typeof r.severity === 'string' ? r.severity.toLowerCase() : null;
    // Q0547: 'skip' = needs the service's rights, checked by the service at its start (grey, never ✓ or ✗).
    if (sev) return { name, ok, level: levelFromSeverity(sev, ok), detail };
    // Pre-cb33 daemons: no severity.
    if (name === 'kill_switch' && ok) return { name, ok, level: /unpinned|unusable|leftover/i.test(detail) ? 'warn' : 'ok', detail };
    return { name, ok, level: !ok ? 'fail' : detail && ADVISORY.test(name) ? 'warn' : 'ok', detail };
  });
}

function rawDoctor(home: string): Promise<DoctorCheck[]> {
  return new Promise((resolve) => {
    const exe = dvpndPath();
    if (!fs.existsSync(exe)) { resolve([{ name: 'binary', ok: false, level: 'fail', detail: 'dvpnd is not installed with this app.' }]); return; }
    execFile(exe, doctorArgs(home), { timeout: 60_000, env: withProtocolPath() }, (err, stdout, stderr) => {
      const text = String(stdout);
      const start = text.indexOf('[');
      if (start >= 0) {
        try {
          resolve(parseDoctorRows(text.slice(start)));
          return;
        } catch (parseErr) {
          log.warn('doctor output not JSON', { err: (parseErr as Error).message });
        }
      }
      resolve([{ name: 'doctor', ok: false, level: 'fail', detail: (err?.message ?? String(stderr)).slice(0, 300) }]);
    });
  });
}

// ─── First-run setup (F1.5) ───
// dvpnd will not start until its device key holds a grant, so setup is:
//   1. initDevice   — `dvpnd init` as the user into <data>/daemon-staging → device address
//   2. (owner signs device setup: delegate + grant + SOL — services/wallet.deviceSetup)
//   3. installService — ONE administrator prompt (osascript): copy into /Library/Application Support/sentinel-dvpn/c0, lock keys,
//      add the user to the 'dvpn' group, write + load the LaunchDaemon, link the CLI
export function stagingHome(): string {
  return path.join(getHost().dataDir, 'daemon-staging');
}

// ─── Wallet switch (rc.4 E-55, ported from #31 manager.ts) ───
// A switch to another wallet used to write device.json and the staging home FIRST, so any refusal after it
// (too little SOL, setup or install failing) left this computer recorded for the new wallet: the first
// wallet's deposits went unlisted and the next switch back stopped on "a half-finished setup" (macOS rc.3
// proof: hub tests/walk/evidence/macos-e55-repair-20261116). Now the new key is made in its own scratch folder,
// device.json and the staging home are never touched before the setup has landed AND the service runs the new
// key, and a failure leaves them byte-identical.
export function switchHome(): string {
  return path.join(getHost().dataDir, 'daemon-switch');
}
const SWITCH_FILE = 'switch.json';
interface SwitchRecord { device: string; owner: string; at: number }

/** The switch waiting in the scratch folder (its key may already hold a grant and fee SOL), or null. */
export function pendingSwitch(): SwitchRecord | null {
  try {
    const p = path.join(switchHome(), SWITCH_FILE);
    return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) as SwitchRecord : null;
  } catch (err) {
    log.warn('unreadable wallet-switch record', { err: (err as Error).message });
    return null;
  }
}

/** A device key for `owner` in the scratch folder (reused when one is already there for it). Writes nothing else. */
export function stageSwitchDevice(owner: string): Promise<{ ok: boolean; device?: string; error?: string }> {
  const have = pendingSwitch();
  if (have && have.owner === owner) return Promise.resolve({ ok: true, device: have.device });
  if (have) return Promise.resolve({ ok: false, error: `A switch to another wallet (${have.owner.slice(0, 4)}…${have.owner.slice(-4)}) was started and not finished. Load that wallet to finish it, or remove the half-finished setup (Diagnostics, or: devnet-dvpn device discard-setup --yes). Nothing was paid.` });
  const exe = dvpndPath();
  if (!fs.existsSync(exe)) return Promise.resolve({ ok: false, error: 'The VPN service is missing from this install. Reinstall the app.' });
  const scratch = switchHome();
  if (fs.existsSync(scratch)) fs.rmSync(scratch, { recursive: true, force: true }); // a folder with no record holds no key anyone uses
  return new Promise((resolve) => {
    execFile(exe, initArgs(scratch, owner), { timeout: 60_000 }, (err, stdout, stderr) => {
      const text = String(stdout);
      const at = text.indexOf('{');
      if (err || at < 0) {
        fs.rmSync(scratch, { recursive: true, force: true });
        resolve({ ok: false, error: `Could not set up the VPN service for this wallet. Try again, or send the log from Diagnostics (${(err?.message ?? String(stderr)).slice(0, 300)}).` });
        return;
      }
      try {
        const init = JSON.parse(text.slice(at)) as { public_key: string };
        carryLiveSettings(scratch);
        wholeDeviceByDefault(scratch);
        fs.writeFileSync(path.join(scratch, SWITCH_FILE), JSON.stringify({ device: init.public_key, owner, at: Date.now() } satisfies SwitchRecord));
        log.info('wallet switch staged', { device: init.public_key });
        resolve({ ok: true, device: init.public_key });
      } catch (parseErr) {
        fs.rmSync(scratch, { recursive: true, force: true });
        resolve({ ok: false, error: `Could not set up the VPN service for this wallet. Try again, or send the log from Diagnostics (unreadable output: ${(parseErr as Error).message}).` });
      }
    });
  });
}

/**
 * A setup left half done that Diagnostics offers to remove: a wallet switch waiting in the scratch folder, or a
 * staged install whose device record names another wallet than the loaded one (the rc.3 E-55 state). A staged
 * install for the loaded wallet is the normal "finish on the next Connect" and is not counted.
 */
export function halfFinishedSetup(loaded: string | null): boolean {
  if (pendingSwitch()) return true;
  if (!installPending()) return false;
  const rec = deviceRecord();
  return !rec || !loaded || rec.owner !== loaded;
}

/** The snapshot's view of the device record for the loaded wallet (AppSnapshot.deviceOwner / halfFinishedSetup). */
export function deviceStateFor(loaded: string | null): { deviceOwner: string | null; halfFinishedSetup: boolean } {
  try {
    return { deviceOwner: deviceRecord()?.owner ?? null, halfFinishedSetup: halfFinishedSetup(loaded) };
  } catch (err) {
    log.warn('device state unreadable', { err: (err as Error).message });
    return { deviceOwner: null, halfFinishedSetup: false };
  }
}

/** After the service runs the switched key: record it and drop the scratch folder. */
export function commitSwitch(s: SwitchRecord): void {
  writeJson(DEVICE_FILE, { device: s.device, home: DEFAULT_DAEMON_HOME, owner: s.owner, at: Date.now() } satisfies DeviceRecord);
  fs.rmSync(switchHome(), { recursive: true, force: true });
  log.info('wallet switch done', { device: s.device, owner: s.owner });
}

/**
 * The real "remove the half-finished setup". Removes the staging home and the switch scratch folder;
 * device.json and the installed service are kept. A switch key that already holds a grant is named in the
 * log so its refund can be found.
 */
export function discardHalfFinishedSetup(): { removed: string[] } {
  const removed: string[] = [];
  const sw = pendingSwitch();
  if (sw) log.warn('discarding a half-finished wallet switch', { device: sw.device, owner: sw.owner });
  for (const dir of [stagingHome(), switchHome()]) {
    if (fs.existsSync(dir)) { fs.rmSync(dir, { recursive: true, force: true }); removed.push(dir); }
  }
  return { removed };
}

/**
 * fleet-bugs W3: a wallet switch installs this fresh home in place of the old one, so copy the
 * user's settings (kill switch, DNS, LAN, split, RPC, payment limits, whole-device) into the new
 * staging home's ONE config.toml first. The source is the installed cb33 home (single config.toml)
 * if there is one, else a pre-cb33 pair home (config.toml + client/config.toml) for a first cb33
 * install over an old one. Nothing installed yet, or unreadable: the daemon's defaults stay.
 * `live`/`legacyHome` are injectable so unit tests stay hermetic (never read the real installed homes).
 */
export function carryLiveSettings(
  staging: string,
  live = DEFAULT_DAEMON_HOME,
  legacyHome = LEGACY_DAEMON_HOME,
): void {
  const freshPath = path.join(staging, 'config.toml');
  if (!fs.existsSync(freshPath)) return;
  const cb33 = path.join(live, 'config.toml');
  const legacyRoot = path.join(legacyHome, 'config.toml');
  const legacyClient = path.join(legacyHome, 'client', 'config.toml');
  // old = {root, client}: for a cb33 source both are the one file (it holds every key); for a pair
  // home they are the two old files. svcBase = where the per-service config.toml live in the source.
  let old: { root: string; client: string } | null = null;
  let svcBase = '';
  if (fs.existsSync(cb33)) {
    const t = fs.readFileSync(cb33, 'utf8');
    old = { root: t, client: t };
    svcBase = live;
  } else if (fs.existsSync(legacyRoot) && fs.existsSync(legacyClient)) {
    old = { root: fs.readFileSync(legacyRoot, 'utf8'), client: fs.readFileSync(legacyClient, 'utf8') };
    svcBase = path.join(legacyHome, 'client');
  }
  if (!old) return;
  try {
    fs.writeFileSync(freshPath, carrySettingsInto(old, fs.readFileSync(freshPath, 'utf8')), 'utf8');
    for (const s of TUN_SERVICES) {
      const from = path.join(svcBase, s, 'config.toml');
      const into = path.join(staging, s, 'config.toml');
      if (!fs.existsSync(from) || !fs.existsSync(into)) continue;
      const tun = readToml(fs.readFileSync(from, 'utf8'), '', 'tun');
      if (typeof tun === 'boolean') fs.writeFileSync(into, renderServiceConfig(fs.readFileSync(into, 'utf8'), tun), 'utf8');
    }
    log.info('settings carried to the new device home', { from: svcBase });
  } catch (err) {
    log.warn('could not carry settings to the new device home; daemon defaults stay', { error: (err as Error).message });
  }
}

/**
 * Owner 2026-11-12 (#31 5b98716): V2Ray and Xray use the whole computer by default. `init` writes
 * tun = false; a fresh install (no service config for that protocol in the installed cb33 home or
 * a pre-cb33 pair home) gets tun = true. A choice the user already made is carried by
 * carryLiveSettings and kept. `live`/`legacyHome` are injectable for hermetic tests.
 */
export function wholeDeviceByDefault(staging: string, live = DEFAULT_DAEMON_HOME, legacyHome = LEGACY_DAEMON_HOME): void {
  for (const s of TUN_SERVICES) {
    const into = path.join(staging, s, 'config.toml');
    if (!fs.existsSync(into)) continue;
    if (fs.existsSync(path.join(live, s, 'config.toml')) || fs.existsSync(path.join(legacyHome, 'client', s, 'config.toml'))) continue;
    try {
      fs.writeFileSync(into, renderServiceConfig(fs.readFileSync(into, 'utf8'), true), 'utf8');
    } catch (err) {
      log.warn('could not turn on whole computer for a new install', { service: s, error: (err as Error).message });
    }
  }
}

/**
 * Q0507 (release blocker, DIR 11-12): `dvpnd init` writes kill_switch = 'on' and setup-daemon.sh's
 * migration turns 'on' into 'persist', so a fresh install came up with the kill switch "Always"
 * nobody chose (connect, reboot = no internet). A fresh install (no installed cb33 home and no
 * pre-cb33 home to carry from) is written 'off'; an upgrade keeps the user's value (carryLiveSettings).
 */
export function killSwitchOffByDefault(staging: string, live = DEFAULT_DAEMON_HOME, legacyHome = LEGACY_DAEMON_HOME): void {
  const into = path.join(staging, 'config.toml');
  if (!fs.existsSync(into)) return;
  if (fs.existsSync(path.join(live, 'config.toml')) || fs.existsSync(path.join(legacyHome, 'config.toml'))) return;
  try {
    fs.writeFileSync(into, patchToml(fs.readFileSync(into, 'utf8'), 'network', 'kill_switch', 'off'), 'utf8');
    log.info('fresh install: kill switch off');
  } catch (err) {
    log.warn('could not set the kill switch off for a new install', { error: (err as Error).message });
  }
}

export function initDevice(owner: string): Promise<{ ok: boolean; device?: string; error?: string }> {
  const existing = deviceRecord();
  if (existing && existing.owner === owner) return Promise.resolve({ ok: true, device: existing.device });
  const exe = dvpndPath();
  if (!fs.existsSync(exe)) return Promise.resolve({ ok: false, error: 'The VPN service is missing from this install. Reinstall the app.' });
  const staging = stagingHome();
  if (fs.existsSync(path.join(staging, 'config.toml'))) {
    return Promise.resolve({ ok: false, error: 'A half-finished setup exists. Remove it in Diagnostics (or: devnet-dvpn device discard-setup --yes), then try again. Nothing was paid.' });
  }
  // cb33: `init --instance c0 --home <staging> --owner <o> --plain-key`. --instance c0 sets the
  // role (c = client), so there is no --role. No group is set here: the daemon gives the socket its
  // group only when run as the real instance (setup-daemon.sh installs the home there and the
  // service `run --instance c0` applies the group).
  const args = initArgs(staging, owner);
  return new Promise((resolve) => {
    execFile(exe, args, { timeout: 60_000 }, (err, stdout, stderr) => {
      const text = String(stdout);
      const at = text.indexOf('{');
      if (err || at < 0) { resolve({ ok: false, error: `Could not set up the VPN service. Try again, or send the log from Diagnostics (${(err?.message ?? String(stderr)).slice(0, 300)}).` }); return; }
      try {
        const init = JSON.parse(text.slice(at)) as { public_key: string };
        writeJson(DEVICE_FILE, { device: init.public_key, home: DEFAULT_DAEMON_HOME, owner, at: Date.now() } satisfies DeviceRecord);
        log.info('device initialised', { device: init.public_key });
        carryLiveSettings(staging);
        wholeDeviceByDefault(staging);
        killSwitchOffByDefault(staging);
        resolve({ ok: true, device: init.public_key });
      } catch (parseErr) {
        resolve({ ok: false, error: `Could not set up the VPN service. Try again, or send the log from Diagnostics (unreadable output: ${(parseErr as Error).message}).` });
      }
    });
  });
}

/**
 * The Mac short name of the person running the app (the elevated step adds it to the socket group; Homebrew runs as it).
 * macOS allows dots and capitals. Takes the first valid non-root name of SUDO_USER, USER, LOGNAME: an app started through
 * `sudo` from a root shell carries SUDO_USER=root, and that must fall back to USER, not give no one access (Q0572).
 */
export function loginName(env: NodeJS.ProcessEnv = process.env): string {
  for (const n of [env.SUDO_USER, env.USER, env.LOGNAME]) {
    if (n && n !== 'root' && /^[A-Za-z_][A-Za-z0-9_.-]{0,31}$/.test(n)) return n;
  }
  return '';
}

/** The bundled CLI launcher (Contents/Resources/bin/devnet-dvpn in the app); setup links it into /usr/local/bin. */
export function cliLauncherPath(): string | null {
  const p = path.join(path.dirname(resourcesDir()), 'bin', 'devnet-dvpn');
  return fs.existsSync(p) ? p : null;
}

/** L6: poll (bounded) until `probe` is true; probes and sleep are injectable (exported for tests). */
export async function pollUntil(
  probe: () => Promise<boolean>,
  waitMs = 30_000,
  stepMs = 2_000,
  sleep: (ms: number) => Promise<void> = (ms) => new Promise((r) => setTimeout(r, ms)),
): Promise<boolean> {
  for (let waited = 0; ; waited += stepMs) {
    if (await probe()) return true;
    if (waited + stepMs > waitMs) return false;
    await sleep(stepMs);
  }
}

function unitRunning(): Promise<boolean> {
  return new Promise((resolve) => {
    execFile('launchctl', ['print', `system/${SERVICE_LABEL}`], { timeout: 10_000 }, (_err, stdout) => resolve(/state = running/.test(String(stdout))));
  });
}

/** After the install step ran past its time limit: did the service come up anyway? */
async function verifyInstalled(home: string): Promise<ElevatedResult> {
  const up = await pollUntil(async () => (await unitRunning()) && fs.existsSync(path.join(home, 'daemon.sock')));
  if (up) {
    log.info('install step timed out but the service is running', { service: SERVICE_LABEL });
    return { status: 'ok', detail: 'service installed and running (the administrator step took longer than expected)' };
  }
  return { status: 'error', detail: 'The administrator step took too long and the VPN service is off. Try again; if it keeps happening, send the log from Diagnostics.' };
}

/**
 * The service is installed but refuses this account (a macOS user who did not run setup). One
 * administrator step (grant-socket.sh) adds this account to the socket group and its ACL entries,
 * without touching anyone else's; no log out. Same name as #31 a2edc22 (shared connection.ts calls it).
 */
export async function grantPipeAccess(): Promise<{ ok: boolean; error?: string }> {
  const user = loginName();
  if (!user) return { ok: false, error: 'Could not tell which Mac account is running the app. Set the VPN service up again from Wallet.' };
  // Prompts run the root-owned script copy from the last setup. One from before this step existed has
  // no grant-socket; never fall back to the app bundle's (user-writable) copy as root.
  if (fs.existsSync(path.join(ROOT_SCRIPTS_DIR, 'dvpn-helper')) && !fs.existsSync(path.join(ROOT_SCRIPTS_DIR, 'grant-socket.sh'))) {
    return { ok: false, error: 'This Mac has the VPN service from an older version. Set it up again once from Wallet, then connect.' };
  }
  const r = await runElevated(scriptPath('grant-socket.sh'), { DaemonHome: deviceRecord()?.home ?? DEFAULT_DAEMON_HOME, User: user, Group: SOCKET_GROUP });
  log.info('socket access grant', { status: r.status, detail: r.detail });
  if (r.status === 'ok') noteServiceStarting();
  relinkDaemon();
  return r.status === 'ok' ? { ok: true } : { ok: false, error: r.detail };
}

/** A device key made for a new wallet waits in the staging home until the service is (re)installed. */
export function installPending(): boolean {
  return fs.existsSync(path.join(stagingHome(), 'config.toml'));
}

/** Elevated: move the staged home into /var/db/dvpnd and run it as a LaunchDaemon. Call after device setup. */
/**
 * Shared seam (Linux Q0431: the recorded service home is gone). macOS keeps a fixed home that uninstall
 * leaves in place with the device key, and an unreadable parent (user not yet in the group) must not read
 * as gone: never.
 */
export function deviceHomeGone(): string | null {
  return null;
}

/** `staging` = the home to install: the staging home, or the wallet-switch scratch folder (rc.4 E-55, #31 b15c05f). */
export async function installService(staging = stagingHome()): Promise<{ ok: boolean; error?: string; waitingForNetwork?: boolean; data?: { relogin: boolean } }> {
  const rec = deviceRecord();
  if (!rec) return { ok: false, error: 'Initialise the device first.' };
  const user = loginName();
  const cli = cliLauncherPath();
  installing += 1; // shared serviceInstallRunning(): nothing else starts the service while its installer runs
  let r: ElevatedResult;
  try {
    r = await runElevated(scriptPath('setup-daemon.sh'), {
      Dvpnd: dvpndPath(), Staging: staging, DaemonHome: rec.home, BinRoot: path.dirname(binPath('x')),
      Group: SOCKET_GROUP, Service: SERVICE_NAME, Instance: CLIENT_INSTANCE, Label: SERVICE_LABEL,
      ...(user ? { User: user } : {}), ...(cli ? { Cli: cli } : {}),
    }, 300_000, () => verifyInstalled(rec.home));
  } finally {
    installing -= 1;
  }
  if (r.status === 'ok') noteServiceStarting();
  relinkDaemon();
  // waitingForNetwork: installed, but dvpnd checks the RPC before it serves; launchd retries every minute.
  return r.status === 'ok' ? { ok: true, ...(r.waitingForNetwork === true ? { waitingForNetwork: true } : {}) } : { ok: false, error: r.detail };
}

/**
 * Elevated: remove the service (uninstall-cleanup.sh). A .dmg has no uninstall hook, so this is
 * the Mac's uninstaller: networking put back, LaunchDaemon + root copies + CLI link removed,
 * the device key kept in /var/db/dvpnd (it holds an on-chain permission and SOL).
 */
export async function uninstallService(): Promise<{ ok: boolean; error?: string; detail?: string }> {
  // dvpnd keeps a held or persist-mode kill switch in its database (kept on uninstall with the
  // device key) and re-applies it on its next start. Without this a reinstall blocked the
  // internet with the kill switch set to off (#33 rig 2, safety-armed). StopSession with no
  // session releases it; "not found" means nothing was held.
  if (info.reachable) {
    try {
      await daemon().stopSession('', {});
    } catch (err) {
      if (!(err instanceof DaemonError && err.kind === 'not-found')) log.warn('releasing the kill switch before uninstall', { err: (err as Error).message });
    }
  }
  const r = await runElevated(scriptPath('uninstall-cleanup.sh'), {}, 300_000);
  relinkDaemon();
  return r.status === 'ok' ? { ok: true, detail: r.detail } : { ok: false, error: r.detail };
}

export type ServiceStart = 'running' | 'started' | 'no-service' | 'no-right' | 'failed';

/** What `launchctl kickstart` printed / its exit code means for the caller (exported for tests). */
export function classifyServiceStart(code: number, stderr: string): ServiceStart {
  if (code === 0) return 'started';
  if (/could not find service|no such process|not loaded/i.test(stderr)) return 'no-service';
  if (/not privileged|operation not permitted|permission denied/i.test(stderr)) return 'no-right';
  return 'failed';
}

/**
 * Start the installed service if it is not running, without a password prompt. dvpnd refuses to
 * start until the device has a grant; launchd (KeepAlive, ThrottleInterval 60 s) starts it again
 * within a minute of device setup on its own. A non-admin cannot kickstart a system daemon, so
 * this only tries it and otherwise reports 'no-right' (the caller says "starts within a minute").
 */
export function startServiceIfStopped(): Promise<ServiceStart> {
  return (async () => {
    if (!fs.existsSync(SERVICE_PLIST)) return 'no-service';
    if (fs.existsSync(daemonSocket()) && info.reachable) return 'running';
    const s = await new Promise<{ code: number; err: string }>((resolve) => {
      execFile('launchctl', ['kickstart', `system/${SERVICE_LABEL}`], { timeout: 30_000 }, (err, _stdout, stderr) => {
        resolve({ code: err ? (typeof (err as { code?: unknown }).code === 'number' ? Number((err as { code?: unknown }).code) : 1) : 0, err: String(stderr) });
      });
    });
    const r = classifyServiceStart(s.code, s.err);
    if (r === 'started') { noteServiceStarting(); relinkDaemon(); }
    else if (r !== 'no-right') log.warn('service start failed', { code: s.code, err: s.err.slice(0, 300) });
    return r;
  })();
}

/**
 * The account an elevated step is for (shared name, #31 8070712). macOS: the login short name (loginName), never
 * a Windows DOMAIN\user. Empty = no app user (root): the steps that need a user then refuse.
 */
export function appUserAccount(env: NodeJS.ProcessEnv = process.env): string {
  return loginName(env);
}

// ─── The one button (#31 baff369, UI pass rows 119-142) ───
/** Wait (with the fast retry on) until the service answers, at most maxMs. */
async function waitAnswer(maxMs: number): Promise<boolean> {
  return withLinkWatch(async () => {
    const until = Date.now() + maxMs;
    while (!info.reachable && Date.now() < until) await new Promise((r) => setTimeout(r, 250));
    return info.reachable;
  });
}

export interface FixResult { ok: boolean; error?: string; code?: string; data?: { did: string; state: string } }

/**
 * Do the one action of the state the service is in now, then wait for it to answer (IPC DAEMON_INIT step 'fix').
 * install / reinstall / finish-setup ask for an administrator once. start: a non-admin cannot kickstart a system
 * LaunchDaemon ('no-right'), so on macOS the start button re-runs the setup step (one prompt), which bootstraps it.
 */
export async function fixService(): Promise<FixResult> {
  const v = serviceNow();
  const done = (did: string): FixResult => {
    const now = serviceNow();
    return now.state === 'ready' ? { ok: true, data: { did, state: now.state } } : { ok: false, error: now.sentence, code: now.code ?? 'daemon-unavailable', data: { did, state: now.state } };
  };
  log.info('service fix', { state: v.state, action: v.action });
  if (v.state === 'ready') return { ok: true, data: { did: 'none', state: v.state } };
  if (v.action === null) { // starting, restarting: nothing to press, wait for it
    retryNow();
    await waitAnswer(30_000);
    return done('wait');
  }
  if (v.action === 'start') {
    const r = await startServiceIfStopped();
    if (r === 'no-service') { osState = { installed: false, running: false, startPending: false }; setError(); emit(); return done('start'); }
    if (r === 'failed') return { ok: false, error: 'The VPN service did not start. Open Diagnostics and run the check to see why.', code: 'service-start-failed', data: { did: 'start', state: v.state } };
    if (r === 'no-right') {
      const i = await installService();
      if (!i.ok) return { ok: false, error: i.error, code: 'service-install-failed', data: { did: 'install', state: v.state } };
    }
    await waitAnswer(30_000);
    return done('start');
  }
  if (v.action === 'install' || v.action === 'reinstall') {
    const i = await installService();
    if (!i.ok) return { ok: false, error: i.error, code: 'service-install-failed', data: { did: v.action, state: v.state } };
    await waitAnswer(30_000);
    return done(v.action);
  }
  if (v.action === 'finish-setup') {
    const g = await grantPipeAccess();
    if (!g.ok) return { ok: false, error: g.error ?? v.sentence, code: 'daemon-relogin', data: { did: 'finish-setup', state: v.state } };
    await waitAnswer(30_000);
    return done('finish-setup');
  }
  // repair: a fresh link first (no administrator); only if the service then refuses this account, the grant.
  relinkDaemon();
  if (!await waitAnswer(10_000) && serviceNow().state === 'no-permission') {
    const g = await grantPipeAccess();
    if (!g.ok) return { ok: false, error: g.error ?? serviceNow().sentence, code: 'daemon-relogin', data: { did: 'repair', state: serviceNow().state } };
    await waitAnswer(30_000);
  }
  return done('repair');
}

/** Public half only, written world-readable by setup-daemon.sh (the key folder is root 0700). */
export const DEVICE_PUB_FILE = 'device.pub';

/** The device address a home publishes in device.pub, or null (exported for tests). */
export function readDevicePub(home: string): string | null {
  try {
    const v = fs.readFileSync(path.join(home, DEVICE_PUB_FILE), 'utf8').trim();
    return /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(v) ? v : null;
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code !== 'ENOENT' && code !== 'EACCES') log.warn('device.pub unreadable', { err: (err as Error).message });
    return null;
  }
}

/**
 * The device public key of an existing home: device.pub first (no secret needed), else
 * `dvpnd key list` (cf4c372; was `keys`), which only works when the key folder is readable (e.g. as root).
 */
export function detectDevice(home = DEFAULT_DAEMON_HOME): Promise<{ ok: boolean; device?: string; error?: string }> {
  const pub = readDevicePub(home);
  if (pub) return Promise.resolve({ ok: true, device: pub });
  const exe = dvpndPath();
  if (!fs.existsSync(exe)) return Promise.resolve({ ok: false, error: 'The VPN service is missing from this install. Reinstall the app.' });
  return new Promise((resolve) => {
    execFile(exe, keyListArgs(home), { timeout: 20_000 }, (err, stdout, stderr) => {
      const text = String(stdout);
      const at = text.indexOf('[');
      if (err || at < 0) { resolve({ ok: false, error: `Could not read the service's device key (${(err?.message ?? String(stderr)).trim().slice(0, 160)}). Enter its address instead.` }); return; }
      try {
        const keys = JSON.parse(text.slice(at)) as Array<{ name: string; public_key: string }>;
        const dev = operatorKey(keys);
        resolve(dev ? { ok: true, device: dev.public_key } : { ok: false, error: 'The service home has no device key.' });
      } catch (parseErr) {
        resolve({ ok: false, error: `Could not read the service's device key (unreadable output: ${(parseErr as Error).message}). Enter its address instead.` });
      }
    });
  });
}

/** Record an already-initialised daemon's device key (e.g. service set up by an admin). */
export function registerDevice(device: string, owner: string, home = DEFAULT_DAEMON_HOME): void {
  if (!/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(device)) throw new Error('The device must be a Solana address (base58).');
  writeJson(DEVICE_FILE, { device, home, owner, at: Date.now() } satisfies DeviceRecord);
}

/**
 * Android: the app restarts its own VPN engine (Restore network when dvpnd does not answer). The desktop
 * runs dvpnd as a system service the user restarts, so this is never reached here (connection.ts calls
 * it only on isAndroid()); the platform export keeps that shared file identical on every OS.
 */
export async function restartAndroidDaemon(): Promise<{ ok: boolean; error?: string }> {
  return { ok: false, error: 'Only the Android app restarts its own VPN engine.' };
}
