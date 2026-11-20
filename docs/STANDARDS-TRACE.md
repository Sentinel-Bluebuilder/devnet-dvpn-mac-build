# Standards trace — Devnet dVPN

Every checklist item from our standards, mapped to the feature that satisfies it
([`FEATURE-PLAN.md`](FEATURE-PLAN.md)). Release (P8) requires every row ✅.

- ✅ proven live: box rig ([`BOX-RIG.md`](BOX-RIG.md)), devnet test, or UI smoke screenshot
- ◐ built and unit-tested, not yet seen live (the live case can't be staged safely on this laptop)
- ☐ not done — the note says what is missing

## Solana protocol — `sentinel-solana/docs/25-BUILDING-AN-APP.md` §10

| item | feature | done | evidence |
|---|---|---|---|
| `StopSession` on every exit path and signal; surface its errors and `dns_revert_failed` | F12.5, F12.6, F15.3 | ✅ | box: `disconnect`, `--switch`, `--follow` + Ctrl-C, UI Disconnect; app `before-quit` stops first (10 s cap); `dns-revert-failed` copy in `connection.ts` |
| visible "reconnecting — traffic blocked" state with a Stop button | F11.4 | ◐ | `state.ts` `reconnecting` → `canStop`; Home shows Stop |
| daemon stopped gracefully by the service manager, never killed | F1.3, F18, F1.7 | ✅ | laptop 2026-10-20: `daemon install` → service Running/Automatic, restarted by `Restart-Service` on PATH change, sessions resumed cleanly; clean VM (T1): installer upgrade stops the service before replacing files and starts it after, uninstall stops then removes it (`build/installer.nsh`) |
| startup check for leftover kill switch with no active session | F14.3, F14.4 | ◐ | `checkLeftoverBlock()` after every daemon attach (`reachability.test.ts`); the blocked state itself reproduced on the box (daemon killed, tunnel gone → egress 000 → service restart → 200); the app-side banner needs the Windows VM |
| nodes probed before charging | F6.3–F6.5, F9.1 | ✅ | box: connect preflight probes; dead node refused before any deposit |
| REALITY transports avoided | F6.6 | ◐ | `hasRealityTransport()` reads `inbounds[].security` (fixed 2026-10-20; it read `service.type` before); `reality.test.ts` with the box xray metadata shape |
| escrow ≥ prepay; returned balance shown and withdrawable | F8.3, F12.4, F2.7 | ✅ | box: `settle run` closed + withdrew; Wallet "Refundable"; `settle list` shows refundable per channel |
| usage UI tolerates the 60 s refresh | F5.2 | ✅ | box: `connect --follow` updated on the 60 s meter tick; UI "Approximate · every minute" |
| errors keyed on numbers, not names | F23.3 | ✅ | devnet: `GraceNotElapsed` matched by number (`p0-builders`); `ProviderNotListed (6020)` seen on the box |
| per-protocol binaries bundled under the exact names | F1.1, F1.8, F17.3 | ✅ | `resources/bin/{v2ray,xray,hysteria2}` (official releases, sha256 checked, gitignored) on the service PATH; WireGuard 1.1.1, AmneziaWG 3.1.0 and **OpenVPN 2.6.x** (not 2.7, UPSTREAM-GAPS #21) installed system-wide; all six proven live on Windows 2026-10-20. **Bundled in the installer**, pinned in `build/deps.lock.json`, hash + signer checked at build and install (`docs/INSTALLER.md`); proven on a clean VM (T1) |

## Solana UX — `sentinel-solana/docs/29-UI-UX-GUIDE.md` §9

| item | feature | done | evidence |
|---|---|---|---|
| onboarding runs `dvpnd doctor` and turns the `grant` check (`mandate` before the grants program) into a grant step | F1.6, F3.2, F3.3 | ✅ | box: preflight failed on the grant → `device setup` granted it in one tx; onboarding step 3 "Spending permission" |
| servers probed before shown as available | F6.7 | ✅ | smoke `02-servers`: "Online only", latency per row, "checking X/Y" while probing |
| "Reconnecting — internet blocked" with an always-visible Stop | F11.4 | ◐ | as above |
| "Restore network" on start when a stale kill switch exists | F14.4 | ◐ | banner + button; daemon-dead case says to restart the service (elevated release = UPSTREAM-GAPS #5) |
| every close reason and node error code has copy | F11.3, F23.2 | ✅ | `core-pure.test.ts` close-reason table; box: `peer_limit_reached`, `ticket_invalid`, `plan-limit` copy |
| retries with backoff around RPC calls and ticketed connects | F4.1, F10.5 | ✅ | RPC pool benching; ticket retries; box ticketed connects |
| refundable balance + Withdraw; subscription "no refunds" disclosure | F12.4, F10.4 | ✅ | box: `plans close` says "the price is not refunded"; withdraw landed |
| usage labelled approximate, refreshed every minute | F5.2, F8.5 | ✅ | UI hint + box `--follow` |

## Known protocol weaknesses we must design around — doc 18 §6

| weakness | how the app handles it | feature |
|---|---|---|
| REALITY carries no traffic | hidden | F6.6 |
| kill switch leaks on daemon death | detect + restore | F14.3, F14.4 |
| data cap 0 = unlimited | shown as "Unlimited" | F10.1 |
| cutoff is late | usage labelled approximate | F8.5 |
| `ticket_invalid` hides the cause | retry ≥3, generic copy | F10.5 |
| peer slots leak | `peer_limit_reached` copy suggests another node | F23.2 |
| one 429 fails a call | pool failover, dedicated-RPC prompt | F4.1, F4.4 |
| removed grant strands channels | revoke blocked while channels open | F3.5 |
| billing counts wire bytes | disclosed next to price | F8.5 |

## One-shot app checklist — `Sentinel SDK/suggestions/2026-03-23-app-oneshot-standards.md`

| item | feature | done | evidence |
|---|---|---|---|
| welcome / auth screen first on every launch | F2.1 | ✅ | smoke `00-welcome` (welcome-back card, then Continue) |
| split layout: brand left, auth right | F2.1 | ✅ | smoke `00-welcome`, `00-onboarding` |
| import + create wallet | F2.2, F2.3 | ✅ | cli-e2e local: `wallet create`, `wallet import`; app key-file import dialog |
| test wallet button for development | F2.11 | ✅ | onboarding "Import a key file (devnet test wallet)…" |
| loading indicator while nodes probe, "Probed X/Y" | F5.5, F7.7 | ✅ | Servers subtitle "checking X/Y" |
| flags render as images | F6.9 | ✅ | bundled SVG flags, smoke `02-servers` |
| countries collapsed with chevron + flag + count | F7.1 | ✅ | smoke `02-servers` ("India 6/6 online") |
| node rows: name, city, protocol, pricing; both prices visible | F7.5 | ✅ | smoke `02-servers` (per GB + per hour on every row) |
| filters (protocol, basis) | F7.3 | ✅ | protocol + "Any / Pay per GB / Pay per hour" selects |
| search across country, city, name | F7.2 | ✅ | search box; country names incl. variants (`country.test.ts`) |
| connection control with off / connecting / on | F11.1 | ✅ | UI connect smoke `09`–`11` on the box |
| stats row: IP, uptime, protocol, session | F9.5 | ✅ | Home chips IP / Protocol / DNS / country (`10-connected`) |
| DNS badge showing resolver | F15.1 | ✅ | Home DNS chip from daemon settings |
| log panel with copy | F19.4 | ✅ | Diagnostics "Copy log" |
| persistence in the user's app-data dir | ARCHITECTURE "Data at rest" | ✅ | `%APPDATA%\Devnet dVPN` (`DVPN_DATA_DIR` for tests) |
| theme tokens, no hard-coded colours | F25.4 | ✅ | smoke dark + light, all 8 screens |
| clean build, 0 warnings | F26 | ✅ | `npm run build` + both `tsc` projects clean; smoke 0 console errors (2026-10-20) |

## SDK consumer standards (Cosmos-era, UX only)

| standard | feature |
|---|---|
| CONNECTION-STATE-MACHINE states + concurrent actions | F11.1, F11.5 |
| auto-reconnect backoff | F11.4 (daemon owns it, D6) |
| polling intervals (status, balance, IP, nodes) | F5 |
| ERROR-MESSAGES severity classes | F23.1 |
| SETTINGS-SCREEN keys, nulls = defaults | F18 |
| PRICING: never compare GB vs hour; show cost before paying; disable when unaffordable | F8.1, F8.3, F8.6 |
| DISCONNECT soft vs hard | F12.1, F12.2 |
| SESSION-LIFECYCLE reuse | F9.2 |
| SUBSCRIPTION-MANAGEMENT / CONNECT-VIA-PLAN | F10 |
| DNS presets (Handshake default) | F15.1 |
| COUNTRY-FLAGS variants map | F6.8 |
| SPLIT-TUNNEL-TESTING proofs | F16.6, TEST-PLAN T16 |
| CONSUMER-VS-TESTING separation | F20 |
| ux-patterns: always show status, one-click connect, seamless switch, cleanup handlers first, never raw errors | F9.5, F7.9, F11.6, F12.6, F23.6 |
| windows-app-standards: topbar + sidebar + main panel layout, stats row, log strip, favourites, caching TTLs | F7, F9.5, F19.4, F7.6, F5 |

## Handshake dVPN standards — `Desktop/handshake-dvpn/`

| standard | feature |
|---|---|
| Handshake DNS default | F15.1 |
| single probe per app session, disk cache, refresh on demand | F5.4, F5.5 |
| never re-render while the user interacts | F7.8 |
| pre-connect validation (status, binaries, balance) | F9.1 |
| speed test fallback chain + baseline | F19.2 |
| dedicated test instance per node test | F20.1 |
| progress counter on every path | F20.7 |
| FAST / SLOW / FAIL | F20.5 |
| test run history + compare | F20.6 |

**The six-question standard** (RETROSPECTIVE) — every feature must answer yes to: works on first
use · works on return visit · works after restart · works after failure (crash, network, cancel) ·
the user can share the output · the user can investigate issues. Applied per feature in TEST-PLAN.

## Learn-from-mistakes — eight review questions (`suggestions/2026-03-23-learn-from-mistakes.md`)

Asked in every review, before every merge:

1. Does it work on the second attempt? → TEST-PLAN T-second-attempt suite
2. Does it use real chain data formats? → real devnet fixtures only
3. Does it survive a JSON round-trip? → F13.6
4. Does it have silent side effects? → no auto fee payer, no auto-spend, no auto-resume
5. Does it pay before verifying success is possible? → F9.1
6. Does it parse all available fields? → decoders cover every IDL field
7. Does it work at production scale? → discovery tested against the full devnet registry
8. Does the test check the output, not the input? → tests assert tx bytes / chain state

## Master verticals

| vertical | rules applied |
|---|---|
| V5.1 Electron architecture | secrets in main (F2.5), IPC constants (F24.2), polling at root (D9), teardown on quit (F12.6) |
| V5.2 VPN / tunnel clients | IPC tiers (ARCHITECTURE), code + message on every failure (F23.6), "no session" is a state not an error (F11.1) |
| V5.3 native interop | elevate once (F1), never config inside an elevated shell string (D4), pipe ACL (D5), resolve binaries by priority (F1.8), teardown restores connectivity first (F12.6) |
| V7.1 secrets | phrase not retained (F24.3), https-only RPC (F4.2), redacting logger (F19.4) |
