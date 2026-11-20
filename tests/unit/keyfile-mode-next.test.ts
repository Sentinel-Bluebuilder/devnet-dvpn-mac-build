// #38 rc.8 macOS audit (M-S keyfile-mode): the chmod in `next` must run verbatim on a path with spaces.
import { describe, expect, it, vi } from 'vitest';

vi.mock('../../src/main/daemon/launchd-state', () => ({ launchdState: async () => ({ installed: null, loaded: false, running: false }), LAUNCHD_LABEL: 'x', LAUNCHD_PLIST: 'x' }));

describe('keyfileModeNext quotes the key file path', () => {
  it('a path with spaces is one quoted shell word', async () => {
    const { keyfileModeNext } = await import('../../src/cli/agent-cmd');
    expect(keyfileModeNext('/Users/a/Library/Application Support/k.json')).toBe("chmod 600 '/Users/a/Library/Application Support/k.json', then devnet-dvpn agent up --yes");
  });
  it("a single quote inside the path is escaped", async () => {
    const { shellWord } = await import('../../src/cli/agent-cmd');
    expect(shellWord("/tmp/o'k.json")).toBe("'/tmp/o'\\''k.json'");
  });
  it('negative control: a plain path stays unquoted', async () => {
    const { keyfileModeNext } = await import('../../src/cli/agent-cmd');
    expect(keyfileModeNext('/Users/runner/mac-gha-1.json')).toBe('chmod 600 /Users/runner/mac-gha-1.json, then devnet-dvpn agent up --yes');
  });
});
