// ─── Start at login (F18 startWithOs) — macOS ───
// A per-user LaunchAgent in ~/Library/LaunchAgents: launchd starts the app hidden at login. Same
// file from the app (main/index.ts, on start and on every settings change) and the CLI
// (`settings set|reset`, applyStartWithOsFromCli). Electron's login-item API is app-only, so the
// CLI could not use it. Removing the file turns it off; nothing needs root.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { log } from '../logger';

export const AUTOSTART_LABEL = 'network.sentinel.devnet-dvpn.app';
export const AUTOSTART_NAME = `${AUTOSTART_LABEL}.plist`;

export function autostartPath(home = os.homedir()): string {
  return path.join(home, 'Library', 'LaunchAgents', AUTOSTART_NAME);
}

const xml = (s: string): string => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/** The LaunchAgent plist text (exported for tests). `exec` is the app binary (…/Contents/MacOS/Devnet dVPN). */
export function autostartEntry(exec: string): string {
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0">',
    '<dict>',
    `  <key>Label</key><string>${AUTOSTART_LABEL}</string>`,
    '  <key>ProgramArguments</key>',
    `  <array><string>${xml(exec)}</string><string>--hidden</string></array>`,
    '  <key>RunAtLoad</key><true/>',
    '  <key>ProcessType</key><string>Interactive</string>',
    '</dict>',
    '</plist>',
    '',
  ].join('\n');
}

/** Write or remove the LaunchAgent so it matches `on`. */
export function setStartWithOs(on: boolean, exec: string): void {
  const p = autostartPath();
  try {
    if (on) {
      const want = autostartEntry(exec);
      // Called on every service change too (#31 edc3751): skip the write when the LaunchAgent already matches.
      if (fs.existsSync(p) && fs.readFileSync(p, 'utf8') === want) return;
      fs.mkdirSync(path.dirname(p), { recursive: true });
      fs.writeFileSync(p, want, 'utf8');
    } else if (fs.existsSync(p)) {
      fs.rmSync(p, { force: true });
    }
  } catch (err) {
    log.warn('login item not updated', { on, err: (err as Error).message });
  }
}

/** The app binary when this process runs from the bundle: the app itself, or the CLI (its wrapper
 *  runs …/Contents/MacOS/Devnet dVPN with ELECTRON_RUN_AS_NODE). null from a dev tree or plain node. */
export function bundleExecutable(execPath = process.execPath): string | null {
  return /\.app\/Contents\/MacOS\/[^/]+$/.test(execPath) ? execPath : null;
}

/** CLI side of `settings set|reset startWithOs`: write or remove the same LaunchAgent the app does.
 *  Returns a note when it can't (not run from the app bundle); the app applies it when it opens.
 *  `on` is already the decision: the shared CLI (info-cmd.ts) applies the kill switch log-in rule. */
export function applyStartWithOsFromCli(on: boolean, execPath = process.execPath): string | null {
  const exe = bundleExecutable(execPath);
  if (exe) {
    setStartWithOs(on, exe);
    return null;
  }
  return 'Start at login takes effect the next time the app opens (this command line is not running from the app).';
}

export function startWithOsActive(): boolean {
  return fs.existsSync(autostartPath());
}
