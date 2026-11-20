// ─── afterPack: sign the .app with the project's STABLE self-signed identity (no notarization; owner decision) ───
// electron-builder signs nothing with `identity: null`. Apple Silicon refuses to run a Mach-O with no signature at
// all, and editing the bundle (Info.plist, resources) breaks Electron's own linker signature, so the whole bundle is
// re-signed here, inside-out: every loose Mach-O in Resources (dvpnd, v2ray, xray, hysteria2), then the frameworks and
// helpers (--deep), then the app. Only runs on macOS (codesign); verifies the result.
//
// Why a stable identity (DIR 11-13, Mac rc.2): an AD-HOC signature's designated requirement is the cdhash, so every
// build was a different app to the Keychain: the first start after an update asked for the login keychain password
// to read "Devnet dVPN Safe Storage", and Electron's safeStorage blocked the app until it was answered. Signed with one
// self-signed certificate the requirement is `identifier "network.sentinel.devnet-dvpn" and certificate root = H"…"` (self-signed: root = leaf),
// the same for every build, so the Keychain grant survives updates. Gatekeeper is unchanged (not notarized).
//
// Env: DVPN_MAC_SIGN_IDENTITY  the identity's SHA-1 (or name) in the signing keychain
//      DVPN_MAC_SIGN_KEYCHAIN  path of the dedicated signing keychain
//      DVPN_MAC_SIGN_KEYCHAIN_PASS_FILE  file holding that keychain's password (unlocked here, never logged)
//      DVPN_MAC_ADHOC=1        deliberately sign ad hoc (dev builds only; a release must not)
'use strict';
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const MACHO = new Set(['feedfacf', 'cffaedfe', 'feedface', 'cefaedfe', 'cafebabe', 'bebafeca']);

function isMachO(file) {
  const fd = fs.openSync(file, 'r');
  try {
    const b = Buffer.alloc(4);
    return fs.readSync(fd, b, 0, 4, 0) === 4 && MACHO.has(b.toString('hex'));
  } finally {
    fs.closeSync(fd);
  }
}

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.isFile() && isMachO(p)) out.push(p);
  }
  return out;
}

/** Which signer to use, from the environment. Exported for tests. */
function signer(env = process.env) {
  const identity = (env.DVPN_MAC_SIGN_IDENTITY || '').trim();
  if (identity) {
    const keychain = (env.DVPN_MAC_SIGN_KEYCHAIN || '').trim();
    if (!keychain) throw new Error('DVPN_MAC_SIGN_IDENTITY is set but DVPN_MAC_SIGN_KEYCHAIN is not');
    return { kind: 'identity', identity, keychain, passFile: (env.DVPN_MAC_SIGN_KEYCHAIN_PASS_FILE || '').trim() };
  }
  if (env.DVPN_MAC_ADHOC === '1') return { kind: 'adhoc' };
  throw new Error('no Mac signing identity: set DVPN_MAC_SIGN_IDENTITY + DVPN_MAC_SIGN_KEYCHAIN (release), or DVPN_MAC_ADHOC=1 for a dev build. An ad-hoc build changes the app\'s Keychain identity on every update.');
}

/** codesign arguments for one target. Exported for tests. */
function codesignArgs(s, target, deep) {
  const who = s.kind === 'identity' ? ['--sign', s.identity, '--keychain', s.keychain] : ['--sign', '-'];
  return ['--force', ...(deep ? ['--deep'] : []), ...who, '--timestamp=none', target];
}

function unlock(s) {
  if (s.kind !== 'identity' || !s.passFile) return;
  const pass = fs.readFileSync(s.passFile, 'utf8').trim();
  // -p on argv is visible to `ps` for a moment; the keychain is a build-only one on the build guest.
  execFileSync('/usr/bin/security', ['unlock-keychain', '-p', pass, s.keychain], { stdio: 'ignore' });
  execFileSync('/usr/bin/security', ['set-keychain-settings', '-t', '3600', s.keychain], { stdio: 'ignore' });
}

/** The user keychain search list, from `security list-keychains -d user` output. Exported for tests. */
function parseSearchList(out) {
  return out.split('\n').map((l) => l.trim().replace(/^"|"$/g, '')).filter(Boolean);
}

/** codesign only finds an untrusted (self-signed) identity in a keychain on the search list, even with --keychain
 * ("The specified item could not be found"). Put the build keychain there for the signing, then put the list back. */
function withSearchList(s, fn) {
  if (s.kind !== 'identity') return fn();
  const before = parseSearchList(execFileSync('/usr/bin/security', ['list-keychains', '-d', 'user'], { encoding: 'utf8' }));
  if (before.includes(s.keychain)) return fn();
  execFileSync('/usr/bin/security', ['list-keychains', '-d', 'user', '-s', ...before, s.keychain]);
  try { return fn(); }
  finally { execFileSync('/usr/bin/security', ['list-keychains', '-d', 'user', '-s', ...before]); }
}

exports.default = async function macSign(context) {
  if (context.electronPlatformName !== 'darwin') return;
  if (process.platform !== 'darwin') throw new Error('the macOS app must be packaged on a Mac (codesign)');
  const s = signer();
  unlock(s);
  const app = path.join(context.appOutDir, `${context.packager.appInfo.productFilename}.app`);
  const loose = walk(path.join(app, 'Contents', 'Resources', 'resources'));
  withSearchList(s, () => {
    for (const f of loose) execFileSync('/usr/bin/codesign', codesignArgs(s, f, false), { stdio: 'inherit' });
    execFileSync('/usr/bin/codesign', codesignArgs(s, app, true), { stdio: 'inherit' });
  });
  execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app], { stdio: 'inherit' });
  const dr = execFileSync('/usr/bin/codesign', ['-d', '-r-', app], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  console.log(`  • ${s.kind === 'identity' ? 'signed with the stable identity' : 'AD-HOC signed (dev build)'} ${path.basename(app)} (${loose.length} bundled binaries)`);
  console.log(`  • designated requirement: ${dr.trim().split('\n').pop()}`);
};
exports.signer = signer;
exports.codesignArgs = codesignArgs;
exports.parseSearchList = parseSearchList;
