# Audit coverage — #33 macOS layer, parts 1 + 2 (AC-MAC-1, at 65247b082; part 2 read at 84b42a1a9)

Phase 2 parts 1 + 2 of the final-line audit: every row below is read in full. Checklist per file: (1) correct from the call site, every branch;
(2) every failure coded, no `catch {}`, no un-awaited timer; (3) every path quoted (the home has a space),
bash 3.2-safe; (4) flags exist; (5) money preview/check; (6) no secrets; (7) UTF-8/LF; (8) docs = code;
(9) a failing-first test per fix. Findings are rows C1-C8 in the hub's `tests/walk/AUDIT-FINAL-FINDINGS.md`.
Tests added here have not run yet: no tests on the laptop; the macOS CI run on the rc.9 export runs them.

| file | lines | auditor | read | classes | findings | result |
|---|---|---|---|---|---|---|
| resources/scripts/dvpn-helper | 17 | AC-MAC-1 | full | 1-4,6-7 | — | pass |
| resources/scripts/_lib.sh | 107 | AC-MAC-1 | full | 1-4,7 | — (write_result dir-swap race: target must be named result.json, below L) | pass |
| resources/scripts/setup-daemon.sh | 226 | AC-MAC-1 | full | 1-4,6-9 | C1 (M) | fixed 4a419a1c0 |
| resources/scripts/apply-daemon-config.sh | 53 | AC-MAC-1 | full | 1-4,7,9 | C2 (M) | fixed 4a419a1c0 |
| resources/scripts/migrate-daemon-config.sh | 56 | AC-MAC-1 | full | 1-4,7 | (reached by C1 through a linked config.toml; closed by C1's fix) | pass after C1 |
| resources/scripts/remove-tunnels.sh | 89 | AC-MAC-1 | full | 1-4,7,8 | C4 (L) | open |
| resources/scripts/service-ctl.sh | 16 | AC-MAC-1 | full | 1-4 | — | pass |
| resources/scripts/grant-socket.sh | 38 | AC-MAC-1 | full | 1-4 | — | pass |
| resources/scripts/install-deps.sh | 251 | AC-MAC-1 | full | 1-4,7,8 | C5 (comment). `--OutDir` from root callers: none (drivers.ts:170), not a finding. Homebrew / user AmneziaWG copy = code trust by design (fallback only when the bundle lacks a tool) | pass |
| resources/scripts/uninstall-cleanup.sh | 72 | AC-MAC-1 | full | 1-4,7 | — | pass |
| src/main/system/elevate.ts | 158 | AC-MAC-1 | full | 1-3,6,8 | C5 (comment) | fixed 4a419a1c0 |
| src/main/system/tunnels.ts | 208 | AC-MAC-1 | full | 1,2,8 | C4 (L) | open, rc.10 |
| src/main/system/proxy.ts | 203 | AC-MAC-1 | full | 1,2,8 | — | pass |
| src/main/system/drivers.ts | 196 | AC-MAC-1 | full | 1,2,8 | C6 (M: Repair drivers fails on a Mac with no Homebrew even with every tool bundled) | open, rc.10 |
| src/main/daemon/manager.ts | 1120 | AC-MAC-1 | full | 1,2,6,8 | C3 (M, raised by the lead) | fixed 14691cfd1 |
| src/cli/keystore.ts | 173 | AC-MAC-1 | full | 1,2,6 | — (secret on stdin as hex, read back, quote/newline refused; paths shellWord-quoted) | pass |
| PLATFORM-EXCEPTIONS.txt | 14 rows | AC-MAC-1 | full | 8 | — | pass |
| src/main/system/admin-check.ts | 20 | AC-MAC-1 | full | 1,2 | — (Windows only; null on macOS) | pass |
| src/main/system/apps.ts | 111 | AC-MAC-1 | full | 1,2 | — | pass |
| src/main/system/autostart.ts | 76 | AC-MAC-1 | full | 1,2,8 | C7 (MAC-PORT row said setLoginItemSettings; code = own LaunchAgent) | fixed (docs) |
| src/main/system/browser.ts | 78 | AC-MAC-1 | full | 1,2 | — (loopback-only endpoint, DNS off-host rule) | pass |
| src/main/system/cli-shell.ts | 6 | AC-MAC-1 | full | 1 | — | pass |
| src/main/system/direct-wait.ts | 22 | AC-MAC-1 | full | 1,2 | — | pass |
| src/main/system/dns-check.ts | 91 | AC-MAC-1 | full | 1,2 | — | pass |
| src/main/system/dns-probe.ts | 86 | AC-MAC-1 | full | 1,2 | — (timer cleared, socket closed on every path) | pass |
| src/main/system/notify.ts | 26 | AC-MAC-1 | full | 1,2 | — | pass |
| src/main/system/settings.ts | 81 | AC-MAC-1 | full | 1 | — (every field sanitised) | pass |
| src/main/system/tray.ts | 71 | AC-MAC-1 | full | 1,2,5 | — (never connects from the tray: a connect pays) | pass |
| src/main/system/window-guard.ts | 71 | AC-MAC-1 | full | 1,2 | — | pass |
| build/mac/adhoc-sign.cjs | 138 | AC-MAC-1 | full | 1,2,6,8 | C8 (L: header + error say ad hoc is dev-only; rc8 release is ad hoc). Keychain password on argv (:95): accepted, build-only keychain, commented | open, rc.10 |
