// ─── Repair drivers works on a Mac with no Homebrew when the app bundles every tool (AC-MAC-1 C6) — macOS ───
// drivers.ts repairDrivers() always runs `install-deps.sh --UserPhase 1` first. That phase died on
// `[ -n "$BREW" ] || die "Homebrew is not installed"` (exit 1), so the repair stopped before its root step, which
// installs a complete bundle with no Homebrew at all (install-deps.sh "bundled tools present"). Most Macs have no
// Homebrew, and Repair is the recovery path. The user phase now ends at once (exit 0) when the bundle is complete.
import fs from 'node:fs';
import { describe, expect, it } from 'vitest';

const src = fs.readFileSync('resources/scripts/install-deps.sh', 'utf8');
const lines = src.split('\n');
const at = (re: RegExp, from = 0): number => {
  for (let i = from; i < lines.length; i += 1) if (re.test(lines[i]) && !/^\s*#/.test(lines[i])) return i;
  return -1;
};

describe('install-deps.sh user phase with a complete bundle', () => {
  const phase = at(/^if \[ "\$USER_PHASE" = 1 \]; then/);

  it('exits 0 on a complete bundle before it needs Homebrew', () => {
    expect(phase).toBeGreaterThan(-1);
    const skip = at(/bundle_complete.*exit 0/, phase);
    const brew = at(/\[ -n "\$BREW" \] \|\| die "Homebrew is not installed/, phase);
    expect(skip).toBeGreaterThan(phase);
    expect(brew).toBeGreaterThan(skip);
  });

  it('the root check still runs first (Homebrew refuses root)', () => {
    expect(at(/\[ "\$\(id -u\)" != 0 \] \|\| die 'the user phase runs as the Mac user/, phase)).toBeLessThan(at(/bundle_complete.*exit 0/, phase));
  });

  it('negative control: without a complete bundle the Homebrew check is still there', () => {
    expect(at(/\[ -n "\$BREW" \] \|\| die "Homebrew is not installed/, phase)).toBeGreaterThan(-1);
  });

  it('the root step installs a complete bundle with no Homebrew (what the skip relies on)', () => {
    const rootBundle = at(/^\s*if bundle_complete; then$/);
    expect(rootBundle).toBeGreaterThan(-1);
    expect(at(/copy_tools/, rootBundle)).toBeGreaterThan(rootBundle);
  });
});
