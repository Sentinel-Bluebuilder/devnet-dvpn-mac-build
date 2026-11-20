# Final audit — macOS pages (#38, AC-MAC-1)

Every macOS claim on the pages the public macOS repo (`Sentinel-Bluebuilder/sentinel-solana-dvpn-macos` README) and the hub
(`Desktop/sentinel-agent-connect-solana` = agentic-privacy-solana-devnet) cite, checked against #33 `65247b082` and the
rc.8 evidence on real Apple silicon (GitHub `macos-15`, arm64):

- **B** = build + live run [44808199308](https://github.com/Sentinel-Bluebuilder/devnet-dvpn-mac-build/actions/runs/44808199308)
  (#33 `72b903539`, the build **published as v0.3.0-rc8**; artifact `macos-rc8-live-evidence`)
- **L** = build + live run [44813895933](https://github.com/Sentinel-Bluebuilder/devnet-dvpn-mac-build/actions/runs/44813895933)
  (#33 `b0197b5c1`, rc.8 + AC-MAC-3's audit fixes; artifact `macos-live-evidence`, 21 PASS / 3 DIFFERS)
- **V** = verify-release on the published v0.3.0-rc8 assets
  [44813935780](https://github.com/Sentinel-Bluebuilder/devnet-dvpn-mac-build/actions/runs/44813935780)

Verdicts: **true** · **false** (fix given) · **stale** (true once, not for rc.8 / the code now) · **unverified** (no evidence
either way on this rig; named why). Line numbers are at the commits named.

## 1. Hub `docs/INSTALL-BY-HAND.md` (hub `8a459c8`), macOS block → AC-CODES

| file:line | claim | verdict | fix |
|---|---|---|---|
| INSTALL-BY-HAND.md:3, :25 | v0.3.0-rc8 macOS = Apple silicon only, no Intel build | true (V: assets = `-arm64.dmg`, `-arm64-mac.zip`, `SHA256SUMS`) | — |
| :26 | an older app goes first (`sudo -n rm -rf …`), `ditto` merges into an existing app | true (ditto semantics; B/L installs ran `rm -rf` then `ditto`) | — |
| :30 | `A=x64` unless `hw.optional.arm64` = 1 | true | — |
| :33 | "no $A build in this release …; stop here" | **false**: it only `echo`es; the next lines still run with an empty `$F` (`curl -fsSLO "$U/"` fails, `grep " \$"` matches nothing, `hdiutil attach ./` errors) | make it stop: `[ -n "$F" ] \|\| { echo "no $A build in this release (Intel Macs: docs/OLDER-RELEASES.md)"; exit 1; }` (or tell the reader to stop and run nothing below in the same paste) |
| :31-35 | download `SHA256SUMS` + the dmg, `shasum -a 256 -c` prints `OK` | true (V step 1: both files OK) | — |
| :36 | `M=$(hdiutil attach -nobrowse -readonly … \| tail -1 \| cut -f3-)` gives the mount point | true (same parse class as V/B; mount `/Volumes/Devnet dVPN 0.3.0-rc.8`) | — |
| :37-39 | `sudo -n ditto` to `/Applications`, `hdiutil detach`, `sudo -n xattr -dr com.apple.quarantine` ("not notarized") | true (B/L/V; V step 4: `Signature=adhoc`, deep verify OK) | — |
| :40 | the CLI is `/Applications/Devnet dVPN.app/Contents/Resources/bin` | true (V step 3 ran `…/Contents/Resources/bin/devnet-dvpn version --json` = 0.3.0-rc.8, devnet) | — |
| :41 | `brew install wireguard-tools wireguard-go openvpn bash` as the user (or `daemon repair-drivers --yes`) | true for the brew line (B/L "Drivers" step, then a v2ray connect); `repair-drivers` exists (catalogue) but was not run here | — |
| :44 | V2Ray, Xray, Hysteria2 need no `brew` | true (bundled in `Contents/Resources/resources/bin`, build log `ok xray`/`hysteria2`/`v2ray`; L connected over v2ray with no brew dependency) | — |

## 2. Hub `docs/TROUBLESHOOTING.md` (hub `8a459c8`), macOS rows → AC-CODES

| file:line | claim | verdict | fix |
|---|---|---|---|
| TROUBLESHOOTING.md:3 | covers v0.3.0-rc8, macOS Apple silicon included | true | — |
| :25, :78 | `keyfile-mode`, exit 4, checked on macOS; fix `chmod 600 <file>` | true (L `keyfile_mode.out`: exit 4, code `keyfile-mode`, next `chmod 600 …, then devnet-dvpn agent up --yes`) | — |
| :45 | macOS rc8, kill switch on, service killed: `restore-network` = `daemon-unavailable` ("Restart the Mac") **with no `next`**, no internet | true **for the published rc8** (B `pf_restore1.out`: exit 1, `next: null`, net after = no). Post-rc.8 code adds the next (L `pf_restore1.out`: `next` = `sudo launchctl kickstart -k system/co.sentinel.sentinel-dvpnd.c0, then devnet-dvpn daemon restore-network`, `src/cli/cli-fail.ts:55`) | for rc9: drop "with no next" and name the next it now gives |
| :45 (fix column) | `kickstart -k`, then `restore-network`; if still blocked `sudo pfctl -a sentinel-dvpn-c0 -F all` | partly proven: the anchor name `sentinel-dvpn-c0` is right (L `pf_restore.out` attach line `anchor "sentinel-dvpn-c0" quick all`); service back (launchd KeepAlive) + `restore-network` → attach line and anchor rules gone (L `pf_restore2.out` ok, end attach `[]`). Not run in the exact order of the row (the row checks the network before the second restore) | keep; the evidence for "kickstart then restore lifts the block" is L's final restore; a direct row is AC-MAC-3's `pf_restore` |
| :62 (macOS part) | rc8 macOS: stopped service → `next` = `sudo launchctl bootstrap system /Library/LaunchDaemons/co.sentinel.sentinel-dvpnd.c0.plist`, then `agent up --yes` ("proven") | true (L `launchd_stopped_status.out`: `"service":false`, that exact `next`, `alsoNext` agent up; doctor service row says the same; ran verbatim, service back) | — |
| :65 | `daemon-missing` → `daemon install --yes` as root or with passwordless `sudo` (macOS) | true (L `install.out`: exit 0 as the runner user with passwordless sudo) | — |
| :67 | macOS over SSH: login Keychain locked → use `DVPN_KEYFILE` / `--keyfile`; a key-file wallet never touches the Keychain | unverified here (GHA has no SSH session and used a key file throughout; the key-file half is consistent: B/L never touched the Keychain) | — |
| :71 | `clock-skew`, run the time-sync line in `next` | true for the code + next (L `clock_skew.out`: exit 4, `next` = `sudo sntp -sS time.apple.com, then devnet-dvpn agent up --yes`); that the sync line fixes it is unverified (GHA blocks NTP: sntp timed out) | — |

## 3. #33 `docs/MAC-PARITY.md` (public README cites it)

| file:line | claim | verdict | fix |
|---|---|---|---|
| MAC-PARITY.md:5-6 | rig = Intel Sonoma guest on `ddv-mac-host-1` / `ddv-node-1` | stale (retired project); arm64 now runs on GitHub `macos-15` | add the GHA rig: "Apple silicon: GitHub-hosted `macos-15` arm64 (`.github/workflows/macos-rc8.yml`)" |
| :6 | dvpnd = `cf4c372-ddv15.2-mac<N>` | **false** for rc.8: lock = `sentinel-dvpnd-darwin-arm64-fork-cb33-4-final6.16`; the rc.8 package ships the rc.4-built final6.16 bytes `cfc37810…` (CI lock override, B summary) | name `fork-cb33-4-final6.16` and the override |
| :6-7 | macOS patches in `docs/patches/` | true in #33, **broken in the public copy** (`docs/patches/dvpnd-*` is excluded from every public export) | say "(private; not in the public copy)" or drop the path |
| :26, :32 | evidence in `~/memory/cells/results/…` | not reachable by a public reader | move the files under `docs/evidence/mac/` or mark them private |
| :35, :50 | Apple silicon: "⏸ built + signed, never run" / "built, not run (rig is Intel-only)" | **false** since 2026-11-20: B and L ran rc.8 arm64 live (dmg install, device setup, service install, doctor 19 rows 0 fail, v2ray connect, exit IP ≠ home, status, down, launchd, GUI smoke) | ✅ with B/L run links; name what is still Intel-only proof (six-protocol matrix, KS matrix) |
| :37 | per-step table at `Desktop/sentinel-agent-connect-solana/docs/PROOF-MACOS.md` | a laptop path, not a link | link the hub's `docs/PROOF-MACOS.md` |
| :44 | unit tests "🧪 laptop (Windows) green; ☐ guest run" | **false**: `tests/unit` + `tests/platform` (darwin) green on real macOS: B build log "Test Files 321 passed (321)" | ✅ with the B link |
| :49 | installer "☐ dmg + first-run setup" | partly false: dmg install + `device setup --allowance 50` + `daemon install --yes` ✅ on arm64 (L `setup_allowance`, `install`); plain `device setup` refuses on a 60 tDVPN wallet (W91, rc.8; fixed in rc.9) | ◐ with L; name W91 |
| :64-78 | "Release candidates": interim 0.1.3 RC; "Final RC … pending FWX (~1–2 h)" | stale (v0.3.0-rc8 is published) | replace with the published release + sums (`a4295f29…` dmg, `b7bda429…` zip) and the V result |
| :88 (V2 column) | connect per GB, egress = node | ✅ for V2Ray on arm64 (L `up.out` protocol `v2ray`; `exit_ip` 185.241.226.196 ≠ home) | mark V2 ✅ (arm64) with L |
| :102 | kill switch ON: dvpnd dies → no leak | ✅ fail-closed on arm64 (L `pf_restore.out`: after `kill -9`, anchor = `block drop out all`, direct request failed) | mark ✅ (the protocol L used) |
| :104 | restore network: pf exactly as before | ◐: after a killed service, the first `restore-network` cannot lift the block (service down, B/L `pf_restore1`); once the service is back, restore leaves no attach line or anchor rules (L end attach `[]`) | ◐ with L; the open item is AC-MAC-3's `pf_restore` row (M5) |
| :121 | LaunchDaemon KeepAlive restarts a crashed dvpnd | ✅ (L: after `kill -9`, `wait_service` saw it back and `pf_up2` connected, exit 0) | mark ✅ |
| :122 | socket `root:dvpn 0660` | **false** name: group is `sentinel-dvpn` (`resources/scripts/setup-daemon.sh:23`); socket under `/Library/Application Support/sentinel-dvpn/c0` (`src/main/daemon/manager.ts:33`) | `root:sentinel-dvpn 0660` |
| :123 | key folder root-only; `device.pub` readable | ✅ for root-only (L `launchd_stopped_doctor.out`: as the user, `open …/c0/keys: permission denied`) | mark ✅ |
| :125 | root steps: `sudo -n` | ✅ (L `install.out` as the runner user with passwordless sudo) | mark ✅ |
| :129 | drivers: Homebrew as the user | ◐ (brew line ran as the user in B/L; `daemon repair-drivers` not run) | ◐ |
| :130-131 | login item, Terminal `.command` | unverified (not in any GHA row) | — |
| :132 | `.dmg` ad hoc signature verifies | ✅ (V step 4: `Signature=adhoc`, `codesign --verify --deep --strict` OK) | mark ✅ |
| (new) | every Mach-O in the arm64 app is arm64 | **✗ for the published rc8** (V step 5: 29 Mach-O, 5 not arm64-only: 3 universal `node_gyp_bins/python3`, 2 `darwin-x64` prebuilds); fixed for rc9 by `bea4ebaec` | add the row with V and the rc9 fix |

## 4. #33 README-linked pages: `INSTALLER.md`, `ARCHITECTURE.md`, `NETWORK-SAFETY.md` (macOS facts, at `65247b082`)

The code moved to the cb33 layout; these pages still describe the pre-cb33 one. Truth at `65247b082`: label
`co.sentinel.sentinel-dvpnd.c0` (L `launchd_print`: `system/co.sentinel.sentinel-dvpnd.c0` running), home
`/Library/Application Support/sentinel-dvpn/c0` (`manager.ts:7,33`, `layout.ts:18`), group `sentinel-dvpn`
(`setup-daemon.sh:23`), root-owned lib `/Library/devnet-dvpn` (`setup-daemon.sh:134-138` migrates the legacy
`/usr/local/lib/devnet-dvpn`).

| file:line | claim | verdict | fix |
|---|---|---|---|
| INSTALLER.md:13, :26, :28, :53 | root-owned copy in `/usr/local/lib/devnet-dvpn` | **false** (legacy path, migrated away) | `/Library/devnet-dvpn` |
| INSTALLER.md:15, ARCHITECTURE.md:46, NETWORK-SAFETY.md:14 | plist `network.sentinel.devnet-dvpn.dvpnd(.plist)` | **false** | `/Library/LaunchDaemons/co.sentinel.sentinel-dvpnd.c0.plist`, label `co.sentinel.sentinel-dvpnd.c0` |
| INSTALLER.md:22, ARCHITECTURE.md:26, :119 | group `dvpn` | **false** | `sentinel-dvpn` |
| INSTALLER.md:23, :55, ARCHITECTURE.md:18, :119 | home `/var/db/dvpnd/client` | **false** (pre-cb33; migrated once) | `/Library/Application Support/sentinel-dvpn/c0` (a space in the path) |
| INSTALLER.md:77 | designated requirement `identifier "network.sentinel.devnet-dvpn"` | true for the app bundle id (`appId: network.sentinel.devnet-dvpn`, `electron-builder.yml`); not the service label | — (keep; do not confuse with the label) |
| INSTALLER.md:5 | signed with a stable self-signed identity | **false for the published rc8**: ad hoc (`DVPN_MAC_ADHOC=1`, V step 4) | "rc8 from CI is ad hoc signed (its Keychain identity differs from a self-signed build)" |
| INSTALLER.md:52 | never `pfctl -F all` / `pfctl -d` | true (restore path uses the anchor only) | — |
| NETWORK-SAFETY.md:11 | kill-switch pf anchor `dvpnd` | **false** name on rc.8: `sentinel-dvpn-c0` (L `pf_restore.out`) | `sentinel-dvpn-c0` |
| NETWORK-SAFETY.md:43 | arm64 builds are built, not run | **false** (B/L) | arm64 runs on GitHub `macos-15`; Intel stays on the guest rig |
| `resources/scripts/install-deps.sh:7` (comment) | tools in `/usr/local/lib/devnet-dvpn/tools` | stale comment | `/Library/devnet-dvpn/tools` |

Correction (lead, 2026-11-20): the public macOS README's `docs/known-issues-rc1.md` link points to the testing-tools
repo, where the file exists and is public; it is not a dead link. #33's own README has no such link.

## Fixed

All H rows in sections 3 and 4 are fixed in #33 `08dbbeaa7` (MAC-PARITY, INSTALLER, ARCHITECTURE, NETWORK-SAFETY,
MAC-PORT, SETTINGS-MAP, README). Old names left on purpose: `INSTALLER.md` dated history (`/var/db/dvpnd` moved
aside on the guest), the Signing section's description of the guest's self-signed identity (a real, optional
build path), `MAC-PORT.md` Linux column and migration notes, and `LINUX-PORT.md` (Linux facts). Hub rows (sections
1-2) went to AC-CODES.
