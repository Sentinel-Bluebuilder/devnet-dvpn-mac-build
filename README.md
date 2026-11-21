# Devnet dVPN for macOS

A pure peer-to-peer dVPN app on the Sentinel Solana devnet protocol. Pick any server and pay it
directly, or subscribe to any plan. No accounts, no servers of ours in the middle.

This is the macOS build of Devnet dVPN (#31 Windows, #32 Linux): the same features, screens and
CLI, with a macOS platform layer (unix socket, launchd LaunchDaemon, osascript admin prompt, pf
kill switch, networksetup DNS + system proxy, Keychain). Electron + React + TypeScript; sessions
run through the `dvpnd` daemon; the app signs owner transactions itself. Every app function is
also a command (`devnet-dvpn …`).

## Install

Open `Devnet-dVPN-<version>-<arch>.dmg` and drag the app to Applications. The app is
ad hoc signed (v0.3.0-rc8), not notarized: the first time, right-click it → Open. Its first run sets up the device
and installs the VPN service (one administrator prompt); after that `devnet-dvpn help` works
in any terminal. To remove it: Diagnostics → Remove the VPN service (or
`devnet-dvpn daemon uninstall --yes`), then drag the app to the Trash. Scripts and AI agents
install from a terminal with no clicks (`hdiutil` + `ditto`, then `daemon init` → `device setup`
→ `daemon install`): `docs/INSTALLER.md` "Install from a terminal".

## Develop

```bash
npm ci
npm run typecheck
npm test                              # authoritative run is in the macOS guest
npm run release:mac                   # on a Mac: .dmg + .zip (x64 + arm64) + SHA256SUMS
```

Live tests run on a disposable macOS runner, never on a developer's own Mac: the end-to-end harness is kept
outside the public source, except `scripts/e2e/mac/gha-live.sh` + `gha-mac-rows.sh`, which the
`macos-rc8` workflow runs on a GitHub macOS runner.

## Docs

| doc | what it is |
|---|---|
| `docs/MAC-PARITY.md` | every command, feature, screen, protocol: Windows / Linux / Mac evidence |
| `docs/MAC-PORT.md` | each Linux piece and what replaced it on macOS |
| `docs/INSTALLER.md` | .dmg / .zip, first-run setup, update, uninstall, proof |
| [`docs/CLI.md`](docs/CLI.md) | every command (generated from `src/cli/catalogue.ts`) |
| `docs/LINUX-PORT.md` | the Windows → Linux map this build started from |
| [`ARCHITECTURE`](docs/ARCHITECTURE.md), [`DESIGN`](docs/DESIGN.md), [`MANIFESTO`](docs/MANIFESTO.md) | shared with #31 (platform paths map per `MAC-PORT.md`) |

## Repo map (publish structure)

- **Build / test:** `npm ci`, `npm run typecheck`, `npm test` (see sections above for platform specifics).
- **Tests:** unit tests under `tests/` / `src/**/*.test.ts`; end-to-end harness kept outside the public source.
- **Evidence:** run proofs are the GitHub Actions run summaries and their evidence artifacts.
- **Never committed:** wallets, keys, `.env`, `dvpnd`/`upstream` source (see `.gitignore`).

## License

Devnet dVPN is released under the Sentinel dVPN License (see [`LICENSE`](LICENSE)). It is a client for the
open-source [Sentinel](https://sentinel.co) protocol.

The app and its packages bundle third-party software — the Sentinel daemon, the Xray / Hysteria /
V2Ray transports, and fonts — each under its own license. These are listed in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md); a per-release copy with exact versions, SHA-256
sums and the Xray modification patch (`docs/patches/xray-0001-darwin-find-process.patch`) is
generated to `build/THIRD-PARTY-NOTICES.txt` and shipped inside the app. The VPN tunnel tools are not
in the packages: **Repair drivers** installs them from Homebrew, each under its own license.
