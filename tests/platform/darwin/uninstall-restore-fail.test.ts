// ─── AUDIT-FINAL-MACOS M1: uninstall never says "networking restored" when remove-tunnels failed — macOS ───
// remove-tunnels.sh dies with "still present: pf anchor …" when the kill switch survives; uninstall-cleanup.sh
// swallowed it (`>/dev/null 2>&1 || true`) and wrote ok 'networking restored'.
import fs from 'node:fs';
import { describe, expect, it } from 'vitest';

const src = fs.readFileSync('resources/scripts/uninstall-cleanup.sh', 'utf8');
const lines = src.split('\n');
const code = (l: string): boolean => !/^\s*#/.test(l);
const at = (re: RegExp): number => lines.findIndex((l) => re.test(l) && code(l));

describe('uninstall-cleanup.sh: a failed remove-tunnels is reported', () => {
  it('remove-tunnels is no longer silenced with || true', () => {
    expect(at(/remove-tunnels\.sh.*\|\|\s*true/)).toBe(-1);
  });
  it('its failure dies with "NOT fully restored" and a next, before the root copies are removed', () => {
    const call = at(/if ! rt_out=.*remove-tunnels\.sh/);
    const die = at(/die "Networking is NOT fully restored.*Next: devnet-dvpn daemon restore-network/);
    const rm = at(/^rm -rf "\$LIB"/);
    expect(call).toBeGreaterThan(-1);
    expect(die).toBeGreaterThan(call);
    expect(rm).toBeGreaterThan(die);
  });
  it('negative control: the success line is still written at the end', () => {
    expect(at(/write_result ok 'networking restored/)).toBeGreaterThan(at(/^rm -rf "\$LIB"/));
  });
  it('remove-tunnels.sh still dies when something is left (the signal M1 relies on)', () => {
    expect(fs.readFileSync('resources/scripts/remove-tunnels.sh', 'utf8')).toMatch(/die "still present: /);
  });
});
