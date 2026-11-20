# Stack decision — Devnet dVPN

**Status:** approved by the owner 2026-10-20 ("finish on electron"). v1 = Windows first.
Full feature plan: [`FEATURE-PLAN.md`](FEATURE-PLAN.md).
**Recommendation:** **Electron + React + TypeScript desktop app (electron-vite)** that drives the
upstream **`dvpnd` daemon** over gRPC. Windows first, Linux second, macOS later.

Every fact below was read from disk on 2026-10-20; sources are cited so each one can be re-checked.

---

## 1. The constraint that decides almost everything

On the Solana protocol an app **does not build tunnels or sign vouchers itself**. The upstream
Go daemon `dvpnd` (client role) owns the tunnel, routes, kill switch, DNS, voucher signing every
60 s, and chain RPC. The app drives it over a gRPC control socket
(`Desktop/sentinel-solana/docs/25-BUILDING-AN-APP.md` §1).

So the real question is not "which language can do VPN" — it is **"which UI stack is easiest to
pair with a privileged Go daemon, plus a wallet and on-chain discovery"**.

| platform | daemon control endpoint | runtime status |
|---|---|---|
| Linux | unix socket `<home>/daemon.sock` | ✅ proven on devnet (paid sessions, cutoff, subscriptions) |
| Windows | named pipe `\\.\pipe\ProtectedPrefix\Administrators\dvpnd\<role>`; daemon runs as LocalSystem service (`dvpnd service install`) | builds + `doctor` pass; **tunnel never run** (docs/30) |
| macOS | unix socket | builds only, **unverified** |

Unelevated app → elevated daemon is solved by the daemon itself: `[daemon] socket_group` in
`config.toml` adds that group's SID to the pipe ACL
(`upstream/sentinel-dvpnd/internal/daemon/daemon_windows.go:109-124`, `internal/config/config.go:59`).
Set it to `Users` and a normal user-mode app can connect.

## 2. What the daemon does NOT do (the app must)

`ClientService` exposes only `StartSession`, `StopSession`, `GetSession`, `WatchSession`,
`ListSessions`, `ListChannels`, `ListTickets` (`Desktop/plans-solana/proto/daemon.proto:146-153`).
The app itself must handle:

- **Node discovery** — every listed node, price, protocol, country; then probe it (`node inspect`)
  because "listed" outlives a dead daemon by up to 24 h.
- **Plan discovery + subscribing directly to any plan** (`subscribe`, close subscription).
- **Wallet** — owner key, SOL/tDVPN balances, `grant` + allowance for the device
  key, `withdraw_user_balance` for refunds.

**Write path (revised 2026-10-20, decision D2 in FEATURE-PLAN):** owner-signed writes are built in
TS from the **patched devnet IDL** (`plans-solana/chain/idl/dvpn.devnet.json`), the way #29 already
lands `open_subscription`, `close_subscription` and `withdraw_user_balance` on devnet. The deployed
program differs from the source IDL (`sentinel-solana/docs/14-DEVNET-LAYOUT-COMPAT.md`), so only
the devnet IDL + deployed sizes are used, every tx is simulated before signing, and each new
builder is proven on devnet in P0 before use. A bundled `dvpnctl` was rejected because it needs the
owner key as a file on disk. Wallet/SPL operations use `@solana/web3.js` + `@solana/spl-token`.

## 3. Options compared

| | Electron + React + TS | Tauri (Rust + web UI) | Wails (Go + web UI) | C# WPF | Web app only |
|---|---|---|---|---|---|
| Reuse from our Solana apps | **High** — #28b is this exact stack (scaffold, wallet, IPC, packaging, tests); #29 has a TS gRPC client for dvpnd + `daemon.proto` + error map | Low — Rust crate exists, no app code | Medium — same language as dvpnd, but no app code of ours | Low — Handshake dVPN is WPF but targets the Cosmos C# SDK, not Solana | n/a |
| Talk to dvpnd | `@grpc/grpc-js` (already used in #29) | tonic, named-pipe wiring by hand | native (`go-winio`, as dvpnd does) | Grpc.Net + named pipe | **impossible** — a browser cannot create a tunnel or reach the pipe |
| Ship the daemon | installer runs elevated once: `dvpnd service install`, set `socket_group` | same | same | same | — |
| Cross-platform | Win / Linux / macOS | Win / Linux / macOS | Win / Linux / macOS | **Windows only** | — |
| TypeScript rule (`~/memory/feedback_typescript_mandate.md`) | ✅ | partial | ❌ | ❌ | — |
| Binary size | ~100 MB + daemon ~48 MB | ~10 MB + daemon | ~15 MB + daemon | ~20 MB + daemon | — |
| Team familiarity on this machine | highest | low | low | medium | — |

**Verdict:** Electron wins on "easiest" by a wide margin: it is the only option where the scaffold,
wallet code, gRPC client, packaging and test setup already exist in our own repos. The size
penalty is irrelevant next to a 48 MB daemon that must ship anyway. Tauri is the upgrade path if
size ever matters; the React UI would port over unchanged.

Ruled out: **web-only** (cannot tunnel), **mobile** (dvpnd has no Android/iOS target), **WPF**
(Windows-only, and its Sentinel SDK is Cosmos).

## 4. Architecture

```
┌ Devnet dVPN (Electron, runs as the user) ──────────────────────────┐
│ renderer (React) ── IPC enum ──▶ main process                      │
│                                   ├─ daemon client  (grpc-js → pipe/socket)  connect / stop / watch
│                                   ├─ chain reads    (@solana/web3.js RPC)     nodes, plans, balances
│                                   ├─ chain writes   (TS, devnet IDL, owner)   subscribe, grant, settle, withdraw
│                                   └─ node probe     (HTTPS, pinned TLS)       "is it really online?"
└────────────────────────────────────────────────────────────────────┘
          │ named pipe (socket_group = Users)
          ▼
   dvpnd — client role, LocalSystem service: tunnel, kill switch, DNS, vouchers
          │                                   │
          ▼                                   ▼
   any node, directly (P2P)            Solana devnet (program J52dyXW3…)
```

Pure P2P properties this keeps:

- **No backend server, no API keys of ours.** The app talks only to Solana RPC and to nodes.
- **Any node, any plan:** discovery reads the on-chain registry; the user picks; payment is
  wallet ↔ node (voucher/stream channel) or wallet ↔ plan (subscription ticket). No allowlist.
- **RPC is user-configurable.** Public devnet RPC 429s under real use (docs/29 §6), so ship a
  fallback list and let the user paste their own endpoint; never bake a private key-bearing URL.
- **Keys:** owner key = "Your wallet" (signs grants/withdrawals); device key lives in the daemon
  under a `ROLE_USER` grant (was `mandate`) with an allowance (docs/29 §1, proven by `e2e-mandate.sh`).

## 5. Risks to retire first (spikes, in order)

1. **grpc-js over a Windows named pipe.** #29 only dials a unix socket. Verify grpc-js connects to
   `\\.\pipe\…`; fallback = a ~50-line Go sidecar bridging the pipe to a loopback port.
2. **Windows tunnel has never run.** Tunnel up/down, WFP kill switch, `netsh` DNS revert, crash
   recovery are all untested (docs/30). Run on a disposable Windows VM, never the owner's laptop.
3. **Requires WireGuard for Windows installed** (dvpnd shells out to `wireguard.exe`). Installer
   must bundle or detect it.
4. **Linux is the safe fallback** — everything is proven there, so Linux can be the first
   end-to-end target if the Windows spikes stall.

## 6. Standards this app must meet (sources)

- `sentinel-solana/docs/25-BUILDING-AN-APP.md` §10 ship checklist (StopSession on every exit,
  "dead internet" recovery, probe before charge, refunds withdrawable, errors by number).
- `sentinel-solana/docs/29-UI-UX-GUIDE.md` §9 checklist (state machine copy, 8 close reasons,
  node error codes, retry/backoff, no-refund disclosure on subscriptions).
- `Sentinel SDK/suggestions/2026-03-23-direct-connect-app-standard.md` (Cosmos-era, the UX shape
  of direct-connect still applies: cost shown before paying, all nodes browsable).
- `Sentinel SDK/docs/` — `CONNECTION-STATE-MACHINE.md`, `ERROR-MESSAGES.md`, `UX-FEATURE-PARITY.md`,
  `SETTINGS-SCREEN.md` (Cosmos-era; use for UX parity, never for chain mechanics).
