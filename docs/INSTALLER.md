# macOS packages — Devnet dVPN

One build (`npm run release:mac`, on a Mac) makes a **.dmg** (drag to Applications) and a
**.zip** (scripted installs), each for **x64** and **arm64**. Not notarized (owner decision). The
published v0.3.0-rc8 is **ad hoc signed** and **arm64 only** (built on GitHub `macos-15` by
`.github/workflows/macos-rc8.yml` with `DVPN_MAC_ADHOC=1`); a build on the guest can instead sign with the
stable identity (see Signing). The Windows installer is #31's `docs/INSTALLER.md`; Linux is #32's.

## What the user gets

| | |
|---|---|
| App | `/Applications/Devnet dVPN.app` |
| CLI | `/usr/local/bin/devnet-dvpn` → `Devnet dVPN.app/Contents/Resources/bin/devnet-dvpn` (made by the service setup; the app's CLI screen → "Open in Terminal" works before that) |
| Root helper | ONE entry point `resources/scripts/dvpn-helper` (whitelist `HELPER_STEPS`), run through `osascript … with administrator privileges`; after setup the root-owned copy in `/Library/devnet-dvpn/scripts` is used |
| VPN drivers | Diagnostics → Repair drivers (or `daemon repair-drivers --yes`): Homebrew, **as the Mac user**, installs `wireguard-tools wireguard-go openvpn bash go`; AmneziaWG is built from pinned source (`amneziawg-tools` / `amneziawg-go` v3.1.20260812, same generation as the nodes). Root then copies them into `/Library/devnet-dvpn/tools` |
| Service | first run: device setup, then ONE admin prompt writes `/Library/LaunchDaemons/co.sentinel.sentinel-dvpnd.c0.plist` |

The VPN service (`dvpnd`, client role, root) is installed by the app's first run, not by the
package: dvpnd will not start until its device key holds an on-chain permission, which needs
the user's wallet. A .dmg has no install hooks, so everything root needs happens in that one
prompt (`setup-daemon.sh`):

1. group `sentinel-dvpn` (`dseditgroup`), the user added to it;
2. the staged home copied to `/Library/Application Support/sentinel-dvpn/c0`, key folders `root:wheel 0700`, `device.pub`
   world-readable, an inherited ACL for the user so the socket dvpnd re-creates stays reachable;
3. root-owned copies of dvpnd, V2Ray, Xray, Hysteria2, the Homebrew tools and the helper scripts
   in `/Library/devnet-dvpn` (quarantine removed). **Root never executes anything from the
   app bundle or the user-writable Homebrew prefix**; `wg-quick`/`awg-quick` run under the
   copied bash 5 (`#!/Library/devnet-dvpn/tools/bash`);
4. the LaunchDaemon (KeepAlive, `ThrottleInterval` 60 s so a device without its grant does not
   burn RPC calls), PATH = only those root-owned folders;
5. the `/usr/local/bin/devnet-dvpn` link.

## Update

Drag the new app over the old one. The running service keeps its root-owned copies, so the app
compares them with what it ships (`serviceStaleFiles()`: dvpnd, protocol binaries, helper
scripts). When they differ, Diagnostics → Service check shows **Service version !** with
**Update the VPN service** (one prompt; re-runs setup over the kept home, which also renames old
dvpnd config keys with `migrate-daemon-config.sh`). CLI: `devnet-dvpn daemon doctor` shows the
same row; `devnet-dvpn daemon install --yes` updates.

## Uninstall

Diagnostics → **Remove the VPN service** or `devnet-dvpn daemon uninstall --yes`
(`uninstall-cleanup.sh`, one prompt), then drag the app to the Trash:

- the SOCKS system proxy put back on every network service, only where ours is still set;
- the service stopped (a clean stop ends the session and releases the pf kill switch and DNS),
  the LaunchDaemon removed;
- `remove-tunnels.sh` for anything a dead session left: our protocol processes, wg-quick utun
  links, the `sentinel-dvpn-c0` pf anchor (and a pre-cb33 `dvpnd` one) + its attach line + its enable token, DNS from dvpnd's networksetup backup.
  **Never** `pfctl -F all` or `pfctl -d`: the user's own pf rules stay;
- `/Library/devnet-dvpn` and the CLI link removed.

Kept on purpose: `/Library/Application Support/sentinel-dvpn/c0` (the device key holds an on-chain permission and SOL;
a reinstall picks it up) and the `sentinel-dvpn` group (the kept home is owned by it). Homebrew packages
stay (they are the user's).

## Dependencies are pinned and verified

`build/deps.lock.json` pins Hysteria2, V2Ray and Xray (darwin amd64 + arm64) by version, URL and
SHA-256, checked against each publisher's own digest file. `scripts/fetch-deps.mjs --arch
x64|arm64` refuses a mismatch, extracts only the listed files and copies `dvpnd` from the darwin
build (`fork-cb33-4-final6.16`, sha pinned per arch). `resources/bin` holds one arch at a time;
`release-mac.mjs` fetches and packages each arch in turn.

## Signing

`identity: null` (electron-builder signs nothing), then `build/mac/adhoc-sign.cjs` (afterPack)
signs every loose Mach-O in `Contents/Resources/resources` and the bundle, and verifies it: Apple
Silicon refuses code with no signature. Gatekeeper still warns on first open (right-click → Open).
Notarization needs an Apple Developer ID: owner decision.

Guest builds (since 0.3.0-rc.2) sign with ONE stable self-signed code-signing identity, not
ad hoc. The CI build (v0.3.0-rc8, GitHub `macos-15`) has no such identity and signs **ad hoc**
(`DVPN_MAC_ADHOC=1`): its Keychain identity differs from a guest build, so installing it over a guest build
asks for the login keychain password once. Why the stable identity: ad hoc, the designated requirement is the build's cdhash, so every update was a new app to
the Keychain and its first start asked for the login keychain password ("Devnet dVPN Safe
Storage"). With the stable identity the requirement is `identifier "network.sentinel.devnet-dvpn"
and certificate root = H"…"` for every build, so the grant survives updates (self-signed: root = leaf). Env for the build:
`DVPN_MAC_SIGN_IDENTITY` (SHA-1), `DVPN_MAC_SIGN_KEYCHAIN`, `DVPN_MAC_SIGN_KEYCHAIN_PASS_FILE`.
The identity lives in a build-only keychain on the build guest and is backed up outside every repo;
losing it means the next update asks once more. Without it the build fails, unless
`DVPN_MAC_ADHOC=1` asks for an ad-hoc dev build.

## CLI shim

`Contents/Resources/bin/devnet-dvpn` (bash) follows its own symlink chain without
`readlink -f` (missing before macOS 13) and runs the bundled CLI on the app's own runtime
(`ELECTRON_RUN_AS_NODE=1 "Contents/MacOS/Devnet dVPN" Contents/Resources/app.asar/out/cli/devnet-dvpn.cjs`),
the pattern of VS Code's `code`. If the app was moved it says so (exit 127).

## Packaging rule: main and CLI are self-contained bundles

Same as #31: the main process and the CLI bundle every runtime dependency (electron-builder 25
re-nests deduplicated npm packages and drops some).

## Build

```bash
npm run release:mac                    # typecheck → tests → build → CLI → per arch: fetch-deps + electron-builder → SHA256SUMS
node scripts/release-mac.mjs --skip-tests --arch x64
```

Output: `dist/Devnet-dVPN-<version>-{x64,arm64}.dmg`, `dist/Devnet-dVPN-<version>-{x64,arm64}-mac.zip`,
`dist/SHA256SUMS.txt`. Build on a Mac (the guest: `bash scripts/e2e/mac/sync.sh`).

## Install from a terminal (no clicks)

For scripts and AI agents. The rig installs every build this way (`scripts/e2e/mac/ksm/chain3.sh`,
`ksm/ksm-setup.sh`). An administrator account is needed; with passwordless `sudo` (`sudo -n`)
nothing asks, otherwise `daemon install` opens the macOS password dialog (osascript, needs a person
at the screen; `src/main/system/elevate.ts`).

```bash
M=$(hdiutil attach -nobrowse -readonly Devnet-dVPN-<version>-x64.dmg | tail -1 | cut -f3-)
sudo -n ditto "$M/Devnet dVPN.app" "/Applications/Devnet dVPN.app"; hdiutil detach -quiet "$M"
CLI="/Applications/Devnet dVPN.app/Contents/Resources/bin/devnet-dvpn"   # /usr/local/bin link comes with daemon install
"$CLI" wallet create --keyfile ~/dvpn-key.json --yes; export DVPN_KEYFILE=~/dvpn-key.json
"$CLI" daemon init && "$CLI" device setup --yes && "$CLI" daemon install --yes   # after funding the wallet
```

A key file (`--keyfile` / `DVPN_KEYFILE`) never touches the Keychain, which is locked in an SSH
session. A dmg fetched with `curl` carries no quarantine flag, so no Gatekeeper dialog (not yet
proven on the rig: rig dmgs are built in the guest).

## Proof — macOS Sonoma x86_64 in QEMU on GCP (`ddv-mac-dv`)

- **Fresh install + first run, 0.3.0-rc.1 (T1, 2026-11-12):** dmg mounted and copied as above → `version` →
  `wallet create` → funded by `wallet send` → `daemon init` → `device setup` → `daemon install` (no prompt,
  `sudo -n`) → WireGuard connect, exit IP = node → disconnect, direct IP back → `settle run` →
  `daemon uninstall`, network as before. `docs/evidence/mac/rc1/t1-06-fresh.txt`, `t1-07-journey.txt`
  (the guest's old `/var/db/dvpnd` was moved aside first: uninstall keeps the device home on purpose).
- **Update 0.1.3 → 0.3.0-rc.2 (2026-11-14):** same wallet, device and settings kept; "Update the VPN service"
  via the osascript prompt; connect / disconnect / settle on rc.2. `docs/evidence/mac/rc2/upgrade-013-*.txt`.
- `scripts/e2e/mac/installer-test.sh` (install → update over a running service → uninstall → reinstall
  keeps the device) is the scripted form; per-run results in `docs/evidence/mac/`.
- arm64: v0.3.0-rc8 installed and run live on GitHub `macos-15` (`.github/workflows/macos-rc8.yml`; install, device setup, service, connect, kill switch); upgrade and uninstall are Intel-guest proof only.
