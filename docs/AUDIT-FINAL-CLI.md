# Final audit: `src/cli` (rc.9)

Read-only, line by line, of every file in `src/cli` at #31 `76b237e2` + LIM-1. For each message, `next`, code, flag
help and money word, the question was: is it wrong, stale, contradictory or unclear, and is there a logic bug?
Line numbers are on that base. Severity: **H** = an agent that follows the answer gets stuck or does the wrong thing
with money; **M** = a wrong or misleading answer, exit class or money word; **L** = wording, a missing CLI name, a
missing `next`.

H and M rows are fixed in rc.9 by the patch named in the Fix column. L rows are listed for rc.10.

## H

| # | Where | What is wrong | Fix |
|---|---|---|---|
| H1 | `commands.ts:213`, `cli-fail.ts:24-26`, `daemon-cmd.ts:140` | A loop on a fresh computer with no service. `device setup` answers `no-device-key` with next `daemon install --yes` ("installs it and creates the key"). `daemon install` refuses first, because there is no grant yet (`device-not-ready`, next `device setup --yes`). Nothing in the loop makes the key. | **AUD-1.** no-device-key without a service: `daemon init --yes, then device setup --yes`. device-not-ready with no device key: `daemon init --yes, then device setup --yes, then daemon install --yes`. `daemon init` answers `next`. The onboarding contract test (`tests/unit/onboarding-walk.test.ts`) follows `next` from the empty state for each entry command: it must reach connected in at most 6 steps, never repeat, and every clause must parse against the catalogue. |
| H2 | `error-out.ts:44` | `--json` `next` was the raw `action`. For app-label actions (`Retry` at 10 sites in `main/services`, `Open Wallet`, `Open diagnostics`), `next` was a button label, not a command. Text mode mapped the label; JSON did not. | **AUD-2 M1.** `next = commandNext(action, message)`: a known label becomes its command (matched case-insensitively), `Retry` becomes `agent status --json`, and a command stays itself. `action` keeps the label for older scripts. |

## M

| # | Where | What is wrong | Fix |
|---|---|---|---|
| M2 | `action-hint.ts:25` | `cliMessage` rewrote every "server" to "node", including "DNS server" (`config.ts:185`: "The DNS node 9.9.9.9 is not valid"). | AUD-2: `(?<!DNS )` on both lower-case forms. |
| M3 | `exit-codes.ts:20` | `rpc-busy`, `rpc-unavailable` and `rpc-ws` are money `unclear` ("not known whether a deposit was opened") but exited 6, whose contract is "no deposit possibly open, retry later". | AUD-2: exit 1 on `agent`, `connect`, `switch` and `test`; exit 6 elsewhere. `docs/AGENT-COMMANDS.md` row 6 is updated. |
| M4 | `args.ts:8` | `switch`, `force`, `allow-empty`, `hidden` and `raise-limit` are read with `flag()` but were not in `BOOLEAN`. `connect --switch NodeA --yes` took NodeA as the value of `--switch`, so the node was lost and switch was false. | AUD-2: added to `BOOLEAN`. |
| M5 | `index.ts:87` | `--keyfile` with no value was `true`, so the key fell back to `DVPN_KEYFILE` or the stored wallet without a word: a command could sign with another wallet. | AUD-2: `requireValues(['keyfile'])`, usage error, exit 3. |
| M6 | `info-cmd.ts:83` | The text said "add another endpoint: rpc set <url>", but `rpc set` REPLACES the list. The CLI name was missing. | AUD-2: "set the endpoints: devnet-dvpn rpc set <url> [<url>...] (this replaces the whole list)". |
| M7 | `info-cmd.ts:75` | A bad `rpc set` URL was a bare Error (code null, exit 1). | AUD-2: usage error (exit 3), "Nothing was changed." |
| M8 | `info-cmd.ts:103` | When one bad value is given, `settings set` fails with exit 1, but the good keys on the same line were already saved, and the text read as if nothing changed. | AUD-2: `setting-rejected` names the saved keys; next `settings get`. |
| M9 | `status-cmd.ts:175` | With the kill switch on (not persist), the blocked advice said '"disconnect" gives the internet back'. With no session there is nothing to disconnect, and the persist line and `RECONNECT_BLOCKED_NEXT` already say restore-network. | AUD-2: both modes name `devnet-dvpn daemon restore-network`. |
| M10 | `daemon-cmd.ts:116` | `daemon init` with no wallet was a usage error (exit 3), while `daemon install` says `no-wallet` (exit 4). | AUD-2: `no-wallet` with the wallet create line. |
| M11 | `keystore.ts:38-39` | The `keyfile-read-only` next was "unset DVPN_KEYFILE": wrong when the key came from `--keyfile`, and not a Windows command. | AUD-2: "drop --keyfile and unset DVPN_KEYFILE (PowerShell: Remove-Item Env:DVPN_KEYFILE)". |
| M12 | `commands.ts:205`, `money-note.ts` | `device-key-unreadable` (a local read) was unclassified, so on `device` its money read "not known whether the transaction went through". | AUD-2: money `none`. `setting-rejected` is `none` too. |
| M13 | `commands.ts:128` | `wallet show` with no wallet answered ok with no `next`. | AUD-2: next `wallet create --keyfile <path> --yes`. |
| M14 | `commands.ts:353,358` | `connect`'s own refusals ("You do not hold that subscription", "No such node") were bare Errors, so money read "not known whether a deposit was opened" although nothing was paid. | AUD-2: `no-subscription` and `node-gone` (both `none`); next is the read that lists them. |
| M15 | `commands.ts:375` | With another VPN on, the wrapped error dropped the failure's code and next, so a `price-cap` refusal read as unclear, exit 1. | AUD-2: the code and action are kept. |
| M16 | `keystore.ts` (K-WIN), E-EP | The Windows icacls nexts used `"%USERNAME%:F"`. PowerShell does not expand it, and icacls answered "No mapping between account names and security IDs" (AC-WIN). | **KWIN-USER**: the account is written into the line (`DOMAIN\user`). |
| M17 | `agent-cmd.ts:88` `LIMIT_NEXT`, `action-hint.ts:29` | After a connect fails on the spending limit, `next` is prose ("N = grant.allowance … divided by 1000000, plus the deposit"), so it cannot be run, and it contradicts LIM-1's runnable `device setup --allowance <deposit> --yes`. | Open: on the connect-failure path the deposit is known, so `limitRefusal(...).next` can be used. Not in rc.9 unless the lead asks for it. |

## L (rc.10)

| # | Where | What |
|---|---|---|
| L1 | `server-stopped.ts:9`, `action-hint.ts:7-10,29`, `status-cmd.ts:165-166` | `devnet-dvpn` is hard-coded; every other file uses `CLI_NAME` (`DVPN_CLI_NAME`). |
| L2 | `server-stopped.ts:47-54` | `depositNext` ignores `in-use` while `depositRows`/`depositSafe` count it, so an in-use deposit with no session gets next null. |
| L3 | `split-cmd.ts:29,42` | Unreadable settings: no next (should be `daemon install --yes`); "Change it: daemon set …" lacks the CLI name. |
| L4 | `poll-cmd.ts:56,78` | Bare `throw new Error` (code null) against the "every failure carries a code" rule. |
| L5 | `send-check.ts:51-52` | A tDVPN send to a wallet with no token account also pays the account rent (~0.00204 SOL) if `send` creates it; the check counts only the base fee. Check `send` before deciding. |
| L6 | `info-cmd.ts:55,64` | A failed speed test or IP check prints its error and exits 0. |
| L7 | `info-cmd.ts:149,158` | "No SOCKS endpoint" is a bare Error (code null). |
| L8 | `index.ts:4,51` | The header lists exits 0-3 only (4/5/6 exist); the usage line omits `--keyfile <path>`. |
| L9 | `index.ts:126-130` | An unhandled rejection always exits 1, never `exitCodeFor(code)`. |
| L10 | `status-cmd.ts:131,139,174` | The quoted commands ("daemon restore-network", "proxy off") lack the CLI name. |
| L11 | `test-cmd.ts:96` | `test run --resume` with no earlier run still asks to continue "the last test run". |
| L12 | `test-cmd.ts:35,53` | The usage omits `--max-nodes`, `--limit`/`--max-spend`; "Continue with: test run --resume --yes" lacks the CLI name. |
| L13 | `daemon-cmd.ts:1-15` | `clockDoctorRow` sits above the file header and imports (where C-CLOCK put it). |
| L14 | `daemon-cmd.ts:230,248` | "(or run: devnet-dvpn daemon install)" lacks `--yes`; `new Error(r.error)` has no code. |
| L15 | `daemon-cmd.ts:75-78`, `commands.ts:245,248,279,412,423` | The quoted commands lack the CLI name (`daemon repair-drivers`, `settle run --device`, `daemon install`, `status`, `daemon restore-network`). |
| L16 | `commands.ts:148,152,197,251,491` | `wallet import` of a missing file is a raw ENOENT; `wallet receive`, `device register` and `device revoke` with nothing set are usage errors (exit 3), not `no-wallet`/`no-device`; `plans subscribe <unknown>` is a usage error, not `no-plan`. |
| L17 | `commands.ts:564,577`, `test-cmd.ts:35` | Help strings omit flags the catalogue has (`--allow-empty`, `settle run --device`). |
| L18 | `agent-cmd.ts:435,510` | `no-device` next is `daemon doctor` without `--json`; the `no-nodes` next ends in prose ("then widen --protocol / --country / --max-price"). |

## Checked and fine

`cli-fail.ts` (codes and doc anchors), `console-text.ts` (folding), `payer.ts`, `last-failed.ts` (skip window,
negative paths), the money classes in `money-note.ts` apart from M12, `send-check.ts` refusal order, `daemon set`
validation before `--yes`, `settle run`/`withdraw` nexts, and `disconnect` when no session is left.

Not read line by line in this pass: `up-lock.ts` (B-UP, rc.8, has its own tests), `ipc-map.ts`,
`android/split-android-cmd.ts`, `catalogue.ts` beyond the entries above. In `agent-cmd.ts` every `fail()`,
`next` and `alsoNext` site was read; the rest of its logic was not.
