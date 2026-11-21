# Changelog — Devnet dVPN for macOS

Entries for builds not yet released. The history of shipped builds is in the public repository's
`CHANGELOG.md` (Sentinel-Bluebuilder/sentinel-solana-dvpn-macos); at the next release this
section moves there under its version.

## Unreleased — next release candidate (after 0.3.0-rc.2)

### Three commands for AI agents and scripts (#31 dff77e8…a75d4e5, ported in 8df146f42)

- `devnet-dvpn agent up [--protocol any|wireguard|amneziawg|openvpn|v2ray|xray|hysteria2] [--country CC] [--node N] [--basis per_gb|per_hour] [--units N] [--plan <subscription>] [--max-price N] --yes`
  creates the device key if it is missing, picks the best online server that matches, pays the
  deposit (or uses a plan) and connects. It prints one JSON line: session, server, protocol,
  country, exit IP, SOCKS endpoint and the next step. If a session is already live, it answers
  with that session and pays nothing again.
- `devnet-dvpn agent down --yes` disconnects, closes per-hour deposits at once (they bill until
  closed) and starts the refund of per-GB ones. It says what is refundable and when.
- `devnet-dvpn agent status` gives the wallet, session and exit IP as one JSON line with the next
  step (for example, what to fund).
- **The `--yes` rule:** `agent up` and `agent down` sign transactions, so without `--yes` they only
  print what they would do (exit code 2). `agent status` never spends.
- **macOS: every hint can be run as printed.** Until `daemon install --yes` links
  `/usr/local/bin/devnet-dvpn`, the command is the one inside the app
  (`/Applications/Devnet dVPN.app/Contents/Resources/bin/devnet-dvpn`). That launcher now tells
  the CLI its own path (`DVPN_CLI_NAME`, quoted), so the `next` hints name it until then.
- **macOS: V2Ray needs no extra install.** V2Ray, Xray and Hysteria2 ship inside the app, so
  `agent up --protocol v2ray --yes` works on a fresh Mac. WireGuard, AmneziaWG and OpenVPN need
  `daemon repair-drivers --yes` (Homebrew; Intel builds from source, which is slow). If a server's
  tool is missing, the answer is `protocol-missing`, and its next step names both ways out.
- **Limit: one administrator step.** The VPN service is installed once with `daemon install --yes`.
  With passwordless `sudo` (`sudo -n`) nothing asks. Otherwise macOS shows its password dialog,
  which needs a person at the screen: an agent over SSH cannot answer it.
- Tested: `agent-cmd`, `cli-map` and `ui-controls` unit tests 41/41 on darwin, typecheck clean
  (Linux CI box, 2026-11-15). Not yet run live on a Mac.

### Documentation fixed (2026-11-15, docs only)

- `docs/INSTALLER.md`: new "Install from a terminal (no clicks)" (`hdiutil` + `ditto`, the CLI
  inside the app until `daemon install`, key file, `sudo -n` vs the password dialog). The Proof
  section said "Pending"; it now cites the fresh install on 0.3.0-rc.1 and the 0.1.3 → 0.3.0-rc.2
  update (bc41ba34f).
- `README.md`: garbled signing sentence fixed; points scripts and agents to the terminal install (bc41ba34f).
- `docs/MAC-PARITY.md`: a "Current proof" table with evidence. The older cells said "not run" or
  "blocked" for things that had passed: plans, split by address on all six protocols, whole
  device, DNS, allow LAN (bc41ba34f, 0770cd500).
- Public `sentinel-solana-dvpn-macos` repository:
  - README (2628abcd): it called the release "RC2 on cut final6.1". It now says 0.1.3 carries
    `final6.5` and the pre-release 0.3.0-rc2 carries `final6.16`. The checksum check uses
    `shasum` (macOS has no `sha256sum`), and a terminal install was added.
  - README (58babcca): added requirements (macOS 12+, Intel tested, arm64 never run, administrator
    account), which protocols need Homebrew, what uninstall keeps, and the 0.3.0-rc2 known issues.
  - CHANGELOG (58babcca): added the missing 0.3.0-rc2 entry.
