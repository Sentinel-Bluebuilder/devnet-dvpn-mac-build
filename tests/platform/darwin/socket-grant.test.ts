// ─── A second macOS account gets the service socket with no log out (port of #31 a2edc22) ───
// The Mac twin of #31's pipe-grant.test.ts: grant-socket.sh is a whitelisted root step that only
// ADDS ACL entries (clearing the ACL would lock out the account that ran setup).
import fs from 'node:fs';
import { describe, expect, it } from 'vitest';
import { HELPER_STEPS, helperArgs } from '../../../src/main/system/elevate';

const script = fs.readFileSync('resources/scripts/grant-socket.sh', 'utf8');
const code = script.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');
const manager = fs.readFileSync('src/main/daemon/manager.ts', 'utf8');

describe('grant-socket step', () => {
  it('is whitelisted in the app and in dvpn-helper', () => {
    expect(HELPER_STEPS).toContain('grant-socket');
    expect(fs.readFileSync('resources/scripts/dvpn-helper', 'utf8')).toMatch(/\|grant-socket\)/);
    expect(helperArgs('grant-socket', { DaemonHome: '/Library/Application Support/sentinel-dvpn/c0', User: 'zoe' }))
      .toEqual(['grant-socket', '--DaemonHome', '/Library/Application Support/sentinel-dvpn/c0', '--User', 'zoe']);
  });

  it('never clears an ACL, so the account that ran setup keeps access', () => {
    expect(code).not.toMatch(/chmod\s+-N/);
    expect(code).toMatch(/chmod \+a "user:\$USER_NAME allow \$1"/);
  });

  it('checks the home, the user (never root) and the group before it changes anything', () => {
    const firstChange = code.indexOf('dseditgroup -o edit');
    for (const guard of ['under "$HOME_DIR" "$DAEMON_ROOT"', '!= root', 'id -u "$USER_NAME"', 'GROUP" =~']) {
      const at = code.indexOf(guard);
      expect(at, guard).toBeGreaterThan(-1);
      expect(at, guard).toBeLessThan(firstChange);
    }
  });

  it('grants the same entries setup-daemon.sh gives the setup user, plus the live socket', () => {
    for (const perms of ['search,readattr', 'list,search,read,write,readattr,readextattr,file_inherit', 'list,search,readattr', 'read,readattr']) {
      expect(code).toContain(`'${perms}'`);
    }
    expect(code).toContain('"$HOME_DIR/daemon.sock"');
  });

  it('the app exports the names shared code imports', () => {
    expect(manager).toMatch(/export async function grantPipeAccess\(\): Promise<\{ ok: boolean; error\?: string \}>/);
    expect(manager).toMatch(/export function installPending\(\): boolean/);
    expect(manager).toContain("runElevated(scriptPath('grant-socket.sh')");
  });

  it('an older root script copy without the step gets a plain message, never the bundle copy as root', () => {
    const body = manager.slice(manager.indexOf('export async function grantPipeAccess'), manager.indexOf('export function installPending'));
    expect(body).toContain("!fs.existsSync(path.join(ROOT_SCRIPTS_DIR, 'grant-socket.sh'))");
    expect(body.indexOf('older version')).toBeGreaterThan(-1);
    expect(body.indexOf('older version')).toBeLessThan(body.indexOf("runElevated(scriptPath('grant-socket.sh')"));
  });
});
