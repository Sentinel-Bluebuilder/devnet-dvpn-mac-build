// ─── AUDIT-FINAL-MACOS M7: write_result replaces a hard-linked result path instead of writing through it — macOS ───
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';

const lib = path.resolve('resources/scripts/_lib.sh');
const write = (result: string): void => {
  execFileSync('/bin/bash', ['-c', `source "${lib}"; ARG_Result="$1" write_result ok 'done'`, 'x', result]);
};

describe('_lib.sh write_result', () => {
  it('a hard link at the result path is replaced; the linked file keeps its bytes', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'devnet-dvpn-'));
    const victim = path.join(dir, 'victim.txt');
    fs.writeFileSync(victim, 'KEEP');
    const result = path.join(dir, 'result.json');
    fs.linkSync(victim, result);
    write(result);
    expect(fs.readFileSync(victim, 'utf8')).toBe('KEEP');
    expect(JSON.parse(fs.readFileSync(result, 'utf8'))).toMatchObject({ status: 'ok', detail: 'done' });
    expect(fs.readdirSync(dir).filter((f) => f.startsWith('.result.'))).toEqual([]);
    fs.rmSync(dir, { recursive: true, force: true });
  });
  it('negative control: a plain result path is written, mode 644', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'devnet-dvpn-'));
    const result = path.join(dir, 'result.json');
    write(result);
    expect(JSON.parse(fs.readFileSync(result, 'utf8')).status).toBe('ok');
    expect(fs.statSync(result).mode & 0o777).toBe(0o644);
    fs.rmSync(dir, { recursive: true, force: true });
  });
});
