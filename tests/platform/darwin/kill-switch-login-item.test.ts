// ─── macOS: while the kill switch is on the app starts at log-in (#31 edc3751, owner 2026-11-13) ───
// The Mac log-in item is a per-user LaunchAgent (system/autostart.ts), not Electron's app.setLoginItemSettings.
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

describe('macOS log-in item follows the kill switch', () => {
  const main = readFileSync('src/main/index.ts', 'utf8');
  it('the app writes the LaunchAgent from loginItemWanted, on start, settings and service changes', () => {
    expect(main).toContain('const openAtLogin = loginItemWanted(startWithOs, killSwitch);');
    expect(main).toContain('try { setStartWithOs(openAtLogin, exe); }');
    expect(main).toContain("onSettingsChanged(() => loginItem('settings'));");
    expect(main).toContain("onDaemonChange(() => loginItem('daemon change'));");
    expect(main).toContain("setInterval(() => loginItem('tick'), LOGIN_ITEM_TICK_MS).unref();");
    expect(main).toContain('osSays: startWithOsActive()');
  });
  it('negative control: no Electron login-item call on macOS', () => {
    expect(main).not.toContain('setLoginItemSettings');
  });
  it('the CLI applies the same rule in one place (shared info-cmd.ts), the Mac layer only writes the LaunchAgent', () => {
    expect(readFileSync('src/cli/info-cmd.ts', 'utf8')).toContain('applyStartWithOsFromCli(loginItemWanted(next.startWithOs, getDaemonSettings().settings.killSwitch))');
    expect(readFileSync('src/main/system/autostart.ts', 'utf8')).not.toContain('loginItemWanted');
  });
});
