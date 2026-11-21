// ─── CLI key store — macOS ───
// DVPN_KEYFILE (or --keyfile) points at a solana-keygen JSON that is used in place and never
// copied — how tests use the devnet wallet. Otherwise the key is kept in the user's login Keychain
// as a generic password (service `devnet-dvpn`, account `cli-wallet:<data dir>`) through
// /usr/bin/security. The secret never goes on a command line (visible in `ps`): it is written to
// `security -i` on stdin, hex-encoded (-X). <data>/wallet.cli.keyring is only a marker (no
// secret in it) so `exists` needs no Keychain round trip.
import { cliErr, CLI_NAME } from './cli-fail';
import fs from 'node:fs';
import os from 'node:os';

/** KWIN-USER (#38 rc.9): this Windows account as icacls takes it (DOMAIN\\user), written into the line: PowerShell
 *  never expands %USERNAME%. Pure over the environment; exported for tests. */
export function windowsAccount(env: NodeJS.ProcessEnv = process.env): string {
  const user = env.USERNAME || os.userInfo().username;
  return env.USERDOMAIN ? `${env.USERDOMAIN}\\${user}` : user;
}
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { log } from '../main/logger';
import type { Keypair } from '@solana/web3.js';
import { keypairFromInput, keypairToJson } from '../core/wallet/keys';
import type { KeyStore } from '../main/host';

const SECURITY = '/usr/bin/security';
export const KEYCHAIN_SERVICE = 'devnet-dvpn';
const LABEL = 'Devnet dVPN CLI wallet';

/** The Keychain account that names this data folder's wallet (exported for tests). */
export function keychainAccount(dataDir: string): string {
  return `cli-wallet:${path.resolve(dataDir)}`;
}

/** One `security -i` line; values are double-quoted, and our values never hold a quote or newline (exported for tests). */
export function securityLine(args: string[]): string {
  for (const a of args) if (/["\n\r\\]/.test(a)) throw cliErr('keystore-unavailable', `${CLI_NAME} wallet create --keyfile <path> --yes`, 'refusing a Keychain argument with a quote or newline');
  return args.map((a) => (/^[A-Za-z0-9_:/.,@+-]+$/.test(a) ? a : `"${a}"`)).join(' ') + '\n';
}

/** The add command for `security -i`: the secret as hex (-X), -U replaces an old item (exported for tests). */
export function addCommand(dataDir: string, secret: string): string {
  return securityLine(['add-generic-password', '-U', '-s', KEYCHAIN_SERVICE, '-a', keychainAccount(dataDir), '-l', LABEL, '-X', Buffer.from(secret, 'utf8').toString('hex')]);
}

/**
 * `security` exit codes are the OSStatus cut to 8 bits, and `find-generic-password -w` on a locked
 * Keychain prints NOTHING: exit 36 = errSecInteractionNotAllowed (-25308), 51 = errSecAuthFailed
 * (-25293). Q0484 H2 (ddv-mac-dv 11-12): a second SSH login showed the raw "Command failed:
 * /usr/bin/security find-generic-password … -w" instead of the locked-Keychain sentence.
 */
const LOCKED_STATUS = [36, 51];

/** Map a `security` failure to something a person can act on (exported for tests). */
export function keyringError(raw: string, status?: number): Error {
  if (/ENOENT|not found|No such file/i.test(raw) && !/could not be found in the keychain/i.test(raw)) {
    return cliErr('keystore-unavailable', `${CLI_NAME} wallet create --keyfile <path> --yes`, 'The macOS security tool is missing. Use a key file instead: --keyfile <path> or DVPN_KEYFILE.');
  }
  if ((status !== undefined && LOCKED_STATUS.includes(status)) || /User interaction is not allowed|interaction|locked|-25308|-25293/i.test(raw)) {
    return cliErr('keystore-unavailable', `${CLI_NAME} wallet create --keyfile <path> --yes`, 'The login Keychain is locked in this session (for example an SSH login). Unlock it (security unlock-keychain), or use a key file: --keyfile <path> or DVPN_KEYFILE.');
  }
  return cliErr('keystore-unavailable', `${CLI_NAME} wallet create --keyfile <path> --yes`, `The Keychain could not store or read the wallet: ${raw.split('\n')[0]}`);
}

function security(args: string[], input?: string): string {
  try {
    return execFileSync(SECURITY, args, { input, encoding: 'utf8', timeout: 30_000, stdio: ['pipe', 'pipe', 'pipe'] });
  } catch (err) {
    const e = err as { stderr?: unknown; stdout?: unknown; code?: string; status?: number; message: string };
    // find of a missing item exits 44 ("could not be found"): not an error for the caller.
    if (args[0] === 'find-generic-password' && e.status === 44) return '';
    if (args[0] === 'delete-generic-password' && e.status === 44) return '';
    throw keyringError(e.code === 'ENOENT' ? 'ENOENT' : String(e.stderr ?? '') || String(e.stdout ?? '') || e.message, e.status);
  }
}

function lookup(dataDir: string): string {
  return security(['find-generic-password', '-s', KEYCHAIN_SERVICE, '-a', keychainAccount(dataDir), '-w']).trim();
}

/** E-EP (#38 rc.9): the one command that lets this user read its key file again, then wallet show. */
export function keyfileUnreadableNext(file: string, platform: string = process.platform): string {
  return platform === 'win32'
    ? `icacls "${file}" /grant "${windowsAccount()}:R", then ${CLI_NAME} wallet show --json` // KWIN-USER
    : `sudo chown $(id -un) ${shellWord(file)} && chmod 600 ${shellWord(file)}, then ${CLI_NAME} wallet show --json`;
}

/** E-EP: reads the key file; a file this user may not read is keyfile-unreadable (it was the raw EPERM / EACCES). */
export function readKeyfile(file: string, read: (f: string) => string = (f) => fs.readFileSync(f, 'utf8')): string {
  try {
    return read(file);
  } catch (err) {
    const c = (err as NodeJS.ErrnoException).code;
    if (c === 'EACCES' || c === 'EPERM') throw cliErr('keyfile-unreadable', keyfileUnreadableNext(file), `The key file ${file} cannot be read by this user (${c}). Nothing was sent or signed.`);
    throw err;
  }
}

/** M33-11 (rc9-f-mac): the macOS shell line (it named PowerShell's Remove-Item, a Windows command). Exported for tests. */
export const KEYFILE_RO_NEXT = 'drop --keyfile and run unset DVPN_KEYFILE, then run the command again';

export function cliKeyStore(dataDir: string, keyfile?: string): KeyStore {
  if (keyfile) {
    return {
      kind: 'keyfile',
      path: keyfile, // E-18: noWallet() names the missing file (#31 main)
      exists: () => fs.existsSync(keyfile),
      load: (): Keypair | null => (fs.existsSync(keyfile) ? keypairFromInput(readKeyfile(keyfile)) : null),
      save() { throw cliErr('keyfile-read-only', KEYFILE_RO_NEXT, 'A --keyfile / DVPN_KEYFILE wallet is read-only. Run without it to import or create a wallet.'); }, // AUD-2 M11
      remove() { throw cliErr('keyfile-read-only', KEYFILE_RO_NEXT, 'A --keyfile / DVPN_KEYFILE wallet is never deleted by this CLI.'); },
    };
  }
  const marker = path.join(dataDir, 'wallet.cli.keyring');
  return {
    // Not 'keyfile': vault.ts skips its "never replace a wallet" check only for a read-only key
    // file, and this store CAN be overwritten (Windows VM sweep 2026-10-21).
    kind: 'keyring',
    exists: () => fs.existsSync(marker),
    load(): Keypair | null {
      if (!fs.existsSync(marker)) return null;
      const json = lookup(dataDir);
      if (!json) throw cliErr('keystore-unavailable', `${CLI_NAME} wallet create --keyfile <path> --yes`, 'The wallet is missing from the Keychain (it was removed outside this app). Import it again, or use a key file.');
      return keypairFromInput(json);
    },
    save(kp) {
      const secret = keypairToJson(kp);
      // `security -i` reads commands from stdin; it prints errors but exits 0, so read back.
      security(['-i'], addCommand(dataDir, secret));
      if (lookup(dataDir) !== secret.trim()) throw cliErr('keystore-unavailable', `${CLI_NAME} wallet create --keyfile <path> --yes`, 'The Keychain did not keep the wallet (is the login Keychain unlocked?). Nothing was saved.');
      fs.writeFileSync(marker, JSON.stringify({ store: 'macos-keychain', service: KEYCHAIN_SERVICE, label: LABEL, at: new Date().toISOString() }) + '\n', { encoding: 'utf8', mode: 0o600 });
    },
    remove() {
      if (fs.existsSync(marker)) security(['delete-generic-password', '-s', KEYCHAIN_SERVICE, '-a', keychainAccount(dataDir)]);
      fs.rmSync(marker, { force: true });
    },
  };
}

// ─── R3 gap 1 (#38 STATE-MATRIX): a key file other users can read is refused before any payment ───
/** The key file's mode problem (group/other bits set, POSIX only), or null. Pure over the stat; exported for tests. */
/** The one command that makes the key file readable by this user only, then the agent up line (K-WIN: per OS). */
/** A path as one shell word: unchanged when it is plain, else single-quoted (macOS key files often sit under
 *  "~/Library/Application Support", and an unquoted chmod there runs on two wrong paths). AC-MAC-3, #33 3b64e34c5. */
export const shellWord = (p: string): string => (/^[A-Za-z0-9_./@%+:=-]+$/.test(p) ? p : `'${p.replace(/'/g, `'\\''`)}'`);
// L4 (rc9-c2, AC-WIN w11): /inheritance:r drops only inherited ACEs and /grant:r replaces only this account's grant, so
// an EXPLICIT Users / Authenticated Users / Everyone ACE survived and this next looped. /remove:g takes out every group
// keyfileModeProblem refuses (OPEN_ACE), by SID, in the same one command.
export const WIN_OPEN_GROUP_SIDS = ['*S-1-1-0', '*S-1-5-11', '*S-1-5-32-545'] as const;
export const keyfileModeNext = (file: string, platform: string = process.platform, account: string = windowsAccount()): string => platform === 'win32'
  ? `icacls "${file}" /inheritance:r /remove:g ${WIN_OPEN_GROUP_SIDS.join(' ')} /grant:r "${account}:F", then ${CLI_NAME} agent up --yes`
  : `chmod 600 ${shellWord(file)}, then ${CLI_NAME} agent up --yes`;

/** K-WIN (#38 rc.9): reads a file's ACL on Windows. Injected in tests. */
export type AclRunner = (file: string) => string;
const icacls: AclRunner = (file) => execFileSync('icacls', [file], { encoding: 'utf8', windowsHide: true, timeout: 5000 });
// The groups every local account is in (names, or the bare SIDs icacls prints when it cannot resolve them): an allow
// ACE for one of them lets other users read the wallet key. The first ACE sits on the line with the file path.
const OPEN_ACE = /(?:^|\s)(BUILTIN\\Users|Everyone|NT AUTHORITY\\Authenticated Users|\*?S-1-5-32-545|\*?S-1-1-0|\*?S-1-5-11):((?:\([^)]*\))+)/gi;

/** The first allow ACE in `icacls` output that opens the file to all local users, as icacls prints it; or null. */
export function openAce(icaclsOut: string): string | null {
  for (const m of icaclsOut.matchAll(OPEN_ACE)) if (!/\(DENY\)/i.test(m[2])) return `${m[1]}:${m[2]}`;
  return null;
}

export function keyfileModeProblem(file: string | undefined, platform: NodeJS.Platform = process.platform, statMode?: number, acl: AclRunner = icacls): { path: string; mode: string } | null {
  if (!file) return null;
  if (platform === 'win32') {
    // K-WIN: there is no mode on Windows; the ACL says who can read it. A failed read never blocks (fail-open).
    let out: string;
    try { out = acl(file); } catch (err) { log.warn('key file ACL not read (icacls); not checked', { file, err: (err as Error).message }); return null; }
    const ace = openAce(out);
    return ace ? { path: file, mode: ace } : null;
  }
  let mode = statMode;
  if (mode === undefined) {
    // AUDIT M13: logged, never a silent catch; a missing file is keyfile-missing, named elsewhere
    try { mode = fs.statSync(file).mode; } catch (err) { log.debug('key file stat failed', { file, err: (err as Error).message }); return null; }
  }
  return (mode & 0o077) ? { path: file, mode: (mode & 0o777).toString(8) } : null;
}
