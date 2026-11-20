// ─── safeStorage KeyStore (desktop app) — macOS ───
// Ported from sentinel-node-manager-solana services/wallet.ts: refuse to store the key when the
// OS cannot encrypt it. On macOS, safeStorage encrypts with a per-app key kept in the user's login
// Keychain ("Devnet dVPN Safe Storage"), so isEncryptionAvailable() is the whole test. The Linux
// 'basic_text' fallback (a fixed, public key) does not exist here; it is still refused if seen.
import { safeStorage } from 'electron';
import fs from 'node:fs';
import path from 'node:path';
import type { Keypair } from '@solana/web3.js';
import { keypairFromInput, keypairToJson } from '../../core/wallet/keys';
import type { KeyStore } from '../host';
import { log } from '../logger';

/** Linux backends that really encrypt (kept for the shared test); macOS has no backend choice. */
export const STRONG_BACKENDS = ['gnome_libsecret', 'kwallet', 'kwallet5', 'kwallet6'];

/** macOS: any backend except Linux's 'basic_text' (exported for tests). */
export function backendIsStrong(backend: string, platform: NodeJS.Platform = process.platform): boolean {
  if (platform === 'darwin') return backend !== 'basic_text';
  return STRONG_BACKENDS.includes(backend);
}

export function safeStorageKeyStore(dataDir: string): KeyStore {
  const file = path.join(dataDir, 'wallet.secret');
  // Q0567 (Agent M, Mac): the public address beside the secret, so start-up and the blocked view never decrypt
  // (on macOS each update makes the Keychain ask for the login password on the first decrypt). Not a secret.
  const addrFile = path.join(dataDir, 'wallet.address');
  const writeAddr = (kp: Keypair): void => {
    try { fs.writeFileSync(addrFile, kp.publicKey.toBase58()); }
    catch (err) { log.warn('wallet: could not store the public address', { err: (err as Error).message }); }
  };
  const requireEncryption = (): void => {
    const backend = typeof safeStorage.getSelectedStorageBackend === 'function' ? safeStorage.getSelectedStorageBackend() : 'unknown';
    if (!safeStorage.isEncryptionAvailable() || !backendIsStrong(backend)) {
      log.warn('wallet: no strong key storage', { backend });
      throw new Error('This Mac could not give the app a Keychain key to protect your wallet. Sign in to your Mac user account (not only over SSH) and try again.');
    }
  };
  return {
    kind: 'safeStorage',
    exists: () => fs.existsSync(file),
    load(): Keypair | null {
      if (!fs.existsSync(file)) return null;
      requireEncryption();
      try {
        const kp = keypairFromInput(safeStorage.decryptString(fs.readFileSync(file)));
        if (!fs.existsSync(addrFile)) writeAddr(kp); // a wallet saved by an older version
        return kp;
      } catch (err) {
        log.error('wallet: stored key could not be decrypted', err);
        throw new Error('Your stored wallet could not be unlocked with this account\'s Keychain.');
      }
    },
    save(kp) {
      requireEncryption();
      // Whole file or nothing (#31 f8c84a4, L-25): a crash or full disk mid-write left a cut wallet.secret that
      // could never be unlocked again. Written beside it (0600 from the start), then renamed over it.
      const tmp = `${file}.tmp`;
      fs.writeFileSync(tmp, safeStorage.encryptString(keypairToJson(kp)), { mode: 0o600 });
      fs.renameSync(tmp, file);
      writeAddr(kp);
    },
    address(): string | null {
      if (!fs.existsSync(file) || !fs.existsSync(addrFile)) return null;
      const a = fs.readFileSync(addrFile, 'utf8').trim();
      return /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(a) ? a : null;
    },
    remove() {
      if (fs.existsSync(file)) fs.unlinkSync(file);
      if (fs.existsSync(addrFile)) fs.unlinkSync(addrFile);
    },
  };
}
