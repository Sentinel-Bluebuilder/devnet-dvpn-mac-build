// ─── rc9-d: `daemon install --yes` with the service installed and nothing staged (macOS root step) ───
// Run 44843609674 sw_install_a: install-failed "staging folder not found"; AC-LINUX saw the same as a loop
// (status → install → not found → doctor → status). setup-daemon.sh now re-installs from the kept home.
// The block runs as root, so here it is cut out of the script and run in a temp dir with stand-in paths.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';

const SCRIPT = fs.readFileSync('resources/scripts/setup-daemon.sh', 'utf8');
const START = 'if [ -n "$STAGING" ] && [ ! -e "$STAGING" ] && [ ! -L "$STAGING" ] && [ -f "$HOME_DIR/config.toml" ]; then';
const block = (): string => {
  const at = SCRIPT.indexOf(START);
  return SCRIPT.slice(at, SCRIPT.indexOf('\nfi\n', at) + 4);
};

function staging(home: string, stagingPath: string): string {
  const sh = `STAGING="$1"; HOME_DIR="$2"\n${block()}printf '%s' "$STAGING"`;
  return execFileSync('/bin/bash', ['-c', sh, 'x', stagingPath, home], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

describe('setup-daemon.sh: an installed service with nothing staged', () => {
  it('the block comes before every staging check, so a missing folder never reaches "staging folder not found"', () => {
    const at = SCRIPT.indexOf(START);
    expect(at).toBeGreaterThan(0);
    expect(at).toBeLessThan(SCRIPT.indexOf('if [ -n "$STAGING" ]; then'));
    expect(at).toBeLessThan(SCRIPT.indexOf('die "staging folder not found: $STAGING"'));
    expect(at).toBeGreaterThan(SCRIPT.indexOf('under "$HOME_DIR" "$DAEMON_ROOT"'));
  });
  it('installed home + no staging folder: nothing staged (STAGING emptied, the home is re-installed)', () => {
    const d = fs.mkdtempSync(path.join(os.tmpdir(), 'ns-'));
    fs.writeFileSync(path.join(d, 'config.toml'), 'owner = "x"\n');
    expect(staging(d, path.join(d, 'gone', 'daemon-staging'))).toBe('');
    fs.rmSync(d, { recursive: true, force: true });
  });
  it('negative controls: a staging folder that exists, a link, or no installed home keep STAGING for the checks', () => {
    const d = fs.mkdtempSync(path.join(os.tmpdir(), 'ns-'));
    const s = path.join(d, 'daemon-staging');
    fs.writeFileSync(path.join(d, 'config.toml'), 'owner = "x"\n');
    fs.mkdirSync(s);
    expect(staging(d, s)).toBe(s);
    const link = path.join(d, 'daemon-switch');
    fs.symlinkSync(path.join(d, 'nowhere'), link); // a dangling link: -e is false, -L is true
    expect(staging(d, link)).toBe(link);
    const fresh = fs.mkdtempSync(path.join(os.tmpdir(), 'ns-')); // no config.toml: a first setup
    expect(staging(fresh, path.join(fresh, 'daemon-staging'))).toBe(path.join(fresh, 'daemon-staging'));
    fs.rmSync(d, { recursive: true, force: true });
    fs.rmSync(fresh, { recursive: true, force: true });
  });
});
