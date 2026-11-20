# macOS parity — Devnet dVPN (#33) vs Windows (#31) and Linux (#32)

Every CLI command, feature, screen and protocol, with the Windows and Linux proof next to the Mac
proof. Mac evidence lives in `docs/evidence/mac/` (raw logs; a cell's evidence names the file).
Rigs: **Apple silicon** = GitHub-hosted `macos-15` arm64 (`.github/workflows/macos-rc8.yml`: build, unit + platform
tests, `.dmg` install, live rows `scripts/e2e/mac/gha-live.sh`; `verify-release.yml` checks the published assets).
**Intel** = macOS Sonoma 14 x86_64 guest (OSX-KVM) on GCP host `ddv-mac-host-1`, against #31's six nodes on `ddv-node-1`
(both in the retired project `ddv-node-test-5821`; today's host is `ddv-mac-host-dv`, see `CLAUDE.md`); the matrix and
kill-switch rows below are Intel-guest proof. dvpnd = `fork-cb33-4-final6.16` (pin in `build/deps.lock.json`; the
v0.3.0-rc8 package ships the bytes the rc.4 package shipped from that build, sha `cfc37810…`, under a CI-only lock
override recorded in the run summary). Its macOS patches are part of the private upstream fork and are not in the
public copy of this repo.
Three rigs (`ddv-mac`, `ddv-mac-2`, `ddv-mac-3`) run `scripts/e2e/mac/matrix.sh`; every run's per-case results are
pulled to `docs/evidence/mac/<run>/` and summed by `matrix-json.mjs` (case × protocol, four oracles per cell).

**Rule (#31):** nothing is done until a live run on the final build shows 0 FAIL.

**Status:** ✅ proven live on macOS · 🧪 unit-tested only · ◐ partly · ✗ fails (gap named) ·
⏸ blocked (reason given) · ☐ not run yet · — not applicable

## Current proof (2026-11-15) — read this first

The ☐ cells in the tables below were not updated after the October matrix runs and say "not run" where a live
proof exists. Current state, with the evidence:

| area | macOS | evidence |
|---|---|---|
| Fresh install (dmg, no clicks) → first run → connect → disconnect → settle → uninstall | ✅ 0.3.0-rc.1 | `docs/evidence/mac/rc1/t1-06-fresh.txt`, `t1-07-journey.txt` |
| Update 0.1.3 → 0.3.0-rc.2, connect + settle on rc.2 | ✅ | `docs/evidence/mac/rc2/upgrade-013-*.txt` |
| Per GB / per hour, six protocols | ✅ (dvpnd ddv18.34-mac) | `docs/evidence/mac/final-r2/pay-gb.tsv`, `pay-hour.tsv` |
| Plans: subscribe → connect on the subscription, six protocols | ✅ (10-28/29) | the run's pass files are kept outside this repo (not public); the `matrix/plan-a3a4.tsv` file here is an older VOID run |
| Kill switch on / persist (incl. reboot on rc.2) | ✅ | `final-r1/ks-on.tsv`, `ks-persist.tsv`; `rc2/reboot-B-1cbe290/` |
| Split by address (include + exclude), six protocols | ✅ 0 FAIL | `matrix-r11-rig3/split-route.tsv` |
| Split by app; SOCKS-only V2Ray/Xray; system proxy | ✅ | `rc1/ksm/ksm10-cli-*`; `matrix-r10-rig2/coverage.tsv` |
| Whole device (incl. V2Ray/Xray utun) | ✅ 55 PASS / 0 FAIL | `final-r2/whole.tsv` |
| DNS (kill switch off) | ✅ 61 PASS / 0 FAIL | `matrix-r10-rig2/dns.tsv` |
| Allow LAN | ✅ (10-27, ddv-mac-n1) | the run's pass file is kept outside this repo (not public). The `lan.tsv` FAILs in `matrix-r8-rig2` / `matrix-r10-rig2` ("LAN on: internet still only through the node", egress 136.108.156.183 = the host) are from the old host rig, not the app |
| Settle / withdraw / history | ✅ | `matrix-r10-rig2/money.tsv` |
| Root steps: `sudo -n` (no prompt) and osascript dialog | ✅ | `rc1/t1-07-journey.txt:24-26`; `rc2/upgrade-013-after.txt:21`, `prompt-proof/` |
| Apple silicon (arm64), v0.3.0-rc8: `.dmg` install, device setup (`--allowance 50`), service install, doctor 19 rows / 0 fail, V2Ray connect (exit IP ≠ home), status, disconnect, launchd stop → `next` restarts it, kill switch with the service killed fails closed, GUI window | ✅ (GitHub `macos-15`) | [run 44808199308](https://github.com/Sentinel-Bluebuilder/devnet-dvpn-mac-build/actions/runs/44808199308) (the published build), [run 44813895933](https://github.com/Sentinel-Bluebuilder/devnet-dvpn-mac-build/actions/runs/44813895933) (21 PASS / 3 DIFFERS: plain `device setup` W91, `send_sol_no_fees` row margin, `pf_restore`) |
| Published v0.3.0-rc8 assets on a clean Mac: sums, install, version + devnet ids, ad hoc signature | ✅ | [verify-release 44813935780](https://github.com/Sentinel-Bluebuilder/devnet-dvpn-mac-build/actions/runs/44813935780) |
| Every Mach-O in the arm64 app is arm64 | ✗ v0.3.0-rc8: 3 universal `node_gyp_bins/python3` + 2 `darwin-x64` prebuilds (never loaded); fixed for rc9 (`build/mac/adhoc-sign.cjs` `pruneForeign`, whole-app `checkArch`) | same verify-release run, step 5 |

Per-step agent-flow table: the hub's `docs/PROOF-MACOS.md` ([agentic-privacy-solana-devnet](https://github.com/Sentinel-Bluebuilder/agentic-privacy-solana-devnet/blob/main/docs/PROOF-MACOS.md)).

## Headline

| | Windows (#31) | Linux (#32) | macOS (#33) |
|---|---|---|---|
| CLI commands (catalogue: #31's 71 + Mac `daemon uninstall`) | e2e + VM sweep | ✅ every command live (`cover`: 0 missing) | ☐ |
| Unit tests | Windows suite | ✅ 320/320 on the VM | ✅ `tests/unit` + `tests/platform` (darwin) on GitHub `macos-15`: 321/321 files ([run 44808199308](https://github.com/Sentinel-Bluebuilder/devnet-dvpn-mac-build/actions/runs/44808199308)) |
| Protocols per GB | see LINUX-PARITY | ✅ all six | ☐ |
| Kill switch ON, all six | see LINUX-PARITY | ✅ path lost: no leak · ✗ gap #41 | ☐ |
| System proxy + browser window | ✅ WinINET | ✅ GNOME + KDE | ☐ networksetup |
| UI, every screen, dark + light | ✅ | ✅ | ☐ |
| Installer / clean install / upgrade / uninstall | ✅ | ✅ 22/22 | ◐ arm64: `.dmg` install + device setup + service install ✅ (run 44813895933); upgrade / uninstall: Intel guest only |
| Apple silicon (arm64) | — | — | ✅ live on GitHub `macos-15` (see "Current proof") |

## S12-lite live proof (FMC, 2026-11-08) — fork-cb33-2 x64 dmg

A manual S-suite pass proving the install/upgrade/KS/uninstall path + money + per-protocol
reachability on the fork-cb33-2 x64 dmg (sha `64bacb7b…`), behind the root deadman. Full log:
`docs/evidence/mac/s12-lite-fmc-2026-11-08.md`. Summary: install + hardened plist (root-owned PATH) +
socket `root:sentinel-dvpn` + money ✅; 5/6 protocols (wg/v2ray/xray/openvpn/hysteria2) end-to-end ✅
(AWG unsupported on macOS, UPSTREAM-FIXES #16); upgrade-over → doctor permissions ok + GUI settings
readable ✅; S2 kill switch fail-closed (abnormal tunnel kill → egress blocked) ✅; S10 uninstall clean
(no service/plist/socket/lib/anchors; device key kept) ✅. The full matrix below is TMC's sweep on the RC.

## Releases

Published macOS releases are in [`sentinel-solana-dvpn-macos`](https://github.com/Sentinel-Bluebuilder/sentinel-solana-dvpn-macos/releases).
**v0.3.0-rc8** (Latest, 2026-11-20): arm64 only, ad hoc signed, not notarized, built by
[run 44808199308](https://github.com/Sentinel-Bluebuilder/devnet-dvpn-mac-build/actions/runs/44808199308).

| artifact | sha256 |
|---|---|
| Devnet-dVPN-0.3.0-rc.8-arm64.dmg | `a4295f29a1849d9b2125b783a7eeb303c4e97448113e7e9811d82f44f3c28505` |
| Devnet-dVPN-0.3.0-rc.8-arm64-mac.zip | `b7bda429810c94116e9004b7c5cc461b26f6be06c8875f55ff029d76b5afd1b9` |

Intel Macs: the older x64 releases (guest-built) on the same releases page.

## Matrix — function × protocol (#31's request)

Columns: WG = WireGuard · AWG = AmneziaWG · OVPN = OpenVPN · Hy2 = Hysteria2 · V2 = V2Ray · Xr = Xray.
Each cell names the sweep check that proves it (`~/sweep/<tier>.tsv` in the guest, copied to
`docs/evidence/mac/sweep/`).

| function / setting | WG | AWG | OVPN | Hy2 | V2 | Xr | proof (tier: check) |
|---|---|---|---|---|---|---|---|
| connect per GB, egress = node | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | spend: `<p>: egress IP = node` |
| disconnect leaves nothing (pf, utun, processes), egress direct | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | spend: `<p>: no leftovers` |
| per hour (stream channel) | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | spend: `per hour: egress = node`; ledger: `per_hour <p>: egress = node` |
| switch without a gap | ☐ | — | — | — | ☐ | — | spend: `connect --switch v2ray → wireguard` |
| follow mode | — | — | — | — | — | ☐ | spend: `connect --follow` |
| top up (channels fund) | ☐ | — | — | — | — | — | ledger: `topup: channels fund <live channel> during the session` (billing is protocol-independent) |
| settle + withdraw | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | spend: `settle run`, `settle withdraw` |
| plans: subscribe → connect on subscription → close | ⏸ | ⏸ | ⏸ | ⏸ | ⏸ | ⏸ | spend with `PLAN_ADDR` (needs a plan #31 allows; not 6zKPsC/8CRB4PKg) |
| kill switch OFF: DNS = VPN DNS on every service | ☐ | ☐ | ☐ | ☐ | — | — | ledger: `dns-off <p>: VPN DNS 1.1.1.1 on every service` |
| kill switch ON: pf anchor loaded, names resolve | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ksdns: `pf anchor sentinel-dvpn-c0 is loaded`, `names resolve` |
| kill switch ON: pf passes the utun that exists (#29 shape) | ☐ | ☐ | ☐ | ☐ | — | — | ksdns: `pf passes the utun that exists` |
| kill switch ON: direct request blocked (SOCKS protocols) | — | — | — | — | ☐ | ☐ | ksdns: `a direct (non-proxied) request is blocked` |
| kill switch ON: path to server lost → no leak | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ksdns: `path to the server lost` (test pf anchor before dvpnd's) |
| kill switch ON: tunnel died (utun down / process killed) → no leak, also 25 s later | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ksdns: `tunnel broken`, `25 s later` (gap #41 fixed in ddv6) |
| kill switch ON: dvpnd itself dies → no leak | ☐ | — | — | ☐ | ✅ arm64 (GitHub macos-15 run 44813895933 pf_restore: block held) | — | ledger: `kill-on <p>: dvpnd SIGKILLed` (launchd restarts it; same two protocols as #32) |
| kill switch persist: service restart + dvpnd SIGKILL never leak | ☐ | — | ☐ | — | — | — | ledger: `persist <p>: …` (same two protocols as #32) |
| restore network: pf / DNS / proxy exactly as before | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ksdns: `after restore`, `final: pf main ruleset as before` |
| DNS leak, kill switch off: no lookup on the physical interface | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ledger: `dns-off <p>: no lookup leaves on <if>` (tcpdump; V2/Xr: SOCKS-resolved names), positive control first |
| IPv6 leak | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ksdns: `IPv6 never leaves directly` (the GCP guest has no IPv6 route, so this proves little: recorded) |
| per-app split: system proxy (networksetup) | — | — | — | — | ☐ | ☐ | spend: `proxy on: every enabled service`, Chrome oracle |
| per-app split: browser window through SOCKS | — | — | — | — | ☐ | ☐ | spend: `proxy browser` |
| per-app split: everything else stays direct | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | coverage label on Connect (device / proxy-apps); UI scenario `coverage=` |
| per-destination split (#1) | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | matrix: `split-route` (dvpnd split routes; pf permits with the kill switch on: `split-ks`) |
| V2Ray/Xray whole device (utun) | — | — | — | — | ☐ | ☐ | matrix: `whole` (#33 patches: darwin TUN via the Xray helper, IPv6 reject routes) |
| adopt an existing device key | ☐ | | | | | | daemon: `device register reads device.pub`; installer: reinstall keeps the device |
| uninstall leaves nothing (but the device key) | ☐ | | | | | | installer: `uninstall: …` (7 checks) |
| update over a running service | ☐ | | | | | | installer: `update: …` (stale copy flagged, refreshed) |
| node test run | ☐ | — | — | — | ☐ | — | spend: `test run (wireguard + v2ray)` |

## Platform pieces (Mac-specific)

| piece | proof |
|---|---|
| LaunchDaemon: KeepAlive restarts a crashed dvpnd | ✅ arm64 (GitHub macos-15 run 44813895933: kill -9, service back, connect ok); installer: `launchd restarts the service after a crash` |
| socket `root:sentinel-dvpn 0660` + inherited user ACL | ☐ daemon: `socket root:sentinel-dvpn 0660 with an ACL` |
| key folder root-only; `device.pub` readable | ✅ root-only on arm64 (GitHub macos-15 run 44813895933: doctor as the user, keys/ permission denied); daemon: `device key folder is root-only` |
| service PATH = root-owned copies only | ☐ daemon: `service runs root-owned copies only` |
| root steps: `sudo -n` (rig) | ✅ arm64 (GitHub macos-15 run 44813895933: daemon install --yes with passwordless sudo); daemon tier settings round trips |
| root steps: osascript admin prompt (GUI) | ☐ one prompt answered through QMP keystrokes (installer, GUI) |
| CLI wallet in the login Keychain; locked Keychain → action | ☐ local: `wallet secret is in the Keychain`, `Keychain locked says what to do` |
| app wallet: safeStorage (Keychain) | ☐ ui-smoke with a created wallet |
| drivers: Homebrew as the user + AmneziaWG from pinned source | ☐ daemon: `daemon repair-drivers`, `daemon drivers` all ready |
| login item (LaunchAgent) on/off | ☐ ui-smoke Settings toggle + `launchctl print gui/<uid>/…` |
| Terminal `.command` for the CLI screen | ☐ ui-smoke "Open in Terminal" |
| `.dmg` ad-hoc signature verifies | ✅ v0.3.0-rc8 (verify-release 44813935780: Signature=adhoc, deep verify OK); installer: `dmg: verifies and holds a signed app` |

## Every CLI command

Filled from `cli-sweep.sh cover` (0 MISSING = done); evidence `docs/evidence/mac/sweep/cover.txt`.
