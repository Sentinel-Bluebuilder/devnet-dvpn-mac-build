// ─── AUDIT-FINAL-MACOS M5 + M10: restore network drops our stale pf attach line; one shared helper — macOS ───
// The flush emptied the anchor but left `anchor "sentinel-dvpn-c0" …` in the main ruleset, so the next kill-switch
// connect failed closed ("conflicting pf anchor attachment"). Live repro still owed in the guest (KS on, connect,
// kill -9 dvpnd, Restore network, KS connect again).
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';

const read = (f: string): string => fs.readFileSync(`resources/scripts/${f}`, 'utf8');
const code = (s: string): string => s.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');

describe('pf attach line', () => {
  it('remove-tunnels.sh drops it and counts a survivor as left (so uninstall fails loud)', () => {
    const s = code(read('remove-tunnels.sh'));
    expect(s).toMatch(/if pf_has_our_attach; then pf_drop_our_attach && removed\+=\('pf anchor attach line'\); fi/);
    expect(s).toMatch(/pf_has_our_attach && left\+=\('pf anchor attach line'\)/);
  });
  it('M10: the pfctl -sr | pfctl -R pipeline exists once, in _lib.sh', () => {
    for (const f of ['setup-daemon.sh', 'uninstall-cleanup.sh', 'remove-tunnels.sh']) {
      expect(code(read(f))).not.toMatch(/pfctl -R/);
      expect(code(read(f))).toMatch(/pf_drop_our_attach/);
    }
    expect(code(read('_lib.sh'))).toMatch(/pfctl -R -f -/);
  });
  it('never the whole-firewall forms', () => {
    for (const f of ['_lib.sh', 'setup-daemon.sh', 'uninstall-cleanup.sh', 'remove-tunnels.sh']) {
      expect(code(read(f))).not.toMatch(/pfctl -f \/etc\/pf\.conf|pfctl -F all|pfctl -d\b/);
    }
  });
  it('pf_drop_our_attach with a fake pfctl: drops only our lines, keeps the others', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pfattach-'));
    const rules = path.join(dir, 'rules');
    fs.writeFileSync(rules, 'anchor "com.apple/*" all\nanchor "sentinel-dvpn-c0" all\nanchor "other.vpn" all\n');
    fs.writeFileSync(path.join(dir, 'pfctl'), `#!/bin/bash\nif [ "$1" = -sr ]; then cat "${rules}"; exit 0; fi\nif [ "$1" = -R ]; then cat > "${rules}"; exit 0; fi\nexit 1\n`, { mode: 0o755 });
    const lib = path.resolve('resources/scripts/_lib.sh');
    execFileSync('/bin/bash', ['-c', `source "${lib}"; pf_drop_our_attach`], { env: { ...process.env, PATH: `${dir}:${process.env.PATH}` } });
    expect(fs.readFileSync(rules, 'utf8')).toBe('anchor "com.apple/*" all\nanchor "other.vpn" all\n');
    fs.rmSync(dir, { recursive: true, force: true });
  });
});
