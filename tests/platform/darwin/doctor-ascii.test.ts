// ─── rc9-d (#31 0a4008700): the 'doctor details are ASCII' block of tests/unit/installer-lock-r1b.test.ts ───
// The rest of that file pins Windows' NSIS installer.nsh + assert-app-folder.ps1 (PLATFORM-EXCEPTIONS row).
import { describe, it, expect } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import { asciiDetail } from '../../../src/cli/daemon-cmd';

describe('rc9-d: doctor details are ASCII', () => {
  it('the grant detail arrow becomes ">"; other non-ASCII is dropped', () => {
    expect(asciiDetail('Set one: Wallet → Set spending limit, or x.')).toBe('Set one: Wallet > Set spending limit, or x.');
    expect(asciiDetail('a — b …')).toBe('a - b ...');
    expect(/[^\x20-\x7e]/.test(asciiDetail('été ✓'))).toBe(false);
  });
  it('doctor maps every row through it before printing', () => {
    const s = fs.readFileSync(path.resolve('src/cli/daemon-cmd.ts'), 'utf8');
    expect(s).toMatch(/for \(const r of rows\) r\.detail = asciiDetail\(r\.detail\);\n\s+o\.print\(rows\.map/);
  });
});
