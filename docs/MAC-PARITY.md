# macOS parity — Devnet dVPN (#33) vs Windows (#31) and Linux (#32)

Every CLI command, feature, screen and protocol, with the Windows and Linux proof next to the Mac
proof. Mac evidence lives in `docs/evidence/mac/` (raw logs; a cell's evidence names the file).
Rig: macOS Sonoma 14 x86_64 guest (OSX-KVM) on GCP host `ddv-mac-host-1`, against #31's six nodes
on `ddv-node-1` (both in the retired project `ddv-node-test-5821`; today's host is `ddv-mac-host-dv`, see `CLAUDE.md`). dvpnd = cf4c372-ddv15.2-mac<N> (#31/#32 parity tree + #33 macOS patches 0007–0026 in
`docs/patches/`; pin in `build/deps.lock.json`), darwin build (`scripts/e2e/mac/build-dvpnd.sh`, on the GCP host).
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
| Plans: subscribe → connect on the subscription, six protocols | ✅ (10-28/29) | `~/memory/cells/results/M-plan-a3a4{,-ovh,-vx}.pass` (the `matrix/plan-a3a4.tsv` file is an older VOID run) |
| Kill switch on / persist (incl. reboot on rc.2) | ✅ | `final-r1/ks-on.tsv`, `ks-persist.tsv`; `rc2/reboot-B-1cbe290/` |
| Split by address (include + exclude), six protocols | ✅ 0 FAIL | `matrix-r11-rig3/split-route.tsv` |
| Split by app; SOCKS-only V2Ray/Xray; system proxy | ✅ | `rc1/ksm/ksm10-cli-*`; `matrix-r10-rig2/coverage.tsv` |
| Whole device (incl. V2Ray/Xray utun) | ✅ 55 PASS / 0 FAIL | `final-r2/whole.tsv` |
| DNS (kill switch off) | ✅ 61 PASS / 0 FAIL | `matrix-r10-rig2/dns.tsv` |
| Allow LAN | ✅ (10-27, ddv-mac-n1) | `~/memory/cells/results/M-lan.pass`. The `lan.tsv` FAILs in `matrix-r8-rig2` / `matrix-r10-rig2` ("LAN on: internet still only through the node", egress 136.108.156.183 = the host) are from the old host rig, not the app |
| Settle / withdraw / history | ✅ | `matrix-r10-rig2/money.tsv` |
| Root steps: `sudo -n` (no prompt) and osascript dialog | ✅ | `rc1/t1-07-journey.txt:24-26`; `rc2/upgrade-013-after.txt:21`, `prompt-proof/` |
| Apple silicon (arm64) | ⏸ built + signed, never run | `rc2/MANIFEST.txt` |

Per-step agent-flow table: `Desktop/sentinel-agent-connect-solana/docs/PROOF-MACOS.md`.

## Headline

| | Windows (#31) | Linux (#32) | macOS (#33) |
|---|---|---|---|
| CLI commands (catalogue: #31's 71 + Mac `daemon uninstall`) | e2e + VM sweep | ✅ every command live (`cover`: 0 missing) | ☐ |
| Unit tests | Windows suite | ✅ 320/320 on the VM | 🧪 laptop (Windows) green; ☐ guest run |
| Protocols per GB | see LINUX-PARITY | ✅ all six | ☐ |
| Kill switch ON, all six | see LINUX-PARITY | ✅ path lost: no leak · ✗ gap #41 | ☐ |
| System proxy + browser window | ✅ WinINET | ✅ GNOME + KDE | ☐ networksetup |
| UI, every screen, dark + light | ✅ | ✅ | ☐ |
| Installer / clean install / upgrade / uninstall | ✅ | ✅ 22/22 | ☐ dmg + first-run setup |
| Apple silicon (arm64) | — | — | ⏸ built, not run (rig is Intel-only) |

## S12-lite live proof (FMC, 2026-11-08) — fork-cb33-2 x64 dmg

A manual S-suite pass proving the install/upgrade/KS/uninstall path + money + per-protocol
reachability on the fork-cb33-2 x64 dmg (sha `64bacb7b…`), behind the root deadman. Full log:
`docs/evidence/mac/s12-lite-fmc-2026-11-08.md`. Summary: install + hardened plist (root-owned PATH) +
socket `root:sentinel-dvpn` + money ✅; 5/6 protocols (wg/v2ray/xray/openvpn/hysteria2) end-to-end ✅
(AWG unsupported on macOS, UPSTREAM-FIXES #16); upgrade-over → doctor permissions ok + GUI settings
readable ✅; S2 kill switch fail-closed (abnormal tunnel kill → egress blocked) ✅; S10 uninstall clean
(no service/plist/socket/lib/anchors; device key kept) ✅. The full matrix below is TMC's sweep on the RC.

## Release candidates

### Interim RC — fork-cb33-2 daemon ddv20, built from main `1b7f2cf3` (2026-11-08, gated typecheck + tests green)

For TMC's S3–S9 on the Intel guest. Daemon = fork-cb33-2-ddv20 (AmneziaWG runtime works via
install-deps.sh; doctor still cosmetically warns `service_platform_amneziawg` unsupported — that
clears only on the fork-cb33-4 daemon carrying FWX's SDK fix d3746b4). Tools from Homebrew at setup
(not yet bundled). To be superseded by the fork-cb33-4 RC (doctor-clean AWG + all tools bundled).

| artifact | sha256 | status |
|---|---|---|
| Devnet-dVPN-0.1.3-x64.dmg | `26471f38f1112232e36e6c8936965f6c2080d9ac84582268eee8d5784929eaad` | live-provable (Intel guest) |
| Devnet-dVPN-0.1.3-x64-mac.zip | `4d62b50d062d18b952ec763c70e6ec5bb2c6868a88ff5b056bb891354e494533` | live-provable (Intel guest) |
| Devnet-dVPN-0.1.3-arm64.dmg | `ec51ab19c6b722973abe6acd8e61c7c83857d5db6f893eadc2cb949cd2ba5b58` | built only (rig is Intel) |
| Devnet-dVPN-0.1.3-arm64-mac.zip | `6e973850e9ee37915eb59b30ba72bfe1ba80354acd3b272a3501ff57a8474e4c` | built only (rig is Intel) |

### Final RC — fork-cb33-4 + all tools bundled + OSS fixes — _pending FWX fork-cb33-4 (~1–2 h)_

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
| kill switch ON: pf anchor loaded, names resolve | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ksdns: `pf anchor dvpnd is loaded`, `names resolve` |
| kill switch ON: pf passes the utun that exists (#29 shape) | ☐ | ☐ | ☐ | ☐ | — | — | ksdns: `pf passes the utun that exists` |
| kill switch ON: direct request blocked (SOCKS protocols) | — | — | — | — | ☐ | ☐ | ksdns: `a direct (non-proxied) request is blocked` |
| kill switch ON: path to server lost → no leak | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ksdns: `path to the server lost` (test pf anchor before dvpnd's) |
| kill switch ON: tunnel died (utun down / process killed) → no leak, also 25 s later | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ksdns: `tunnel broken`, `25 s later` (gap #41 fixed in ddv6) |
| kill switch ON: dvpnd itself dies → no leak | ☐ | — | — | ☐ | — | — | ledger: `kill-on <p>: dvpnd SIGKILLed` (launchd restarts it; same two protocols as #32) |
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
| LaunchDaemon: KeepAlive restarts a crashed dvpnd | ☐ installer: `launchd restarts the service after a crash` |
| socket `root:dvpn 0660` + inherited user ACL | ☐ daemon: `socket root:dvpn 0660 with an ACL` |
| key folder root-only; `device.pub` readable | ☐ daemon: `device key folder is root-only` |
| service PATH = root-owned copies only | ☐ daemon: `service runs root-owned copies only` |
| root steps: `sudo -n` (rig) | ☐ daemon tier settings round trips |
| root steps: osascript admin prompt (GUI) | ☐ one prompt answered through QMP keystrokes (installer, GUI) |
| CLI wallet in the login Keychain; locked Keychain → action | ☐ local: `wallet secret is in the Keychain`, `Keychain locked says what to do` |
| app wallet: safeStorage (Keychain) | ☐ ui-smoke with a created wallet |
| drivers: Homebrew as the user + AmneziaWG from pinned source | ☐ daemon: `daemon repair-drivers`, `daemon drivers` all ready |
| login item (LaunchAgent) on/off | ☐ ui-smoke Settings toggle + `launchctl print gui/<uid>/…` |
| Terminal `.command` for the CLI screen | ☐ ui-smoke "Open in Terminal" |
| `.dmg` ad-hoc signature verifies | ☐ installer: `dmg: verifies and holds a signed app` |

## Every CLI command

Filled from `cli-sweep.sh cover` (0 MISSING = done); evidence `docs/evidence/mac/sweep/cover.txt`.
