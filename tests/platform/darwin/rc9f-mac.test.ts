// ─── rc9-f-mac: M33-1 (H), M33-3 (M), M33-11 (M) from the #33 macOS audit (hub docs/AUDIT-COVERAGE-33-macos.md) ───
// M33-1: root copied the user's staged files with root's rights; symbolic links were refused but HARD links were not
// (macOS has no protected_hardlinks), so a staged config.toml hard-linked to a root-only file put that file's bytes in
// a home file the setup user can read. Now the user's own tar / head reads them (_lib.sh copy_as_user, as_user), a
// file with more than one name is refused, and apply's --Staged must resolve under the --User's real home.
// M33-3: uninstall restored EVERY account's proxy-backup.json and took "is it still ours" from the same file. Now
// only the --User app user's own backup, owned by that user, and `ours` must be 127.0.0.1:<port>.
// M33-11: the macOS keyfile-read-only next named PowerShell's Remove-Item; it is `unset DVPN_KEYFILE` now.
// The _lib.sh cases run the real functions under bash (no root needed); the script cases pin the order of the steps.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { cliKeyStore, KEYFILE_RO_NEXT } from '../../../src/cli/keystore';

const lib = path.resolve('resources/scripts/_lib.sh');
const read = (f: string): string => fs.readFileSync(f, 'utf8');
const code = (s: string): string => s.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');
const me = os.userInfo().username;
const isRoot = typeof process.getuid === 'function' && process.getuid() === 0;

/** Runs `source _lib.sh; <fn> args...` under bash; returns the exit code. */
function libRun(fn: string, ...args: string[]): number {
  const r = spawnSync('/bin/bash', ['-c', `source "${lib}"; ${fn} "$@"`, 'x', ...args], { encoding: 'utf8' });
  return r.status ?? 1;
}
const tmp = (p: string): string => fs.mkdtempSync(path.join(os.tmpdir(), p));

describe('M33-1: the staged home is read with the user\'s rights', () => {
  it.skipIf(isRoot)('a staged config.toml hard-linked to a file the user may not read is NOT copied', () => {
    const t = tmp('m331-');
    const secret = path.join(t, 'root-only');
    fs.writeFileSync(secret, 'ROOT-ONLY-SECRET\n');
    const staging = path.join(t, 'daemon-staging');
    fs.mkdirSync(staging);
    fs.linkSync(secret, path.join(staging, 'config.toml')); // the hard link the user can make to a file it cannot read
    fs.chmodSync(secret, 0o000);
    const dst = path.join(t, 'copy');
    fs.mkdirSync(dst, { mode: 0o700 });
    expect(libRun('declare -F', 'copy_as_user')).toBe(0); // the user-rights copy exists (a missing one also "fails")
    expect(libRun('copy_as_user', me, staging, dst)).not.toBe(0);
    const leaked = fs.existsSync(path.join(dst, 'config.toml')) && fs.readFileSync(path.join(dst, 'config.toml'), 'utf8').includes('ROOT-ONLY');
    expect(leaked).toBe(false);
  });

  it('has_hardlink finds a file with two names and passes a plain folder', () => {
    const t = tmp('m331h-');
    fs.writeFileSync(path.join(t, 'a'), 'x');
    expect(libRun('has_hardlink', t)).toBe(1);
    fs.linkSync(path.join(t, 'a'), path.join(t, 'b'));
    expect(libRun('has_hardlink', t)).toBe(0);
  });

  it('negative control: a plain staged home copies, and the copy folder stays root-only (0700)', () => {
    const t = tmp('m331c-');
    const staging = path.join(t, 'daemon-staging');
    fs.mkdirSync(path.join(staging, 'keys'), { recursive: true });
    fs.writeFileSync(path.join(staging, 'config.toml'), 'owner = "x"\n');
    fs.writeFileSync(path.join(staging, 'keys', 'operator.json'), '{}');
    const dst = path.join(t, 'copy');
    fs.mkdirSync(dst, { mode: 0o700 });
    expect(libRun('copy_as_user', me, staging, dst)).toBe(0);
    expect(fs.readFileSync(path.join(dst, 'config.toml'), 'utf8')).toBe('owner = "x"\n');
    expect(fs.existsSync(path.join(dst, 'keys', 'operator.json'))).toBe(true);
    expect(fs.statSync(dst).mode & 0o777).toBe(0o700);
  });

  it('setup-daemon.sh: no root cp from staging; the user read, then the symlink and hard-link refusals, then the home copy', () => {
    const s = code(read('resources/scripts/setup-daemon.sh'));
    expect(s).not.toMatch(/cp -Rp "\$STAGING\/\."/);
    const user = s.indexOf('copy_as_user "$USER_NAME" "$STAGING" "$copy"');
    const sym = s.indexOf('find "$copy" -type l');
    const hard = s.indexOf('has_hardlink "$copy"');
    const home = s.indexOf('cp -Rp "$copy/." "$HOME_DIR/"');
    expect(user).toBeGreaterThan(-1);
    expect(user).toBeLessThan(sym);
    expect(sym).toBeLessThan(hard);
    expect(hard).toBeLessThan(home);
    expect(s).toMatch(/\[ -n "\$USER_NAME" \] \|\| die "a staged home needs --User/);
  });

  it('apply-daemon-config.sh: --Staged under the --User home, each file read by that user, a second name refused', () => {
    const s = code(read('resources/scripts/apply-daemon-config.sh'));
    expect(s).not.toMatch(/cp -RP -- "\$\{SRC\[\$i\]\}"/);
    expect(s).toMatch(/case "\$staged_real" in "\$user_home_real"\/\?\*\) ;;/);
    expect(s).toMatch(/stat -f %l -- "\$\{SRC\[\$i\]\}"/);
    expect(s).toMatch(/as_user "\$USER_NAME" head -c 65537 -- "\$\{SRC\[\$i\]\}" > "\$snap\/\$i"/);
    expect(s.indexOf('staged_real=')).toBeLessThan(s.indexOf('snap="$(mktemp -d'));
  });

  it('settings.ts passes --User to apply-daemon-config', () => {
    expect(read('src/main/daemon/settings.ts')).toMatch(/runElevated\(scriptPath\('apply-daemon-config\.sh'\), \{[^}]*\.\.\.\(user \? \{ User: user \} : \{\}\)/);
  });
});

describe('M33-3: uninstall restores only the app user\'s own proxy backup', () => {
  it('proxy_ours_ok takes only 127.0.0.1:<port>', () => {
    expect(libRun('proxy_ours_ok', '127.0.0.1:1080')).toBe(0);
    for (const bad of ['203.0.113.9:1080', '127.0.0.1', '127.0.0.1:1080 x', '', '127.0.0.10:1080', 'localhost:1080']) {
      expect(libRun('proxy_ours_ok', bad), bad).not.toBe(0);
    }
  });

  it('proxy_restore_ok takes a host + port and nothing else', () => {
    expect(libRun('proxy_restore_ok', '', '0')).toBe(0);
    expect(libRun('proxy_restore_ok', 'proxy.example.com', '8080')).toBe(0);
    expect(libRun('proxy_restore_ok', 'a b', '1')).not.toBe(0);
    expect(libRun('proxy_restore_ok', 'h', '1;x')).not.toBe(0);
  });

  it('uninstall-cleanup.sh reads no other account\'s backup, checks its owner, and checks every row before networksetup', () => {
    const s = code(read('resources/scripts/uninstall-cleanup.sh'));
    expect(s).not.toMatch(/\/Users\/\*\//);
    expect(s).toMatch(/\[ "\$\(stat -f %Su "\$b"\)" = "\$USER_NAME" \]/);
    const ok = s.indexOf('proxy_ours_ok "$ours"');
    expect(ok).toBeGreaterThan(-1);
    expect(s.indexOf('proxy_restore_ok "$server" "$port"')).toBeGreaterThan(-1);
    expect(ok).toBeLessThan(s.indexOf('networksetup -setsocksfirewallproxy "$svc"'));
  });

  it('manager.ts passes --User to uninstall-cleanup', () => {
    expect(read('src/main/daemon/manager.ts')).toMatch(/runElevated\(scriptPath\('uninstall-cleanup\.sh'\), \{ \.\.\.\(user \? \{ User: user \} : \{\}\) \}/);
  });
});

describe('--User is the account that asked (AC-LINUX rc9-f-linux twin)', () => {
  /** user_is_asker under bash with an extra environment; returns the exit code. */
  const asker = (user: string, env: Record<string, string> = {}): number =>
    spawnSync('/bin/bash', ['-c', `source "${lib}"; user_is_asker "$1"`, 'x', user], { encoding: 'utf8', env: { ...process.env, SUDO_UID: '', ...env } }).status ?? 1;
  const myUid = String(process.getuid?.() ?? -1);

  it('root is never accepted as --User', () => {
    expect(asker('root')).not.toBe(0);
    expect(asker('')).not.toBe(0);
  });
  it.skipIf(isRoot)('the account up the parent chain is accepted, another account is not', () => {
    expect(asker(me)).toBe(0);
    expect(asker('nobody')).not.toBe(0); // exists on macOS and Linux, and did not ask
  });
  it.skipIf(isRoot)('under sudo, SUDO_UID decides', () => {
    expect(asker(me, { SUDO_UID: myUid })).toBe(0);
    expect(asker(me, { SUDO_UID: '99999' })).not.toBe(0);
  });
  it('setup-daemon, apply-daemon-config and uninstall-cleanup all check it', () => {
    for (const f of ['setup-daemon.sh', 'apply-daemon-config.sh', 'uninstall-cleanup.sh']) {
      expect(code(read(`resources/scripts/${f}`)), f).toMatch(/user_is_asker "\$USER_NAME"/);
    }
  });
});

describe('L32-1 class (hardening): --Dvpnd and --BinRoot are the bundle\'s own', () => {
  /** A fake bundle: <t>/Resources/scripts (the real scripts) next to <t>/Resources/bin/sentinel-dvpnd. */
  function bundle(): { t: string; scripts: string; bin: string } {
    const t = tmp('l321-');
    const scripts = path.join(t, 'Resources', 'scripts');
    const bin = path.join(t, 'Resources', 'bin');
    fs.cpSync('resources/scripts', scripts, { recursive: true });
    fs.mkdirSync(bin, { recursive: true });
    fs.writeFileSync(path.join(bin, 'sentinel-dvpnd'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
    return { t, scripts, bin };
  }
  const setup = (scripts: string, args: string[]): string => {
    const r = spawnSync('/bin/bash', [path.join(scripts, 'setup-daemon.sh'), ...args], { encoding: 'utf8' });
    return `${r.stdout}${r.stderr}`;
  };

  it('a sentinel-dvpnd outside the bundle is refused before root runs it', () => {
    const b = bundle();
    const other = path.join(b.t, 'elsewhere');
    fs.mkdirSync(other);
    fs.writeFileSync(path.join(other, 'sentinel-dvpnd'), '#!/bin/sh\ntouch "$0.RAN"\n', { mode: 0o755 });
    const out = setup(b.scripts, ['--Dvpnd', path.join(other, 'sentinel-dvpnd'), '--DaemonHome', '/nonexistent/c0']);
    expect(out).toMatch(/sentinel-dvpnd must be the app's own/);
    expect(fs.existsSync(path.join(other, 'sentinel-dvpnd.RAN'))).toBe(false);
  });

  it('a tools folder outside the bundle is refused', () => {
    const b = bundle();
    const out = setup(b.scripts, ['--Dvpnd', path.join(b.bin, 'sentinel-dvpnd'), '--BinRoot', b.t, '--DaemonHome', '/nonexistent/c0']);
    expect(out).toMatch(/the tools folder must be the app's own/);
  });

  it('negative control: the bundle\'s own dvpnd and bin folder pass the pin (the run stops later, on the home check)', () => {
    const b = bundle();
    const out = setup(b.scripts, ['--Dvpnd', path.join(b.bin, 'sentinel-dvpnd'), '--BinRoot', b.bin, '--DaemonHome', '/nonexistent/c0']);
    expect(out).not.toMatch(/must be the app's own/);
    expect(out).toMatch(/daemon home must be under/);
  });

  it('the pin comes before the first root use of $DVPND', () => {
    const s = code(read('resources/scripts/setup-daemon.sh'));
    const pin = s.indexOf('sentinel-dvpnd must be the app\'s own');
    expect(pin).toBeGreaterThan(-1);
    expect(pin).toBeLessThan(s.indexOf('"$DVPND" key list'));
    expect(pin).toBeLessThan(s.indexOf('install -m 755 "$DVPND"'));
  });
});

describe('M33-11: the macOS read-only key file next is a macOS line', () => {
  it('names unset DVPN_KEYFILE and no PowerShell', () => {
    let action = '';
    try { cliKeyStore('/tmp', '/tmp/k.json').save({} as never); } catch (err) { action = String((err as { action?: string }).action ?? ''); }
    expect(action).toBe(KEYFILE_RO_NEXT);
    expect(action).toMatch(/unset DVPN_KEYFILE/);
    expect(action).not.toMatch(/PowerShell|Remove-Item/);
    expect(read('src/cli/keystore.ts')).not.toMatch(/Remove-Item Env:DVPN_KEYFILE/);
  });
});

