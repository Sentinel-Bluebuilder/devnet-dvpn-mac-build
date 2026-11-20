# Linux parity — Devnet dVPN (#32) vs the Windows app (#31)

Every CLI command, feature, screen and protocol, with the Windows proof next to the Linux proof.
Linux evidence lives in `docs/evidence/linux/` (raw logs; a row's evidence names the file).
Rig: GCP VM `ddv-linux-1` (Ubuntu 24.04, kernel 6.8.0-1071-gcp, e2-standard-2) running the
**installed .deb**, against #31's six nodes on `ddv-node-1` (35.232.17.117) and #31's plan
provider. Same dvpnd build as Windows (`dfe36c7-dirty`). Date: 2026-10-21.

**Status:** ✅ proven live on Linux · 🧪 unit-tested only · ◐ partly · ⏸ blocked (reason given)

## Headline

| | Windows (#31) | Linux (#32) |
|---|---|---|
| CLI commands (catalogue, 67) | e2e + VM sweep | ✅ **every command passed live** (`cover`: 0 missing) |
| Unit tests | Windows suite | ✅ **299/299** on the VM |
| Protocols, per GB: connect → egress = node → disconnect → direct IP back | WG / AWG / OVPN / V2Ray / Xray ✅, **Hysteria2 ✗** (gap #28) | ✅ **all six** (run 1, before the redeploy) |
| Kill switch ON | WG / AWG / OVPN **broken** (gap #29) | ✅ **all six**: no leak when the path to the server is lost, clean restore (cf4c372) · ✗ a killed OpenVPN/Hysteria2 process lifts the block (dvpnd, gap #41) |
| UI, every screen, dark + light | ✅ | ✅ 0 renderer errors, screenshots |
| Installer | 25/25 + 9/9 | ✅ **22/22** on cf4c372 (upgrade incl. key migration + polkit start rule + restart backoff, remove, reinstall keeps the device, AppImage; `linux-cf4c372/sweep/installer.*`) |

Linux is ahead of Windows on Hysteria2 and on the kill switch for WireGuard and AmneziaWG.

## External event during the run

At **12:37:39 UTC** the maintainer redeployed the devnet program (grants model, no
`add_operator`; see `Desktop/sentinel-solana/docs/34-UPSTREAM-AUDIT.md`). After that, opening a
new pay-as-you-go channel fails on **both** platforms (`dfe36c7` dvpnd → Custom 102). Ticketed
plan sessions, top-ups, settle and withdraw still work. Linux run 1 (`spend-run1.*`, 11:02 UTC)
is before the redeploy; run 2 (`spend.*`, 13:12 UTC) and the kill-switch run (`ksdns.*`) are
after it, which is why they use plan tickets.

## Re-run on the grants program (upstream cf4c372, from 14:15 UTC)

Both apps moved to the redeployed program and dvpnd `cf4c372-ddv1` (owner-approved). Linux
evidence: `docs/evidence/linux-cf4c372/` (installed .deb on `ddv-linux-1`, the six ddv- nodes
on the same build).

| | Linux result |
|---|---|
| Upgrade of an installed v1 service | ✅ package upgrade renamed the old config keys (dvpnd now ignores them), service refused to start without a grant, `device setup` opened the grant (`3MK5Dp…`), service started; doctor clean |
| Unit tests | ✅ 320/320 |
| CLI tiers | ✅ local 63/0 · daemon 33/0 · spend 67/2 (the 2 = plan connect, below) |
| Protocols per GB | ✅ all six: egress = node, nothing left after, direct IP back |
| Switch / per hour / follow | ✅ |
| V2Ray SOCKS + GNOME proxy + Chrome window | ✅ |
| Leftover check positive control | ✅ sees the live OpenVPN / Hysteria2 / Xray process |
| Deposit top-up / settle (18 tx) / withdraw / node test | ✅ |
| UI, every screen, dark + light | ✅ 0 renderer errors (`ui/`) |
| Kill switch ON, all six protocols (per GB) | ✅ **72 checks pass**: connect, egress = node, `inet dvpnd` up, names resolve, VPN DNS 1.1.1.1 on the WG/AWG/Hy2 links via resolvectl, V2Ray/Xray direct request blocked; **path to the server lost → no leak on all six**; clean restore, direct IP back (`sweep/ksdns.*`). ✗ 4: killing the OpenVPN / Hysteria2 process lifts the block (dvpnd ends the session as "service stats unavailable" and releases the firewall; UPSTREAM-GAPS #41; V2Ray/Xray hit the same path once 5 stats reads fail) |
| Plan connect | ⏸ provider-side, twice: first `POST /v1/tickets` 500 (provider DB, UPSTREAM-GAPS #39, fixed by #31 15:33); then the plan's six leases carry v1 vouchers and were start-closed at 15:38 (gap #40), new leases open after the 2 h close grace (~17:45 UTC). The app shows the plain "provider couldn't give you access" copy for both |

Found by this run and fixed in both apps (shared code): every cf4c372 node showed DOWN (signed
metadata domain is now sha256 of the tag; UPSTREAM-GAPS #38), plan rosters refused (provider tag
renamed), `daemon doctor` crashed (JSON field case), old deposits listed with no server, renamed
node error codes shown as "Something went wrong", node speeds 0 (field rename).

## CLI — every command

All 67 (`devnet-dvpn help`) passed at least once on Linux: `sweep/cover.tsv` + the tier files.

| Group | Commands | Linux evidence |
|---|---|---|
| Overview | version, status, logs | `local.tsv`, `daemon.tsv` |
| Wallet | show, receive, create (libsecret keyring), import (key file + junk refused), send (refusals + live funding), logout | `local.tsv`; keyring entry checked, nothing secret on disk |
| Device | show, plan, setup (live tx `5bbWkP…`), register (reads `device.pub`), revoke (`--yes` gate; live at teardown) | `daemon.tsv` |
| Service | version, doctor (no FAIL), drivers, repair-drivers (AmneziaWG via PPA), init, install, settings, set (allow-lan, DNS, DNS mode, kill switch round trips; `netsh` refused), restore-network | `daemon.tsv`, `ksdns.tsv` |
| Servers | nodes list (all filters), show, fav, recent, cost (GB + hour) | `local.tsv`, `spend.tsv` |
| Connect | connect (per GB ×6, per hour, `--switch`, `--plan`, `--follow`), disconnect, sessions, tickets, proxy status / on / off / browser | `spend-run1.tsv`, `spend.tsv` |
| Plans | list, roster, subscribe, subscriptions, close | `spend.tsv`, `ksdns.tsv`, `extra.tsv` |
| Money | channels, channels fund, settle list / run / withdraw, history list / summary / export | `spend.tsv` |
| Testing | test plan / run / stop / history / show --compare / export | `local.tsv`, `spend.tsv`, `test-run.json` |
| Quality | quality ip (= node while connected), quality speed | `local.tsv`, `spend-run1.tsv` |
| Settings | rpc state / set, poll show / set / reset / run / watch, settings get / set | `local.tsv` |

## Features F1–F26 (docs/FEATURE-PLAN.md)

| F | Feature | Windows (#31) | Linux (#32) |
|---|---|---|---|
| F1 | Install and bootstrap | ✅ NSIS, drivers via MSIs | ✅ .deb + first run (init → setup → one admin step); drivers via apt/PPA; installer 22/22 |
| F2 | Owner wallet | ✅ DPAPI (CLI), safeStorage (app) | ✅ libsecret (CLI, live); app safeStorage with `basic_text` refused 🧪; test wallet via `DVPN_KEYFILE` in the UI run |
| F3 | Device key + spending permission | ✅ | ✅ setup tx, `device.pub`, keys root 0700 |
| F4 | Network and RPC | ✅ | ✅ `rpc set/state`, pool + bench; key never echoed (fixed here) |
| F5 | Refresh and polling | ✅ | ✅ `poll *` commands; UI rpc-startup/rpc-end counts |
| F6 | Node discovery | ✅ | ✅ 35 listed, 11 online |
| F7 | Node browser | ✅ | ✅ Servers screen + `nodes show/fav/recent` |
| F8 | Pricing and cost | ✅ | ✅ `cost` GB + hour |
| F9 | Direct connect | ✅ 5 of 6 protocols | ✅ **6 of 6** per GB; per hour; switch; follow |
| F10 | Plans | ✅ (box rig) | ✅ subscribe → roster → connect --plan (egress = node) → close, after the redeploy |
| F11 | Session state machine | ✅ | ✅ status while connected, `--follow` ends on disconnect |
| F12 | Disconnect and settlement | ✅ | ✅ disconnect ×N, settle run, withdraw, channels closing |
| F13 | Sessions, channels, history | ✅ | ✅ sessions, channels, fund, history list/summary/export (CSV) |
| F14 | Kill switch | ◐ WG/AWG/OVPN broken (gap #29) | ✅ all six: path lost → no leak, restore (`linux-cf4c372/sweep/ksdns.*`) · WG/AWG link down → no leak · killed OVPN/Hy2 process → leak (dvpnd gap #41) |
| F15 | DNS | ✅ presets, leak with KS off (gap #30) | ✅ Cloudflare set on `dvpn-wg-client` / `dvpn-awg-client` via resolvectl, names resolve with KS on; `dns-mode` round trip |
| F16 | Split tunnelling (per app) | ✅ WinINET + browser | ✅ V2Ray SOCKS egress = node; GNOME system proxy on → `manual` + 127.0.0.1, off → `none`; Chrome window with `--proxy-server=socks5` · KDE path 🧪 |
| F17 | Protocols and dependencies | ✅ MSIs | ✅ apt/PPA, `daemon drivers` all ready; kernel 7.0 DKMS gap L2 |
| F18 | Settings | ✅ | ✅ app settings + service settings through the root helper (restart each time) |
| F19 | Quality and diagnostics | ✅ | ✅ quality ip/speed; Diagnostics screen; doctor run as user (fixed here) |
| F20 | In-app node testing | ✅ | ✅ `test run` on WG + V2Ray, reports |
| F21 | Desktop integration | ✅ tray, login item | ✅ tray + hide on close + shown again (`ui/*/desktop.json`); XDG autostart on → `~/.config/autostart/devnet-dvpn.desktop` (`--hidden`), off → removed (`sweep/autostart.txt`) |
| F22 | Updates and versions | ✅ | ✅ `version`, `daemon version` (network OK) |
| F23 | Errors and copy | ✅ | ✅ every refusal in the local tier is plain copy with an action; Linux wording on all screens |
| F24 | Security | ✅ | ✅ root only via `dvpn-helper` whitelist; keys root-only; phrase/key redaction in logs; AppArmor profile scoped to our binary |
| F25 | Language, accessibility, theme | ✅ | ✅ dark + light screenshots, 0 errors |
| F26 | Testing and release | ✅ | ✅ `release:linux`, unit 299/299, sweep tiers, installer test |

## Screens (UI smoke, installed app, Xvfb, `docs/evidence/linux/ui/{dark,light}`)

Welcome, Connect, Servers, Plans, Activity, Node test, Wallet, Settings, Diagnostics, CLI (+ a
command run in the in-app terminal): all render in both themes, `errors.json` = `[]`.

## Open items (honest list)

| Item | Why | Next |
|---|---|---|
| ~~Kill switch ON for OpenVPN, Hysteria2, V2Ray, Xray~~ | ✅ run per GB on cf4c372 (all six, path-lost case) | — |
| Killed protocol process lifts the kill switch | dvpnd releases the firewall when it ends a session as "service stats unavailable" (gap #41); the app cannot hold an nft rule of its own without fighting dvpnd | upstream fix |
| Plan connect on cf4c372 | provider leases (gap #40) | re-run `PLAN_ADDR=6zKPsC… cli-sweep.sh ksdns` after #31's new leases |
| ~~New pay-as-you-go sessions~~ | ✅ fixed by the cf4c372 migration (all six protocols per GB, above) | — |
| ~~pkexec prompt on a desktop~~ | ✅ proven: a desktop user without sudo (`ddvdesk`, own login session, GNOME polkit agent on the display) ran `daemon set`: the prompt shows the app's message + icon (`linux-cf4c372/pkexec/pk-dialog.png`), the admin password → "Applied and restarted."; Escape → "The administrator permission prompt was declined or closed." (exit 1, config unchanged) | — |
| ~~KDE system proxy~~ | ✅ live with KDE's own config tools (`kreadconfig5`/`kwriteconfig5`, `XDG_CURRENT_DESKTOP=KDE`) during a V2Ray session: the user's own HTTP proxy seeded first; `proxy on` → `kioslaverc` socksProxy `socks://127.0.0.1 1080`, SOCKS egress = node; `proxy off` → the user's values back byte for byte (`linux-cf4c372/kde/`). Not run inside a full Plasma desktop (KDE apps reading kioslaverc is KDE's part) | — |
| ~~Migration to the grants program~~ | ✅ done (section above) | plan connect waits on the provider fix |
| AppImage on Ubuntu 24.04 | needs `libfuse2t64` and `--no-sandbox` (all Electron AppImages) | documented; .deb is primary |
| ~~Leftover-process positive control~~ | ✅ cf4c372 spend run (OpenVPN, Hysteria2, Xray) | — |
