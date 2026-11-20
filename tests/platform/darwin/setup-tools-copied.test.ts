// ─── AUDIT-FINAL-MACOS M4: setup-daemon.sh reports a failed install-deps --CopyOnly (toolsCopied:false) — macOS ───
import fs from 'node:fs';
import { describe, expect, it } from 'vitest';

const src = fs.readFileSync('resources/scripts/setup-daemon.sh', 'utf8');
const code = src.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');

describe('setup-daemon.sh install-deps copy', () => {
  it('the copy is no longer silenced to /dev/null', () => {
    expect(code).not.toMatch(/install-deps\.sh" --CopyOnly .*>\/dev\/null 2>&1\s*$/m);
  });
  it('a failure is logged and sets toolsCopied:false', () => {
    expect(code).toMatch(/if ! deps_out="\$\(\/bin\/bash "\$HERE\/install-deps\.sh" --CopyOnly/);
    expect(code).toMatch(/install-deps --CopyOnly failed: /);
    expect(code).toMatch(/TOOLS_FIELD='"toolsCopied":false'/);
  });
  it('both ok results carry the field; the translated detail text is unchanged', () => {
    expect(code).toMatch(/write_result ok 'service installed; waiting for the network' "\\"waitingForNetwork\\":true,\$TOOLS_FIELD"/);
    expect(code).toMatch(/write_result ok 'service installed and running' "\$TOOLS_FIELD"/);
  });
});
