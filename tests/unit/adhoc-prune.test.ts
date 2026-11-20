// ─── afterPack prunes non-arch leftovers before signing (verify-release v0.3.0-rc8: 5 non-arm64 Mach-O) ───
// The arm64 rc.8 app shipped node_gyp_bins/python3 (the build runner's universal python) x3 and darwin-x64-only
// bufferutil / utf-8-validate prebuilds. pruneForeign drops both kinds and keeps this arch's prebuilds.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';

const require = createRequire(import.meta.url);
const { pruneForeign } = require('../../build/mac/adhoc-sign.cjs') as {
  pruneForeign: (dir: string, arch: string) => string[];
};

const dirs: string[] = [];
afterEach(() => { for (const d of dirs.splice(0)) fs.rmSync(d, { recursive: true, force: true }); });

function tree(): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'prune-'));
  dirs.push(root);
  const files = [
    'bigint-buffer/build/node_gyp_bins/python3',
    'bigint-buffer/build/Release/bigint_buffer.node',
    'bufferutil/prebuilds/darwin-x64/bufferutil.node',
    'bufferutil/prebuilds/darwin-arm64/bufferutil.node',
    'bufferutil/prebuilds/linux-x64/bufferutil.node',
    'rpc-websockets/node_modules/utf-8-validate/prebuilds/darwin-x64/utf-8-validate.node',
    'rpc-websockets/node_modules/utf-8-validate/build/node_gyp_bins/python3',
    'rpc-websockets/node_modules/utf-8-validate/index.js',
  ];
  for (const f of files) {
    fs.mkdirSync(path.dirname(path.join(root, f)), { recursive: true });
    fs.writeFileSync(path.join(root, f), 'x');
  }
  return root;
}

const exists = (root: string, f: string) => fs.existsSync(path.join(root, f));

describe('pruneForeign (afterPack, before codesign)', () => {
  it('arm64: removes node_gyp_bins and every prebuild that is not darwin-arm64', () => {
    const root = tree();
    const removed = pruneForeign(root, 'arm64');
    expect(removed).toHaveLength(5);
    expect(exists(root, 'bigint-buffer/build/node_gyp_bins')).toBe(false);
    expect(exists(root, 'rpc-websockets/node_modules/utf-8-validate/build/node_gyp_bins')).toBe(false);
    expect(exists(root, 'bufferutil/prebuilds/darwin-x64')).toBe(false);
    expect(exists(root, 'bufferutil/prebuilds/linux-x64')).toBe(false);
    expect(exists(root, 'rpc-websockets/node_modules/utf-8-validate/prebuilds/darwin-x64')).toBe(false);
    // kept: this arch's prebuild, the compiled addon, plain JS
    expect(exists(root, 'bufferutil/prebuilds/darwin-arm64/bufferutil.node')).toBe(true);
    expect(exists(root, 'bigint-buffer/build/Release/bigint_buffer.node')).toBe(true);
    expect(exists(root, 'rpc-websockets/node_modules/utf-8-validate/index.js')).toBe(true);
  });

  it('x64: keeps darwin-x64 prebuilds and drops darwin-arm64 (negative control)', () => {
    const root = tree();
    pruneForeign(root, 'x64');
    expect(exists(root, 'bufferutil/prebuilds/darwin-x64/bufferutil.node')).toBe(true);
    expect(exists(root, 'rpc-websockets/node_modules/utf-8-validate/prebuilds/darwin-x64/utf-8-validate.node')).toBe(true);
    expect(exists(root, 'bufferutil/prebuilds/darwin-arm64')).toBe(false);
  });

  it('a missing node_modules folder is a no-op', () => {
    expect(pruneForeign(path.join(os.tmpdir(), 'no-such-dir-prune'), 'arm64')).toEqual([]);
  });
});
