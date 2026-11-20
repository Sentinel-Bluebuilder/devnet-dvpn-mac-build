# Reuse map — Devnet dVPN

What we port from **our own** repos, and where it lands (layout in
[`ARCHITECTURE.md`](ARCHITECTURE.md)). ChibaTunnel is not on this list: it may inspire ideas, but
none of its code is used.

Porting rule: read the source file line by line and translate statement by statement into strict
TS; keep its comments about why. Never "describe and regenerate" (Sentinel SDK parity lesson).

## From Plan Manager (Solana) — `Desktop/plans-solana`

| source | lines | → target | notes |
|---|---|---|---|
| `lib/daemon.js` | 150 | `core/daemon/client.ts` | grpc-js + proto-loader options, 20 s deadline, gRPC → status map. Add Windows pipe target (P0 spike) |
| `proto/daemon.proto` | — | `core/daemon/daemon.proto` | copy as-is; `ClientService` + `DaemonService.GetVersion` |
| `chain/idl/dvpn.devnet.json` | — | `core/chain/idl/dvpn.devnet.json` | the patched devnet IDL |
| `lib/solana/idl.js` | 132 | `core/chain/idl.ts` | network identity, `DEPLOYED_SIZES`, memcmp `OFFSETS`, discriminators, protocol names |
| `lib/solana/accounts.js` | 171 | `core/chain/accounts.ts` | `fetchOne` / `fetchMany` (dataSize + discriminator + memcmp), readers `allNodes`, `allPlans`, `subscriptionsByOwner`, `userByOwner`, amount helpers |
| `lib/solana/program.js` | 253 | `core/chain/pdas.ts`, `core/chain/builders.ts` | PDAs (config, provider, plan, subscription, node, user, grant (was mandate)), `ata`, `fetchConfig` cache, builders `openSubscription`, `closeSubscription`, `withdrawUserBalance`. **Add** `addOperator`, `updateOperator`, `removeOperator`, `startCloseChannel`, `closeChannel`, `fundChannels` (P0) |
| `lib/solana/rpc.js` | 148 | `core/chain/rpc.ts` | pool, benching, 429 detection, `rpcCall`, `getRpcState`, `redactUrl` |
| `lib/solana/tx.js` | 207 | `core/chain/tx.ts`, `main/wallet/relay.ts` | `buildTx` (simulate → CU margin → priority fee), `sendSigned` (idempotent resend, "already processed"), `confirmSignature` via pool, `assertRelayable`, per-signer queue |
| `lib/solana/errors.js` | 113 | `core/chain/errors.ts` | devnet number shift, `extractErrorCode`, `ProgramError` |
| `lib/errors.js` | 104 | `shared/errors.ts` | app error codes / statuses |
| `lib/nodeapi.js` | 196 | `core/nodes/nodeapi.ts` | signed request headers (`api-request/v1`), TLS-pinned `httpsRequest`, ticket request/decode |
| `lib/session.js` (`keypairFromInput`) | ~40 | `core/wallet/keys.ts` | phrase / JSON / base58 import |
| `lib/cache.js` | 48 | `core/cache.ts` | TTL cache |

## From Node Tester (Solana) — `Desktop/sentinel-node-tester-solana`

| source | lines | → target | notes |
|---|---|---|---|
| `lib/discovery.js` | 178 | `core/nodes/discovery.ts` | `discoverNodes` (listed vs fresh, 60 s cache), `probeNode` (TCP check, metadata, signature, claims, expiry, pin, peers, bandwidth, location, service type) |
| `lib/nodeapi.js` | 208 | merge into `core/nodes/nodeapi.ts` | compare with PM's copy; keep the stricter of each check |
| `lib/plans.js` | 130 | `core/plans/plans.ts` | plan + provider reads |
| `lib/speed.js` | 77 | `core/quality/speed.ts` | extend to the full fallback chain + baseline (HNS RECOMMENDATIONS §2.1–2.2) |

## From Node Manager (Solana) — `Desktop/sentinel-node-manager-solana`

| source | → target | notes |
|---|---|---|
| `electron.vite.config.*`, `tsconfig.node.json`, `tsconfig.web.json`, `tailwind.config.*`, `vitest.config.*`, `electron-builder.yml` | repo root | scaffold; rename app id / product name; NSIS per-machine |
| `src/shared/types.ts` IPC enum pattern | `src/shared/ipc.ts` | constants both sides, never raw strings |
| `src/preload/index.ts` | `src/preload/index.ts` | `subscribe` / `invoke` pattern, listener cleanup |
| `services/wallet.ts` | `main/wallet/vault.ts`, `main/wallet/balances.ts` | safeStorage vault, `fetchBalances`, `transferInstructions`, `sendFrom`, `classifyErr`, `sanitizeErr` |
| `services/keys.ts` | `core/wallet/keys.ts` | mnemonic create/validate/normalise, derivation |
| `services/settings.ts` | `main/system/settings.ts` | allow-listed keys, clamps, `isValidRpcUrl`, `redactSettings`, change events |
| `services/logger.ts` | `main/logger.ts` | add a redactor for keys and RPC tokens |
| `services/tray.ts` | `main/system/tray.ts` | swap node actions for connect / disconnect |
| `services/updater.ts` | `main/system/updater.ts` | disabled-with-reason pattern |
| `services/validate.ts` | `main/ipc-validate.ts` | input validators |
| `services/store.ts`, `services/events.ts` | `main/system/store.ts`, `main/system/events.ts` | JSON store + activity events |
| `services/solana-client.ts` | superseded by PM `rpc.ts` / `tx.ts` | keep `withRpcTimeout` wrapper |
| `services/system-report.ts`, `diagnostics.ts` | `main/system/diagnostics.ts` | redacted bundle |
| `services/node-test.ts`, `test-channels.ts` | `main/node-test/` | step reporting, test-channel sweep (P7) |

## From the Sentinel JS SDK — `Desktop/Sentinel SDK/js-sdk` (ours, published as `blue-js-sdk`)

Cosmos-era SDK; only its **chain-agnostic** helpers are ported. Its silent `catch {}` blocks are
rewritten to log with context.

| source | lines | → target | notes |
|---|---|---|---|
| `app-helpers.js` `COUNTRY_MAP`, `countryNameToCode`, `CONTINENT_BY_CODE`, `countryToContinent`, `groupNodesByCountry` | 418 | `core/nodes/country.ts` | name variants + fuzzy match; continent grouping |
| `app-helpers.js` `formatBytes`, `formatUptime`, `GB_OPTIONS`, `HOUR_OPTIONS` | — | `core/pricing/format.ts` | price formatting rewritten for tDVPN base units |
| `disk-cache.js` `cached`, `diskSave`, `diskLoad` | 107 | `main/system/disk-cache.ts` | TTL + stale-while-revalidate for node / plan lists |
| `connection/proxy.js` `setSystemProxy`, `clearSystemProxy`, `checkPortFree` | 148 | `main/system/proxy.ts` | Windows WinINET registry; saves and restores a prior (corporate) proxy |
| `preflight.js` `checkVpnConflicts`, port checks | 352 | `main/system/preflight.ts` | other VPN clients running; local SOCKS port 1080 already taken |
| `connection/resilience.js` circuit breaker (`recordNodeFailure`, `isCircuitOpen`) | 441 | `core/nodes/circuit.ts` | skip repeatedly failing nodes in Quick connect; its reconnect logic is NOT ported (daemon owns reconnect, D6) |

## Built new (no source of ours)

Session state machine and close-reason copy (spec: S17, CSM), settlement queue (D3), elevated
settings apply (D4), browser launch through the proxy (F16.2), bundled flags (F6.9),
browser-wallet relay page (F2.6, logic from PM `tx.js`), installer steps (F1).
