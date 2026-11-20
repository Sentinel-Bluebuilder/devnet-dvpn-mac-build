// ─── New key-file wallet (Q0490: wallet create --keyfile <new path>) ───
// A machine with no unlocked keyring (an SSH login, a server) could not get a wallet from this app at all:
// `wallet create` needs the keyring, and a --keyfile wallet is read-only. This writes a NEW solana-keygen
// JSON key file instead: never over an existing file (one atomic 'wx' open), parent folder 0700, file 0600.
// The caller prints the address only; the key stays in the file.
import fs from 'node:fs';
import path from 'node:path';
import { Keypair } from '@solana/web3.js';

export class KeyfileExistsError extends Error {}

export function createKeyfile(file: string, gen: () => Keypair = () => Keypair.generate()): { address: string; path: string } {
  const abs = path.resolve(file);
  if (fs.existsSync(abs)) {
    throw new KeyfileExistsError(`${abs} already exists, so nothing was written: a key file is never replaced. Choose a new path, or use this file with --keyfile to sign in with it.`);
  }
  fs.mkdirSync(path.dirname(abs), { recursive: true, mode: 0o700 });
  const kp = gen();
  try {
    fs.writeFileSync(abs, JSON.stringify(Array.from(kp.secretKey)), { mode: 0o600, flag: 'wx' });
  } catch (err) {
    // Created by someone else between the check and the open: same answer as above, nothing replaced.
    if ((err as NodeJS.ErrnoException).code === 'EEXIST') throw new KeyfileExistsError(`${abs} already exists, so nothing was written: a key file is never replaced.`);
    throw new Error(`Could not write the key file ${abs}: ${(err as Error).message}`);
  }
  return { address: kp.publicKey.toBase58(), path: abs };
}
