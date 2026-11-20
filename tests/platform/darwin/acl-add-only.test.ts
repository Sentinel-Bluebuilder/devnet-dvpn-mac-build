// ─── AUDIT-FINAL-MACOS M3 + M6: setup never clears the home ACL (other accounts keep their grant) and never
// puts an ACE on a symlink's target — macOS ───
import fs from 'node:fs';
import { describe, expect, it } from 'vitest';

const read = (f: string): string => fs.readFileSync(`resources/scripts/${f}`, 'utf8');
const code = (s: string): string => s.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');

describe('ACL grants add only', () => {
  it('setup-daemon.sh has no chmod -N and grants through add_ace', () => {
    const s = code(read('setup-daemon.sh'));
    expect(s).not.toMatch(/chmod -N/);
    expect(s).toMatch(/add_ace 'search,readattr' "\$DAEMON_ROOT"/);
    expect(s).toMatch(/add_ace 'list,search,read,write,readattr,readextattr,file_inherit' "\$HOME_DIR"/);
    expect(s).not.toMatch(/chmod \+a "user:\$USER_NAME/);
  });
  it('add_ace lives once in _lib.sh and both scripts source it', () => {
    expect(code(read('_lib.sh'))).toMatch(/^add_ace\(\) \{/m);
    expect(code(read('grant-socket.sh'))).not.toMatch(/^add_ace\(\)/m);
    for (const f of ['setup-daemon.sh', 'grant-socket.sh']) expect(read(f)).toMatch(/source "\$HERE\/_lib\.sh"/);
  });
  it('M6: every config.toml find for an ACE or chmod is -type f', () => {
    for (const f of ['setup-daemon.sh', 'grant-socket.sh']) {
      for (const l of code(read(f)).split('\n').filter((x) => /find .*-name config\.toml/.test(x))) expect(l).toMatch(/-type f/);
    }
  });
  it('negative control: grant-socket.sh still grants the running socket', () => {
    expect(code(read('grant-socket.sh'))).toMatch(/add_ace 'read,write,readattr' "\$HOME_DIR\/daemon\.sock"/);
  });
});
