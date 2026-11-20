# Feature plan — Devnet dVPN

Every feature the app will have, end to end, mapped from our standards and our own code. No app
code exists yet; this is the build spec. Written 2026-10-20.

Each feature row says: **what it does**, **how** (daemon / chain / node mechanism), **source**
(the standard it comes from), **reuse** (our code it is ported from, if any) and **phase**.
Tests per ID live in [`TEST-PLAN.md`](TEST-PLAN.md); standard-by-standard coverage in
[`STANDARDS-TRACE.md`](STANDARDS-TRACE.md); daemon changes we need in
[`UPSTREAM-GAPS.md`](UPSTREAM-GAPS.md).

## Source keys

| key | document |
|---|---|
| S04 S14 S17 S18 S19 S21 S25 S29 S30 | `Desktop/sentinel-solana/docs/NN-*.md` |
| SRC | dvpnd / sentinel-go-sdk source in `Desktop/sentinel-solana/upstream/` (file named in the row) |
| CSM | `Sentinel SDK/docs/CONNECTION-STATE-MACHINE.md` |
| SET | `Sentinel SDK/docs/SETTINGS-SCREEN.md` |
| ERR | `Sentinel SDK/docs/ERROR-MESSAGES.md` |
| FLOW | `Sentinel SDK/docs/APP-FLOWS.md` |
| CVT | `Sentinel SDK/docs/CONSUMER-VS-TESTING.md` + `IN-APP-NODE-TESTING.md` |
| FEAT | `Sentinel SDK/docs/features/*.md` (CONNECT-DIRECT, DISCONNECT, SESSION-LIFECYCLE, SUBSCRIPTION-MANAGEMENT, PRICING, DNS, CONNECT-VIA-PLAN, EDGE-CASES, COUNTRY-FLAGS, SPLIT-TUNNEL-TESTING) |
| GOT | `Sentinel SDK/docs/PLATFORM-GOTCHAS.md` |
| UXP | `Sentinel SDK/docs/guides/ux-patterns.md` |
| SUG | `Sentinel SDK/suggestions/` (complete-ux, app-oneshot, app-build, learn-from-mistakes, pain-points, windows-app-standards, split-tunnel-complete-analysis) |
| HNS | `Desktop/handshake-dvpn/{STANDARDS,RECOMMENDATIONS,RETROSPECTIVE,MANIFESTO}.md` |
| M5.1 M5.2 M5.3 M7.1 | `Desktop/master/verticals/V5.1/V5.2/V5.3/V7.1-*.md` |

## Reuse keys (our code only)

| key | path |
|---|---|
| PM | `Desktop/plans-solana/lib/` (Plan Manager, Solana) |
| NT | `Desktop/sentinel-node-tester-solana/lib/` (Node Tester, Solana) |
| NM | `Desktop/sentinel-node-manager-solana/src/main/services/` (Node Manager, Solana, Electron) |
| SDK | `Desktop/Sentinel SDK/js-sdk/` (our JS SDK, `blue-js-sdk`) — chain-agnostic helpers only |

Phases: **P0** risk spikes · **P1** foundation · **P2** onboarding · **P3** direct connect ·
**P4** plans · **P5** network safety · **P6** quality + desktop · **P7** node test tab ·
**P8** release.

---

## Architecture decisions that shape every feature

| # | Decision | Evidence |
|---|---|---|
| D1 | Sessions only through `dvpnd` gRPC `ClientService`. The app never builds tunnels, firewall rules, DNS changes or vouchers. | S25 §1 |
| D2 | Owner-signed chain writes are built in TS from the patched devnet IDL (`PM solana/program.js` pattern). No bundled `dvpnctl` for writes. | PM already lands `open_subscription`, `close_subscription`, `withdraw_user_balance` on devnet; dvpnctl would need the owner key as a file. New builders: `add_operator`, `update_operator`, `remove_operator`, `start_close_channel`, `close_channel`, `fund_channels` (proven in P0). |
| D3 | The app settles channels itself. | dvpnd finishes only closes it started (`internal/client/connect.go:501`, `channel.go:114`); no close/withdraw gRPC exists. |
| D4 | Daemon settings change by an elevated file write + service restart. | kill switch, DNS, `allow_lan`, escrow/prepay defaults live in `C:\ProgramData\dvpnd\client\config.toml` + `client\config.toml` (`internal/config/client.go`), not in gRPC. |
| D5 | The unelevated app reaches the SYSTEM pipe via `[daemon] socket_group = "Users"`. | `internal/daemon/daemon_windows.go:109-124`; M5.3 #5 |
| D6 | The app does not duplicate daemon reconnect. | daemon: 5 attempts, 2 s doubling backoff, then releases a non-persist kill switch (`internal/client/issuer.go:20-127`) |
| D7 | Split tunnelling = per-app over the V2Ray/Xray SOCKS proxy, kill switch off. WireGuard split is not possible today. | kill switch admits only `lo`, node, chain (`firewall_linux.go`); WG `AllowedIPs` hard-coded full tunnel (`go-sdk internal/wireguard/client.go:226`); SOCKS inbound is no-auth (`go-sdk v2ray/templates/client.json.tmpl`) |
| D8 | Country flags are bundled SVGs; no flag CDN. | Chromium on Windows has no emoji flags; a CDN request leaks app use |
| D9 | All polling is owned by one root scheduler in main, never by components. | M5.1 #8 |
| D10 | Owner signing has two modes: in-app key (default) and browser wallet (cold). | owner decision 2026-10-20; cold mode reuses PM `tx.js` `broadcastOrRelay` / `relaySignedTx` / `assertRelayable` |
| D11 | v1 targets Windows. macOS/Linux after v1; Linux (WSL netns) is the test rig. | owner decision 2026-10-20; S30 |

### Who signs what

| action | signer | path |
|---|---|---|
| open channel, sign vouchers, open session, request ticket | **device key** (inside dvpnd) | `StartSession` |
| approve delegate, add/update/remove operator | **owner** | app TS builder → owner signer |
| open / close subscription | **owner** | app TS builder (PM) |
| start_close / close channel, fund channel | **owner** (owner may close its channels) | app TS builder (new, P0) |
| withdraw user balance | **owner** | app TS builder (PM) |
| send SOL to device, send tDVPN | **owner** | `NM wallet.ts transferInstructions` |

---

## F1 — Install and bootstrap

The installer is the only elevated moment in normal use (M5.3 #4).

| ID | Feature | How | Source | Reuse | Phase |
|---|---|---|---|---|---|
| F1.1 | NSIS installer, per-machine | electron-builder NSIS; installs app + `dvpnd.exe` + per-protocol binaries we are allowed to ship | M5.3 #11 | NM `electron-builder.yml` | P2 |
| F1.2 | WireGuard for Windows check | detect `wireguard.exe`; if missing, explain and link the official installer (dvpnd shells out to `wireguard.exe /installtunnelservice`) | S30, SUG pain-points #2 | — | P2 |
| F1.3 | Daemon home + service | `dvpnd service install --home C:\ProgramData\dvpnd\client` (LocalSystem, depends on BFE + Nsi, restarts 3×), `sc start dvpnd` | S30 | — | P2 |
| F1.4 | Pipe access for the user app | write `[daemon] socket_group = "Users"` before first start | D5 | — | P2 |
| F1.5 | Deferred client init | the owner address is not known at install; first-run elevated step runs `dvpnd init --role client --owner <owner> --plain-key` once the wallet exists | S30 | — | P2 |
| F1.6 | First-run doctor | run `dvpnd doctor`; render each check (pipe, rpc, grant, binaries) with a fix button | S25, S30 | — | P2 |
| F1.7 | Clean uninstall | stop session, release kill switch, `dvpnd service uninstall`, keep wallet unless asked | M5.1 #9, M5.3 #12 | — | P8 |
| F1.8 | Binary resolution | resolve every bundled binary by explicit priority, verify it runs (`--version`) before use | M5.3 #10, "binary present but cannot run" | — | P2 |

**Risks:** pipe from grpc-js unproven (P0); Windows tunnel never run upstream (P0 in a VM).

## F2 — Owner wallet

| ID | Feature | How | Source | Reuse | Phase |
|---|---|---|---|---|---|
| F2.1 | Welcome screen first, every launch | split layout: brand left, auth card right; never auto-skip | SUG app-oneshot §1 | — | P2 |
| F2.2 | Create wallet | 24-word BIP-39, `m/44'/501'/0'/0'` (Phantom-compatible); show once with backup confirmation | M7.1 #1-2 | NM `keys.ts newMnemonic`, `wallet.ts createWallet` | P2 |
| F2.3 | Import | phrase, solana-keygen JSON (64/32 bytes), base58 secret | — | PM `session.js keypairFromInput`; NM `importKeyFile` | P2 |
| F2.4 | Storage at rest | Electron `safeStorage`; refuse to save without OS encryption | M7.1 #5 | NM `wallet.ts requireEncryption/saveSecret` | P2 |
| F2.5 | Secrets never cross IPC | only main signs; renderer gets address + balances | M5.1 #1 | NM pattern | P1 |
| F2.6 | Browser-wallet (cold) mode | main serves a loopback page with the unsigned tx, opens the system browser, Phantom/Solflare signs, page posts it back; main validates fee payer + program allowlist, sends | D10 | PM `tx.js` relay path | P2 |
| F2.7 | Balances | SOL, tDVPN (Token-2022 ATA), `User.balance` (refunds waiting), device SOL | S29 §1 | NM `fetchBalances`; PM `accounts.js userByOwner` | P2 |
| F2.8 | Receive | address copy with feedback + QR | UXP | — | P2 |
| F2.9 | Send | tDVPN / SOL with recipient ATA created idempotently | S21 (`bank MsgSend` has no dvpnctl equivalent) | NM `transferInstructions`, `sendFrom` | P6 |
| F2.10 | Logout | wipe secret, stop session first, keep settings | — | NM `logoutWallet` | P2 |
| F2.11 | Devnet test wallet | "Import test key file" shortcut, devnet builds only | SUG app-oneshot §1 | — | P2 |

## F3 — Device key and spending grant

The device key lives inside dvpnd and spends from the owner's account only under an on-chain
grant with an allowance (S29 §1, proven by `scripts/e2e-mandate.sh`).

| ID | Feature | How | Source | Reuse | Phase |
|---|---|---|---|---|---|
| F3.1 | Show the device address | captured from `dvpnd init` stdout (it prints the device pubkey, S04) during F1.5 and stored in the app; re-checked against doctor's grant check. `GetVersion` does not return it | S04, S29 §1 | — | P2 |
| F3.2 | Setup wizard (3 steps, one tx each, 7 s apart in tests) | (1) Token-2022 `ApproveChecked` on owner ATA, delegate = Config PDA; (2) `add_operator(device, role 2, allowance)` — grant PDA (the pre-grants program used `["operator_mandate", owner, device, [2]]`); (3) send the device ~0.05 SOL for fees | S04, S29 §1 | PM `program.js` PDAs; new builder | P2 |
| F3.3 | Grant status | grant PDA read (allowance left) + doctor `grant` check; banner when allowance < default escrow | S25 | PM `accounts.js` | P2 |
| F3.4 | Change allowance | `update_operator(allowance)` | S19 lifecycles | new builder | P2 |
| F3.5 | Revoke device | `remove_operator`, **blocked while the device has open or closing channels** (devnet strands escrow otherwise) | S18 §6.8, S14 divergence 5 | new builder | P2 |
| F3.6 | Top up device SOL | one-click send when device SOL < threshold | S29 | NM `sendFrom` | P2 |

## F4 — Network and RPC

| ID | Feature | How | Source | Reuse | Phase |
|---|---|---|---|---|---|
| F4.1 | RPC pool with failover | bench a failing endpoint 60 s (8 s on 429), rotate, never the same host twice while another is untried | S18 §6.7, S19 | PM `solana/rpc.js` | P1 |
| F4.2 | User endpoints | add / reorder / remove; https only, http only for loopback; no whitespace or quotes (written into TOML) | M7.1 #6 | NM `settings.ts isValidRpcUrl` | P1 |
| F4.3 | Health indicator | serving endpoint (redacted), slot, latency, benched list | — | PM `getRpcState`, `redactUrl` | P1 |
| F4.4 | Dedicated-RPC warning | public devnet RPC 429s under real use; prompt for a dedicated endpoint | S19, S29 §6 | — | P1 |
| F4.5 | Network identity check | `DaemonService.GetVersion` `{network, program_id, mint}` must equal the app's constants; mismatch blocks Connect with a clear message | S25 | PM `daemon.js` | P1 |
| F4.6 | Daemon RPC follows app | when the user changes RPC, write it to daemon `[rpc]` (D4); daemon has one URL, no failover | SRC `config.go`; UPSTREAM-GAPS #4 | — | P5 |
| F4.7 | Commitment + timeouts | `confirmed` reads, 12 s read timeout, every call wrapped | — | PM `rpcCall`, NM `withRpcTimeout` | P1 |
| F4.8 | Never call `program.account.X.all()` | `getProgramAccounts` with `dataSize` (deployed sizes) + discriminator + memcmp | S14 | PM `accounts.js fetchMany`, `idl.js DEPLOYED_SIZES/OFFSETS` | P1 |

## F5 — Data refresh and polling

One scheduler in main owns every timer (D9). Each source has one owner; a page never starts
its own poll. Settings can stretch intervals within clamps (NM `settings.ts clampInt`).

| ID | Data | Source | Cadence | Notes | Phase |
|---|---|---|---|---|---|
| F5.1 | Live session | `WatchSession` stream; `GetSession` if the stream drops | push; 5 s fallback | reconnect the stream with backoff | P3 |
| F5.2 | Usage / spent | daemon issuer tick | 60 s | label "updates every minute" (S29) | P3 |
| F5.3 | Owner balances, `User.balance`, grant | websocket `onAccountChange` on owner ATA, user PDA, grant PDA | live; 60 s poll fallback | ws dies under 429 → poll | P2 |
| F5.4 | Node list | getProgramAccounts (node size + discriminator) → disk cache (SDK `disk-cache.js`) | 5 min, stale-while-revalidate; manual Refresh | render once from cache, never mid-interaction (HNS) | P3 |
| F5.5 | Node probes | `GET <uri>/v1/metadata` | on list load, 30 parallel, 6 s timeout; 60 s cache | progress "Probed X/Y" | P3 |
| F5.6 | Plans + providers | accounts + provider metadata | 10 min | | P4 |
| F5.7 | Subscriptions, channels, tickets | chain + `ListChannels` / `ListTickets` | on login and after every tx | | P3 |
| F5.8 | Program config | `fetchConfig` cache | 10 min | fee bps, grace, TTL, prepay bounds | P1 |
| F5.9 | Public IP | 3 services, first answer wins | 30 s while connected; once when idle | disclosed third-party call | P6 |
| F5.10 | Pending settlements | channel accounts in the queue | 60 s while any pending | fires "ready to close" | P3 |
| F5.11 | Daemon health | `GetVersion` | 30 s; immediate on pipe error | drives the "daemon down" banner | P1 |
| F5.12 | Throttling | pause F5.4/5.6/5.9 when minimised; keep F5.1-5.3 | — | bandwidth budget (SUG complete-ux table) | P6 |

## F6 — Node discovery and verification

| ID | Feature | How | Source | Reuse | Phase |
|---|---|---|---|---|---|
| F6.1 | Read every listed node | node accounts decoded with the devnet IDL: owner, status, prices (per GB, per hour), protocols bitmask, country, uri, listed_at | S04, S14 | NT `discovery.js discoverNodes`; PM `accounts.js allNodes` | P3 |
| F6.2 | Listed vs fresh | `listed_at + TTL(86400)`; listed ≠ online | S19, S17 timers | NT `listingFresh` | P3 |
| F6.3 | Signed metadata check | ed25519 over `domain32 ‖ sha256(raw payload)`, signer == node owner, claims (node, owner, program_id), not expired | S18 §1 (`node-metadata/v1`) | NT `probeNode` | P3 |
| F6.4 | TLS pin | record `payload.api.tls_sha256`, check on every later node call | S18 §4 | PM `nodeapi.js httpsRequest` pin check | P3 |
| F6.5 | Live facts | peers / max peers, bandwidth, location, service types, version | — | NT `probeNode` | P3 |
| F6.6 | Hide dead transports | drop REALITY (carries 0 bytes) | S18 §6.1, S19 | — | P3 |
| F6.7 | Online-only list | show only probed-OK nodes; "Unknown" country group for nodes with no location | SUG complete-ux, HNS | — | P3 |
| F6.8 | Country normalisation | name/code → ISO with variants ("The Netherlands", "Türkiye", "Czechia", "Viet Nam", "DR Congo"…) | FEAT COUNTRY-FLAGS, SUG app-oneshot §2 | SDK `app-helpers.js COUNTRY_MAP`, `countryNameToCode`, `countryToContinent` | P3 |
| F6.9 | Bundled flags | SVG per ISO code shipped in the app, 24×16 | D8 | — | P3 |

## F7 — Node browser

| ID | Feature | How | Source | Phase |
|---|---|---|---|---|
| F7.1 | Country groups | collapsed by default, chevron + flag + online/total | SUG app-build §4 | P3 |
| F7.2 | Search | country, city, name, address, across collapsed groups | SUG | P3 |
| F7.3 | Filters | protocol (WG, AWG, V2Ray, Xray, OpenVPN, Hysteria2), basis (per GB / per hour), favourites, recent | SUG one-shot checklist, FEAT PRICING | P3 |
| F7.4 | Sort | price, peers, bandwidth, country | HNS | P3 |
| F7.5 | Node card | flag, name, location, protocol badges, peers, both prices, version, listed age, existing open channel with escrow left | SUG complete-ux "Node Info Card" | P3 |
| F7.6 | Favourites + recent | persisted in app store | SUG windows-app-standards | P3 |
| F7.7 | Loading states | skeleton before every await; "No nodes" only after a finished query returned zero | SUG app-build §3 | P3 |
| F7.8 | Stable list | background refresh updates data but does not re-render while the user interacts; fixed heights | HNS "never re-render" | P3 |
| F7.9 | Quick connect | best node by preference (country, protocol, price basis, peers, probe latency); skips nodes whose circuit is open after repeated failures (SDK `resilience.js` circuit breaker) | SUG windows-app-standards, FLOW | P3 |

## F8 — Pricing and cost

| ID | Feature | How | Source | Phase |
|---|---|---|---|---|
| F8.1 | Basis choice | per GB (voucher channel) or per hour (stream channel) per node; never compare GB with hour | FEAT PRICING, SUG pain-points #3 | P3 |
| F8.2 | Amount presets | GB 1, 2, 5, 10, 25, 50; hours 1, 2, 4, 8, 12, 24 | SET | P3 |
| F8.3 | Cost preview | escrow = amount × price, shown before paying; prepay (default 1 GB, bounds from config) explained | S25, S29 §7 | P3 |
| F8.4 | Formatting | base units → tDVPN with trailing zeros trimmed; never raw base units | SUG complete-ux | P1 |
| F8.5 | Honest disclosures | 2 % protocol fee; billing counts wire bytes (+8 % bulk, more on tiny packets); `spent` includes prepay | S18 §6a, S17 | P3 |
| F8.6 | Affordability gate | Connect disabled with the reason when owner tDVPN, grant allowance or device SOL can't cover it | S29, FEAT CONNECT-DIRECT | P3 |
| F8.7 | Top up open channel | `fund_channels` to add escrow without reconnecting | S19, S21 | P3 |

## F9 — Direct connect

| ID | Feature | How | Source | Phase |
|---|---|---|---|---|
| F9.1 | Zero-cost preflight | daemon up, network match (F4.5), grant + balances (F8.6), fresh probe of this node (F6.3-6.4), protocol binary present (doctor), no other session, no other VPN client running, SOCKS port 1080 free for V2Ray/Xray (SDK `preflight.js checkVpnConflicts`, `proxy.js checkPortFree`) | SUG learn-from-mistakes #5/#12, HNS recs §2.3 | P3 |
| F9.2 | Channel reuse | if an open channel to this node exists with escrow left → `Credential.channel`; else `new_channel{mode, escrow}` + `terms{basis, price, prepay}` | S25, SRC `channel.go resolveChannel` | P3 |
| F9.3 | Progress steps | from `WatchSession`: checking node → opening channel → opening session → starting tunnel → protected | CSM, SUG windows-app-standards | P3 |
| F9.4 | Node re-opened | daemon closes the stale channel and opens a new one once (`channel_node_reopened`); app shows it | SRC `connect.go reopenAndRetry` | P3 |
| F9.5 | Connected view | IP, uptime, protocol, node, session id, usage, spent, escrow left with bar | SUG complete-ux "Allocation display" | P3 |

## F10 — Plans and subscriptions

| ID | Feature | How | Source | Reuse | Phase |
|---|---|---|---|---|---|
| F10.1 | Browse every plan | plan accounts: price, duration, data cap (0 = unlimited), max connections, status, provider | S17, S21 | PM `accounts.js allPlans`; NT `plans.js` | P4 |
| F10.2 | Plan nodes | provider API `getPlanNodes` (signed provider metadata) | S21 off-chain | PM `nodeapi.js` | P4 |
| F10.3 | Subscribe | `open_subscription` with expected price/duration/cap/connections; `PlanTermsChanged` → re-show terms | S21 | PM `program.js openSubscription` | P4 |
| F10.4 | No-refund disclosure | before paying: price is paid up front, closing early refunds nothing | S17, S29 checklist | — | P4 |
| F10.5 | Connect via plan | `StartSession` with `ticket{provider, subscription}`; retry `ticket_invalid` ≥3 with backoff (cause is flattened) | S18 §6.5, S29 | — | P4 |
| F10.6 | Limits | `max_connections` → `peer_limit_reached` copy; data cap and expiry countdown | S19 | — | P4 |
| F10.7 | Renew | no renew instruction: "Renew" opens a new subscription after expiry; reminder before expiry | S21 | — | P4 |
| F10.8 | Cancel | `close_subscription` (owner, any time) | S21 | PM `closeSubscription` | P4 |
| F10.9 | My subscriptions | by owner (memcmp offset 8), status, expiry, nodes | PM `subscriptionsByOwner` | P4 |

## F11 — Session state machine

| ID | Feature | How | Source | Phase |
|---|---|---|---|---|
| F11.1 | States | IDLE · CONNECTING (steps) · CONNECTED · RECONNECTING · DISCONNECTING · ERROR | CSM | P3 |
| F11.2 | Mapping | from daemon session status (`open`, `active`, `closing`, `ended`, `closed`) + error + stream events | SRC `models.go`, S17 | P3 |
| F11.3 | Close reasons | 8 reasons with user copy: closed by client, credit exhausted, idle, closed by operator, position closed on chain, close grace elapsed, no enforcer, retrying close | S17, S29 | P3 |
| F11.4 | Daemon reconnect | show "Reconnecting — internet blocked" (kill switch holds traffic) with an always-visible Stop while the daemon retries (5×); after exhaustion → ERROR with Retry | D6, S25 §10, S29 §9 | P3 |
| F11.5 | Concurrent actions | one action at a time; table of allowed actions per state (no connect during disconnect, etc.) | CSM | P3 |
| F11.6 | Server switch | soft stop then connect; old channel kept for reuse or queued for settlement | FEAT SESSION-LIFECYCLE | P3 |
| F11.7 | Crash recovery | on start, `ListSessions` + `GetSession` rebuild state; never auto-resume a session after a crash | S25, SUG | P3 |

## F12 — Disconnect and settlement

| ID | Feature | How | Source | Phase |
|---|---|---|---|---|
| F12.1 | Soft disconnect | `StopSession`, channel stays open (reuse later) — used for switch / network change | FEAT DISCONNECT | P3 |
| F12.2 | Disconnect (user) | `StopSession`, then settle: voucher → `start_close_channel`; stream → `close_channel` now | D3, S17 | P3 |
| F12.3 | Settlements queue | voucher channels wait 7200 s grace; queue persisted to disk; countdown; "Close now" when ready → `close_channel` | S17, S18 §5 (`GraceNotElapsed`) | P3 |
| F12.4 | Withdraw refunds | `User.balance` > 0 → "Withdraw" → `withdraw_user_balance` | S17 | P3 |
| F12.5 | StopSession result | `kill_switch_released=false` is normal; `dns_revert_failed` → banner with fix; an error = "your internet may be blocked" + Restore network | S25 dead-internet table | P3 |
| F12.6 | On quit / OS shutdown | register cleanup first: StopSession, queue settlement; never leave a tunnel up after quit unless the user chose persist kill switch | M5.1 #9, UXP | P3 |
| F12.7 | Plan sessions | stop only; nothing to settle, no refund | S17 | P4 |

## F13 — Sessions, channels and history

| ID | Feature | How | Phase |
|---|---|---|---|
| F13.1 | Sessions tab | `ListSessions` + local history (node, basis, bytes, seconds, spent, close reason) | P3 |
| F13.2 | Channels tab | `ListChannels` + chain: escrow, redeemed, status, mode, close timer; actions reuse / top up / settle | P3 |
| F13.3 | Tickets | `ListTickets` for plan sessions | P4 |
| F13.4 | Spend summary | per day / node; on-chain truth wins over local notes | P6 |
| F13.5 | Export | CSV / JSON | P6 |
| F13.6 | Persistence round-trip | every cached model survives JSON write → read → use (bigint as string) | P1 |

## F14 — Kill switch

| ID | Feature | How | Source | Phase |
|---|---|---|---|---|
| F14.1 | Modes | off / on (default) / persist (survives daemon restart) — daemon `network.kill_switch` | SRC `client.go`, D4 | P5 |
| F14.2 | Warning copy | what each mode blocks; persist can leave you offline until you reconnect or restore | SET, S25 | P5 |
| F14.3 | Dead-internet detection | on start and on pipe loss: no session but connectivity fails → banner | S25 table, S18 §6.2 | P5 |
| F14.4 | Restore network | StopSession; if the daemon is dead, elevated release (WFP filters / service restart) | S25, UPSTREAM-GAPS #5 | P5 |
| F14.5 | Credit exhausted holds | after `credit exhausted` the kill switch blackholes; show "add credit / reconnect" | S17 | P5 |

## F15 — DNS

| ID | Feature | How | Source | Phase |
|---|---|---|---|---|
| F15.1 | Presets | Handshake `103.196.38.38, 103.196.38.39` (default), Cloudflare, Google, custom → daemon `network.dns_servers` | SET, HNS MANIFESTO, FEAT DNS | P5 |
| F15.2 | Backend | netsh on Windows; `none` for advanced users | SRC `config.go dnsBackends` | P5 |
| F15.3 | Revert failure | `dns_revert_failed` → banner + one-click fix | S25 | P5 |
| F15.4 | Leak check | resolve through the tunnel and compare resolver | FEAT DNS, CVT DNS test | P6 |

## F16 — Split tunnelling

What the daemon allows today (D7):

| mode | protocols | status |
|---|---|---|
| Full device | WireGuard, AmneziaWG, OpenVPN, Hysteria2 | ✅ default |
| Per-app (only chosen apps use the VPN) | V2Ray, Xray — local SOCKS `127.0.0.1:1080`, no-auth | ✅ with kill switch **off** |
| Per-destination (only some IPs use the VPN) | WireGuard | ❌ needs UPSTREAM-GAPS #1 |
| LAN access while connected | all | ✅ `network.allow_lan` |

| ID | Feature | How | Source | Phase |
|---|---|---|---|---|
| F16.1 | Proxy endpoint | show `Session.proxy_endpoint`, copy, how-to for curl / browsers / apps | SUG split-tunnel analysis | P5 |
| F16.2 | Browser through VPN | launch Chrome/Edge with `--proxy-server=socks5://…` and a separate profile dir | SUG split-tunnel Part 7 | P5 |
| F16.3 | System proxy toggle | set/clear HKCU WinINET proxy (no elevation), saving and restoring any prior proxy; restored on disconnect and on next start after a crash (saved state persisted) | SDK `connection/proxy.js setSystemProxy/clearSystemProxy` | P5 |
| F16.4 | Kill-switch interlock | per-app mode requires kill switch off; UI explains and switches with consent (D4) | D7 | P5 |
| F16.5 | Allow LAN | toggle → daemon `allow_lan` | SRC firewall rules | P5 |
| F16.6 | Verify | proxied IP ≠ direct IP check button | FEAT SPLIT-TUNNEL-TESTING | P5 |
| F16.7 | WireGuard split | hidden until the daemon supports it | UPSTREAM-GAPS #1 | later |

## F17 — Protocols and dependencies

| ID | Feature | How | Source | Phase |
|---|---|---|---|---|
| F17.1 | Protocol list | bitmask WG 1, V2Ray 2, Xray 4, OpenVPN 8, Hysteria2 16, AmneziaWG 32 | S19 | P3 |
| F17.2 | Dependency check | per protocol from doctor; node rows show "needs X" instead of failing after payment | HNS recs §2.3 | P5 |
| F17.3 | Install guidance | WireGuard for Windows, OpenVPN + "OpenVPN Wintun" adapter, binary named exactly `hysteria2` | S30 | P5 |
| F17.4 | Preference order | user ranks protocols; Quick connect follows it | SET | P5 |
| F17.5 | Censorship badges | AmneziaWG (obfuscated), Hysteria2 (QUIC) marked "works on restrictive networks" | S19 | P5 |

## F18 — Settings

Two stores. App settings: `%APPDATA%/Devnet dVPN/settings.json`, allow-listed keys, clamped
(NM `settings.ts`). Daemon settings: `config.toml` files, written per D4 (stage → validate → one
UAC copy → restart service → re-check doctor).

| key | store | default | Phase |
|---|---|---|---|
| RPC endpoints | app (+ daemon `[rpc]` url) | devnet pool | P1 |
| DNS preset / custom | daemon | Handshake | P5 |
| Kill switch | daemon | on | P5 |
| Allow LAN | daemon | off | P5 |
| Default basis | daemon `basis` + app | per GB | P3 |
| Default escrow / prepay | daemon `escrow`, `prepay_bytes`, `prepay_seconds` + app per-connect (app always sends an explicit escrow from F8.3, never relies on the daemon default) | daemon defaults: escrow 1,000,000,000 base units (= 1,000 tDVPN at 6 decimals), prepay 1 GB / 3600 s (`internal/config/client.go`) | P3 |
| Protocol preference | app | WG, AWG, Xray, V2Ray, Hysteria2, OpenVPN | P5 |
| Preferred country | app | none | P3 |
| Auto-connect on launch | app | off | P6 |
| Start with Windows | app | off | P6 |
| Close to tray | app | on | P6 |
| Refresh intervals | app | F5 table | P1 |
| Owner signing mode | app | in-app key | P2 |
| Language / theme | app | system | P1 |
| Third-party checks (IP, speed) | app | on, disclosed | P6 |

Rules: nulls mean defaults (SET); a settings change never interrupts a live session without
saying so (daemon settings apply on next connect or after an explicit restart).

## F19 — Quality and diagnostics

| ID | Feature | How | Source | Reuse | Phase |
|---|---|---|---|---|---|
| F19.1 | IP check | 3 services; real vs VPN IP | SUG windows-app-standards | — | P6 |
| F19.2 | Speed test | fallback chain (Cloudflare → multi-request → OVH → Tele2 → rescue → zero-speed), baseline first, pre-resolve DNS | HNS recs §2.1-2.2 | NT `speed.js` | P6 |
| F19.3 | Connectivity check | first reachable of 4 targets, latency | CVT | — | P6 |
| F19.4 | App log | rotating file, redacted (keys, RPC tokens), copy button, 6-line live strip | M7.1 #7, SUG | NM `logger.ts` | P1 |
| F19.5 | Daemon log + doctor view | read-only | S30 | — | P6 |
| F19.6 | Diagnostics bundle | versions, settings (redacted), doctor, last N log lines | — | NM `system-report.ts`, `redactSettings` | P6 |

## F20 — In-app node testing

A separate tab with its own service; it shares no state with the main VPN flow (CVT).

| ID | Feature | How | Phase |
|---|---|---|---|
| F20.1 | NodeTestService + adapter | calls the app's own connect/disconnect through an adapter, one node at a time | P7 |
| F20.2 | Exclusive with VPN | the daemon runs one session; testing only when disconnected, and it says so | P7 |
| F20.3 | Spend consent | per-run confirmation, max nodes, max spend; uses fresh channels and settles them | P7 |
| F20.4 | Checks | connect time, connectivity, DNS (Handshake + standard), speed vs baseline | P7 |
| F20.5 | Results | FAST / SLOW / FAIL, transport detail, filters, sort, expandable diagnostics | P7 |
| F20.6 | History | `node-tests/latest.json`, `history/<ts>.json`, append-only failures log, compare runs, export | P7 |
| F20.7 | Progress always moves | success, error and cancel all increment; Stop works between nodes | P7 |

Reuse: NM `node-test.ts` (step reporting), NM `test-channels.ts` (sweep test channels).

**Built (2026-10-21):** `src/core/nodetest/nodetest.ts` (verdicts, estimate, compare),
`src/main/services/node-test.ts`, the Node test screen and CLI `test plan|run|stop|history|show|export`.
Per-hour basis when the server offers it (closes right after), else per GB (2 h grace). FAIL = no
connect or exit IP ≠ server; SLOW = under 20 % of the direct speed or under 1 Mbps. DNS is checked
through the resolver the daemon applies (Handshake by default); a separate Handshake-name check is
not built. Stop works from the screen, Ctrl-C, or `test stop` in another terminal (marker file).

## F21 — Desktop integration

| ID | Feature | How | Reuse | Phase |
|---|---|---|---|---|
| F21.1 | Tray | status icon, connect/disconnect, last node, open, quit | NM `tray.ts` | P6 |
| F21.2 | Close to tray | first-time hint notification | NM `maybeShowTrayHint` | P6 |
| F21.3 | Notifications | connected, dropped, credit exhausted, low balance / allowance, subscription expiring, settlement ready | — | P6 |
| F21.4 | Start with Windows | login item, minimised | — | P6 |
| F21.5 | Auto-connect | opt-in, last/preferred node, never after a crash | — | P6 |
| F21.6 | Single instance | second launch focuses the first | — | P1 |

## F22 — Updates and versions

| ID | Feature | How | Reuse | Phase |
|---|---|---|---|---|
| F22.1 | App updates | disabled with a stated reason until a private release channel exists | NM `updater.ts` | P8 |
| F22.2 | Compatibility | app knows the daemon versions it supports (`GetVersion` commit/tag); mismatch → update prompt | — | P1 |
| F22.3 | Devnet labelling | "Devnet — test tokens" badge always visible | — | P1 |

## F23 — Errors and copy

| ID | Feature | How | Source | Reuse | Phase |
|---|---|---|---|---|---|
| F23.1 | Severity classes | fatal / retryable / recoverable / infrastructure → modal / toast / inline | ERR | — | P1 |
| F23.2 | Node API codes | credit_exhausted, peer_limit_reached, lease_insufficient, subscription_invalid, ticket_invalid, unauthorized, voucher_*, channel_node_reopened, terms_rejected, rate_limited, mode_not_*, session_not_found, channel_not_open, bad_request, request_too_large, internal → copy + action | S29 | PM `errors.js` | P1 |
| F23.3 | Program errors by number | devnet shift 6022-6038 = source − 1, 6039 devnet-only | S14 | PM `solana/errors.js` | P1 |
| F23.4 | gRPC status | unavailable → "daemon not running" etc. | — | PM `daemon.js` | P1 |
| F23.5 | Tx errors | insufficient SOL / tDVPN, expired, 429 → plain copy; check signature before resending | S29 §6 | NM `classifyErr`, PM `sendSigned` | P1 |
| F23.6 | Never raw | no stack, URL, `getaddrinfo` text reaches the UI; code + message always | M5.2 #8-9 | — | P1 |

## F24 — Security

| ID | Feature | How | Source | Phase |
|---|---|---|---|---|
| F24.1 | Renderer isolation | contextIsolation, sandbox, no nodeIntegration, strict CSP | M5.1 | P1 |
| F24.2 | IPC contract | `IPC` enum constants both sides; every handler validates input; tiered ui/readonly/local/privileged/spend | M5.1 #2-3, M5.2 #1 | P1 |
| F24.3 | Secrets | main only, safeStorage, mnemonic not kept after derivation, stderr never stdout | M7.1 | P1 |
| F24.4 | Transport | https-only RPC (loopback excepted), TLS pin to nodes, signed metadata/tickets verified | S18 | P1 |
| F24.5 | Cold-mode relay safety | fee payer must be the owner, programs allow-listed, no lookup tables | PM `assertRelayable` | P2 |
| F24.6 | Privacy | no telemetry; third-party calls listed in Settings and switchable | MANIFESTO | P1 |

## F25 — Language, accessibility, theme

| ID | Feature | How | Phase |
|---|---|---|---|
| F25.1 | String catalogue | every user string from a catalogue from day one; English first | P1 |
| F25.2 | RTL-ready layout | logical CSS properties (idea from Chiba; no code) | P8 |
| F25.3 | Accessibility | keyboard navigation, focus rings, contrast, screen-reader labels on the connect control | P8 |
| F25.4 | Theme tokens | light/dark tokens only, no hard-coded colours (NM tailwind tokens) | P1 |

## F26 — Testing and release

See [`TEST-PLAN.md`](TEST-PLAN.md). The release gate is every row of
[`STANDARDS-TRACE.md`](STANDARDS-TRACE.md) ticked, including S25 §10 and S29 §9.

---

## Phase plan

| phase | contents | exit criteria |
|---|---|---|
| **P0 spikes** | grpc-js ↔ named pipe with `socket_group`; Windows WireGuard session end to end in a disposable VM; TS builders for `add_operator`, `update_operator`, `remove_operator`, `start_close_channel`, `close_channel`, `fund_channels` simulated and landed on devnet; elevated config apply + restart | each spike passes or has a written fallback |
| **P1 foundation** | scaffold from NM electron-vite layout; shared types + IPC enum; settings; logger; RPC pool; chain ports (idl/accounts/program/tx/errors); daemon client; scheduler; error map; security baseline; string catalogue | app boots, reads chain, talks to daemon |
| **P2 onboarding** | installer; doctor; wallet (both signing modes); grant wizard | fresh machine → ready to connect |
| **P3 direct connect** | discovery; browser; pricing; connect; state machine; disconnect + settlement; history | connect → disconnect → reconnect → settle → withdraw on devnet |
| **P4 plans** | browse, subscribe, connect via ticket, renew, cancel | plan session on devnet |
| **P5 network safety** | kill switch; DNS; split tunnelling; protocols; daemon settings | crash → restore; split proof |
| **P6 quality + desktop** | IP / speed / diagnostics; tray; notifications; startup | — |
| **P7 node test tab** | F20 | 10-node run with history |
| **P8 release** | checklists, packaging, uninstall, a11y, update policy | STANDARDS-TRACE all ticked |
