# Log audit (UI pass, step 0b)

One line per distinct warning, error or on-screen error sentence found in the logs of #31, with what the
user saw, the cause and where it stands. Owner: UI-ENGINE. Plan: `~/.claude/plans/swirling-brewing-finch.md`
section 5h. Row numbers in the last column are the plan's rows (1-165) or `NEW` for a line the plan did not
have; every OPEN or UNPROVEN line is a queue row.

Read on 2026-11-15 on the control box (the laptop only copied the files). Code references are to main at
`3c36017`.

## Status words

| Word | Meaning |
|---|---|
| OPEN | Still happens with the current code, or nothing in the code prevents it. |
| IN CODE, UNPROVEN | The current code handles it (file:line given), but no run on a release build shows the log free of it. Counts as not eliminated. |
| FIXED, TESTED | Handled in code and pinned by a unit test that is named. Still needs the VM walk with zero occurrences to be called eliminated. |
| SERVICE | The line comes from the VPN service (`sentinel-dvpnd` fork); written up for the fork owner, not changed in the app. |
| OTHER OWNER | The fix is in a file another session owns; sent to it. |
| NOT A DEFECT | Expected, and the user is told the right thing. Listed so it can go on the allow-list. |

Rule from the plan: a line is **eliminated** only with a test that reproduces it and a Windows VM run whose
`app.log` shows zero occurrences across the full walk. Nothing in this file is marked eliminated yet.

## Sources

| Source | Size | Period | Builds | Read how |
|---|---|---|---|---|
| Laptop app log `%APPDATA%\Devnet dVPN\logs\app.log` | 2,833 lines (1,744 warn, 15 error, 1,074 info) | 2026-10-20 to 2026-11-15 11:57Z | 0.1.0 dev and installed, 0.2.1 installed and one dev run, 0.3.0-rc.2 (one start, 2026-11-14 13:21Z) | grouped by message and normalised detail; per build; outage timeline |
| Laptop service log `C:\ProgramData\sentinel-dvpn\c0\daemon.log` | 15,764 lines, 5.9 MB (18 warn, 0 error) | 2026-11-11 20:29Z to 2026-11-15 11:05Z | the fork builds installed with 0.2.1 and 0.3.0-rc.2 (final6.14 since 11-14) | grouped by message; every non-OK call |
| Saved logs in the repo, `docs/evidence/**` and `scripts/e2e/**`, `.log` + `.txt` | 807 files (the plan said 660; it has grown) | 2026-10-22 to 2026-11-14 | 0.1.0 to 0.3.0-rc.2, lab builds | app-format lines, service-format lines, harness `FAIL` lines, printed `Error:` sentences |
| Handoff Q rows | `memory/handoff-devnet-dvpn.md` STATE and dated entries | | | used for the status column |

Working copies and the grouped tables are on the control box in `~/ddv31-ui-engine/` (`out/laptop/groups.tsv`,
`out/laptop/screens.tsv`, `out/laptop/applog2.txt`, `out/saved/groups.tsv`); the scripts are `logpass.mjs` and
`applog2.mjs` there. The copies of the two laptop logs are deleted when the pass is closed. The app already
redacts the Solana endpoint key in its log (`?<redacted>`); the copies were checked for a key and hold none.

Not yet read (they are not in this repo): the VM and device logs pulled for #32, #33 and #34. See "Not done".

## A. The laptop app log

Counts are whole-log totals. "rc.2" is the count since the 0.3.0-rc.2 start on 2026-11-14, about 22 hours
of use, because that is the only build whose behaviour still matters.

### A1. The link to the VPN service

| # | Log line | Count (rc.2) | First to last | What the user saw | Cause | Status | Row |
|---|---|---|---|---|---|---|---|
| L01 | `could not list daemon sessions` · "The VPN service is not running." | 704 (13) | 10-20 to 11-15 | "The VPN service is not running" for the whole outage (table A4): 4 h on 10-20, 11 min on 11-04, about 3.3 h in pieces on 11-11, 85 s on 11-14 | The service was not installed, stopped or still starting. One sentence covers all of them (`core/daemon/link-copy.ts:11`), and the app retries with a delay that doubles to 30 s (`main/daemon/manager.ts:151,225`) | OPEN | 119, 121 |
| L02 | The same line twice, 2 ms apart | 330 pairs (6) | 11-11 to 11-14 | nothing extra; the log doubles | Two readers react to one link change. On 11-11 an installed 0.2.1 and a dev run also wrote the same file, so that day's 323 overstates it; the 6 pairs on rc.2 are one process (pid 20756). Suspected pair: the start-up listener `main/index.ts:183` and a second `adoptRunningSession` caller on the same change. To be traced in row 122 | OPEN | 122 |
| L03 | `pipe-bridge exited` code 1, with `pipe-bridge` "…\sentinel-dvpn\c0: The system cannot find the file specified." (358) or the same on the pre-cb33 pipe name (34) | 406 exits (7) | 10-20 to 11-14 | same as L01 | The service's pipe does not exist, so the helper exits and is started again on the doubling delay. One warning pair per attempt, for hours | OPEN | 119, 121, 139 |
| L04 | `pipe-bridge` "Access is denied." (16) and `could not list daemon sessions` · "This app is not allowed to talk to the VPN service yet. Sign out of Windows and sign back in once…" (19) | 35 (0) | 11-11 only | Told to sign out of Windows, right after setup, while the service was coming up | The account had just been added to the service's pipe group; Windows applies that at sign-in. The sentence was also shown while the service was simply not up yet | IN CODE, UNPROVEN: one administrator step grants the pipe without a sign-out (`connection.ts:271`, `grant-pipe.ps1`), and the copy now says "Press Connect to finish setup". The rule "only when the service is proven running" is not in code | 127 |
| L05 | `could not list daemon sessions` with "could not be reached" (3), "did not answer in time" (2), `ListSessions: Connection dropped` (5), `Deadline exceeded` (1); `daemon heartbeat lost` (2); `daemon attach failed` (4) | 17 (0) | 10-22 to 11-11 | "The VPN service could not be reached" or "did not answer in time" for a few seconds during a service restart | Three watchers (session stream, heartbeat, poll) each decide on their own clock, and one text field holds the last writer's message | OPEN | 135, 136 |
| L06 | `daemon config not readable as this user` · EPERM on `config.toml` | 88 (0) | 87 on 11-11 (0.2.1), 1 on 10-20 | Kill switch, Split tunnelling and Settings could show values the service was not using | On 0.2.1 the installed `config.toml` was readable by administrators only. Not seen once on rc.2 | IN CODE, UNPROVEN (zero on rc.2 in one day is not a proof). Saying "unknown" when it cannot be read is still open | 133 |
| L07 | `restore network: daemon did not answer` | 3 (0) | 11-04, 13 s apart | Restore network pressed three times, nothing changed | 0.1.0 had no service start on this path | IN CODE, UNPROVEN: a stopped service is started and the press retried, otherwise one sentence is returned (`connection.ts:1321-1326`). Needs the VM run "Restore network with the service down" | 123 |
| L08 | `auto refund skipped: the VPN service did not list its sessions` | 1 (1) | 11-14 13:21 | nothing | Start-up while the service was down | NOT A DEFECT, but it should be one state-change line, not a warning | 139 |
| L09 | Last four lines of the log: `pipe-bridge exited` code 0, `service transition` "the service stopped answering", `screen` service "restarting", `could not list daemon sessions` | 1 (1) | 11-15 11:57:59 | If the window was still up: the "restarting" banner for a moment | INFERRED: the app was closing (the helper exits with 0 when its input closes, `manager.ts:300`), and the close path still logs a warning, starts a service transition and reads the session list. The service log has no stop at that time | OPEN | NEW-1 |
| L10 | `daemon attached` twice, 5 s apart, after the service came up | 1 pair (1) | 11-14 13:22:32 and :37 | nothing | A relink after the administrator step and a waiting retry both attach | OPEN, minor | 122 |

### A2. Setup and the administrator step

| # | Log line | Count (rc.2) | First to last | What the user saw | Cause | Status | Row |
|---|---|---|---|---|---|---|---|
| L11 | `device setup failed` · "[object Object]" | 5 (0) | 11-11 17:53 to 18:41 | A failure whose reason read "[object Object]" | An object was thrown where an Error was expected (token approval on the wrong token program) | FIXED, TESTED: `core/chain/errors.ts:107` `errorText`, `tests/unit/first-connect-permission.test.ts` ("error text is never [object Object]"). The wider guard (no message anywhere can carry it) is still to add | 128 |
| L12 | `device setup failed` · "The fee payer has no SOL" | 1 (0) | 10-21 | The raw sentence | Wallet had no SOL | IN CODE, UNPROVEN: checked before signing, with the amount (`services/wallet.ts:102`) | 82 |
| L13 | `elevated step returned an error` · `setup-daemon.ps1` "else : The term 'else' is not recognized…" | 1 (0) | 11-11 19:57 | A failed setup | A dev run from the working tree (0.2.1 dev) used a script that did not parse | OTHER OWNER (connect-de owns `resources/scripts`): confirm the shipped script parses and add a parse test for every `.ps1`, run on the VM | 129 |
| L14 | `device permission at first connect failed` · "the app folder …\resources\bin can be changed by S-1-5-21-…; reinstall the app into Program Files" | 1 (0) | 11-11 19:57 | "Could not set up this computer to pay nodes: the app folder … can be changed by S-1-5-21-…" | Same dev run: the folder check is right for an unpackaged tree, but a raw account id reaches the screen | OPEN, low | NEW-2 |
| L15 | `child process gone` · Network Service, killed | 1 (0) | 11-04 22:57 | unknown | Electron's network helper was killed (the log does not say by what; app restarted next) | OPEN: find out whether the app recovers by itself | NEW-3 |

### A3. Solana reads, money, connect

| # | Log line | Count (rc.2) | First to last | What the user saw | Cause | Status | Row |
|---|---|---|---|---|---|---|---|
| L16 | `connect failed` code `daemon-unavailable` · "StartSession: unavailable: the network is unreachable or busy right now" | 2 (0) | 11-11 21:19, 21:23 | "The VPN service is not running" + "Open diagnostics", for a Solana rate limit | `core/session/state.ts:261` treats any text with "unavailable" as a stopped service. The retry rule learned the phrase on 11-12 (`connection.ts:102`), the copy rule did not | OPEN | 124 |
| L17 | `connect failed` code `rpc-busy` · "…getAccountInfo() on <keyed endpoint> status code: 429. could not decode body…" | 3 (0) | 10-21 | "rate-limiting, wait a minute" although the endpoint was out of credit | The service's endpoint had run out | IN CODE, UNPROVEN: `state.ts:256` says the endpoint is out of credit and points to Settings | 131 |
| L18 | `connect failed` code `unknown` · "verifying metadata signature: invalid signature" | 2 (0) | 10-21 | "Something went wrong. Retry." | Server's signed details did not verify | IN CODE, UNPROVEN: `state.ts:224` "This server failed its identity check… Nothing was paid." Final words in the wording pass | 130 |
| L19 | `chain read retrying during connect` · "429 Too Many Requests: max usage reached" (20) or the public endpoint's 429 (5) | 25 (6) | 11-11 to 11-15 | "Checking… Waiting for the Solana network to answer…" | The app's own keyed Solana endpoint is out of credit, so every read fails once and falls to the public endpoint. The app never says the endpoint has run out; the plain sentence exists only for the service's endpoint | OPEN | 131, NEW-4 |
| L20 | `rpc busy while starting a new deposit` | 3 (0) | 11-11 | long "Paying deposit…" | Rate limit while the deposit was being opened; retried | NOT A DEFECT (retry works); the wait text is row 2 | 2 |
| L21 | `scheduler: settlements failed` (15), `wallet refresh failed` (9), `node refresh failed` / `scheduler: nodes failed` (2) · "all RPC endpoints failed…" | 26 (1) | 10-21 to 11-15 | Nothing. Balances, refunds and the server list silently stayed old | Rate limits and the out-of-credit endpoint | OPEN | 140 |
| L22 | `no data from the node yet; reporting connected anyway` | 3 (0) | 10-21 | "Protected" before any data had come back | 8 s wait for the first bytes, then connected regardless (`services/first-data.ts:34`). rc.2 has a "Checking the connection…" stage after it; whether that stage holds when no data arrives is not established | OPEN | 132 |
| L23 | `flushing the DNS cache failed` · "Command failed: ipconfig.exe /flushdns" | 36 (8) | 11-11 to 11-15 | nothing | On rc.2 it fails on every connect and every disconnect (8 of 8). The reason is not in the log: the error text carries no output | OPEN: capture the exit code and output, then fix or drop the call | 134 |
| L24 | `prepay above the service cap; dvpnd will use the cap` | 1 (0) | 11-11 23:34 | The sheet named one amount, the service used its cap | Deposit block above the service's limit | OPEN: check that the amount on screen is the amount paid | NEW-5 (money path) |
| L25 | `the VPN service is running but did not list its sessions: not offering Restore network` (1), `no session but a VPN tunnel is still running: offering Restore network` (1) | 2 (0) | 11-11 23:34 | The "kill switch flashing" false alarm | An Apply restart read as a leftover block | PROVING under Q0518, Q0520-Q0523 (fix 42f8f49, `service-transition.ts`) | - |

### A4. Service outages seen by the app (first failed line to the next attach)

| Start (UTC) | Length | Lines logged | Build | What ended it |
|---|---|---|---|---|
| 10-20 11:33 | 4 h 12 min | 8 | 0.1.0 dev | service installed |
| 11-04 22:15 | 11 min | 57 | 0.1.0 | attach; Restore network pressed 3 times meanwhile (L07) |
| 11-11 17:47 to 21:02 | ten stretches, 13 s to 72 min, about 3.3 h in all | 1,035 | 0.2.1 and a dev run | app restarts and re-installs during the 0.2.1 set-up |
| 11-11 23:34 | 24 s | 12 | 0.2.1 | attach after an Apply restart |
| 11-14 13:21 | 85 s | 18 | 0.3.0-rc.2 | administrator step (the update had left the service stopped, Q0576) |

On 11-14 the retries ran at 0, 2, 6, 14, 30 and 60 s after the start: the doubling delay. That is the
"keeps saying not running for up to half a minute" of row 121.

### A5. On-screen text recorded by the screen journal (rc.2 only, 37 screen lines, 5 toasts)

| Shown | Times | Note | Row |
|---|---|---|---|
| "Protected" | 8 | | |
| "Not connected" | 6 | | |
| "Disconnecting…" | 6 | logged twice per disconnect (before and after the close message) | 12 |
| "Reconnecting… traffic is going direct (kill switch is off)" + "The daemon is retrying the connection." | 5 | each shown for 0.1 to 1.4 s, then "Protected" again (L26) | 17, 47, NEW-6 |
| "Checking…" + one of: "Checking the server and your balance…" (3), "Waiting for the Solana network to answer…" (2), "Raising this computer's spending limit…" (1), "Setting up this computer to pay nodes…" (1), "Getting the deposit ready…" (1) | 8 | up to five detail texts under one title in a single connect (11-15 09:49:51 to 09:50:04) | 2, 48 |
| "Paying deposit…" + "Paying deposit 50 tDVPN…" | 3 | | 2 |
| "Checking the connection…" + "Making sure your traffic passes through the server before calling it protected." | 1 | shown for 130 ms | 2, 53 |
| toast "Connected" | 3 | while the Connect screen showed it | 33 |
| toast "The device spending limit is almost used up. Raise it in Wallet." | 1 | 3 s after connecting | 72 |
| toast "3 refund steps confirmed." | 1 | | 68 |

| # | Finding | Count | What the user saw | Cause | Status | Row |
|---|---|---|---|---|---|---|
| L26 | `stream: connected -> reconnecting` | 137 in one 75-minute V2Ray session on 11-15; 132 came back inside the grace and were hidden, 5 were shown | "Reconnecting… traffic is going direct" flashing for about a second, five times | The service reports "connection lost; reconnecting" on the session stream about every 30 s and recovers within 200 ms. Its own log has no line for any of them | SERVICE for the cause (why the stream flaps and logs nothing); OPEN in the app for the minimum display time | 17, NEW-6 |
| L27 | `plan provider not answering` (info) | 387: 188 for a provider whose listed address is `127.0.0.1:9443`, 179 for one on a server that no longer exists, 20 others | Plans whose server list cannot be shown | Every provider is asked again every 10 minutes for good, including an address that can only ever be this computer | OPEN: back off, and do not call a loopback address from a listing. File `main/services/plans.ts` has no owner in `docs/UI-FLEET.md`; sent to UI-LEAD | 139, NEW-7 |

## B. The laptop service log

| # | Log line | Count | First to last | Effect | Status | Row |
|---|---|---|---|---|---|---|
| S01 | "from tcp:<address> accepted tcp:<address>:<port> [tun -> session]" (and udp) | more than 4,900 lines, most of the 5.9 MB | 11-12 to 11-15 | **The service log on disk records the address and port of every connection the user makes through a V2Ray or Xray session.** This is the helper's access log passed through at info level. A VPN should not keep this. The file is readable by any account on the computer. The app itself never reads or exports this file: Diagnostics "Load" and `devnet-dvpn logs` show the last 300 lines of the app's own log only (`main/logger.ts:92`, `main/ipc.ts:167`), which holds no such line (checked: 0 in 2,833). The risk is the file on disk, and a user who is asked for "the log" and sends this one by hand | SERVICE, high: turn the access log off in the V2Ray/Xray configuration the service writes (`tun-helper.json`). An app-only stopgap exists (`[log] level = 'warn'` in the service's `config.toml`) but it also drops the lines the VM proofs read, so it is not taken. Text for `docs/UPSTREAM-GAPS.md` sent to its owner | UI-173 |
| S02 | `session guard not fully applied` · "hysteria2 inbound permit: finding interface dvpn-hy2-client: … no such network interface (waited for the adapter: context deadline exceeded)" | 7 | 11-12 | The Hysteria2 session ran without its inbound rule | SERVICE, already filed (the owner's laptop findings, among Q0524-Q0530) | - |
| S03 | `StartSession` → FailedPrecondition (3), Unavailable (2) · "Connection rate limits exceeded" | 5 | 11-12 | L16 | see L16 | 124 |
| S04 | `sing-tun firewall rule left`, `removing a tunnel an earlier stop left; the next start retries it` · "A system shutdown is in progress" | 2 | 11-12 | none: Windows was shutting down; the next start clears them | NOT A DEFECT | - |
| S05 | `worker failed` · close_channels, public endpoint timed out | 1 | 11-13 | a refund sweep skipped once | NOT A DEFECT (next sweep runs) | - |
| S06 | Hysteria2 "TUN TCP error" / "TUN UDP error" at WARN inside info lines | 6 | 11-12 | unknown | SERVICE: read the six lines with the fork owner | NEW-9 |
| S07 | "started call" / "finished call" for every app poll: ListSessions 3,414, GetVersion 1,556, ListChannels 304 | about 10,500 lines | 11-12 to 11-15 | The log is two thirds poll noise, which hides real events | SERVICE: log polls at debug. The app side (one poll, state-change logging) is rows 122 and 139 | 139 |

No error-level line, no panic and no crash in the service log. Sessions ended: 12 "stopped by user", 1
"credit exhausted", 1 "daemon stopping".

## C. The saved logs in the repo (807 files)

Only a handful hold app-format lines; most are harness output. Counts by kind:

| Kind | Distinct | Lines | Where |
|---|---|---|---|
| App warnings | 47 | 277 | mostly `windows-rc-arm64/matrix`, `windows-rc3-arm64/swcu-awg`, `windows-rc2/harness` |
| App errors | 5 | 7 | `connect failed` (5), `settlement failed` (1) and one more |
| Harness `FAIL` lines | 398 | 561 | 14 folders; `windows-rc-arm64` 142, `windows-rc` 134, `2026-10-24` 64, `windows-rc-x64` 61 |
| Service lines | 2 | 3 | `StopSession → NotFound` (2) |

### C1. App warnings and errors in the saved logs

| # | Log line | Count (files) | Dates | Cause | Status | Row |
|---|---|---|---|---|---|---|
| V01 | `pipe-bridge exited` code 1 | 103 (7) | 10-25 to 10-29 | kill-switch and restart tests stop the service on purpose | same as L03 | 119, 139 |
| V02 | `[rpc] benched <endpoint> for <n>s: …` 429 or fetch failed | 137 in 33 variants (3) | 10-25 to 10-29 | public endpoint rate limit on the test VMs; the endpoint is rested and retried | NOT A DEFECT, but one line per read is noise: one line per rest period | 139 |
| V03 | `watch stream ended; polling instead` | 16 (7) | 10-25 to 10-29 | service restarted under test | NOT A DEFECT | 135 |
| V04 | `connect failed` · "node settled exceeds the recorded sessions" | 3 (1) | 10-26 | server's ledger ahead of the device's | IN CODE: `state.ts:229` plain sentence | - |
| V05 | `connect failed` · "a session is already active" + `connect failed and left a tunnel service running` | 2 (1) | 10-28 | switch test on rc2 | IN CODE (`link-copy.ts:33`); the leftover tunnel was Q0265/Q0273 | - |
| V06 | `settlement failed` / `[tx] queued write failed` · "BalanceZero: balance to withdraw is zero" | 2 (1) | 10-29 | double-settle test: the second withdraw has nothing to take | OPEN: an empty withdraw should be skipped, not sent and logged as an error | 84, NEW-10 (money path) |
| V07 | `connect failed` · "owner:sol: all RPC endpoints failed…" / "node:… timed out" | 2 (2) | 10-29 | every endpoint down during the fault test | IN CODE: "The Solana network endpoint could not be reached…" | 131 |
| V08 | `wallet refresh failed`, `status: channel read failed`, `cli command failed on every RPC endpoint` | 9 (3) | 10-25 to 10-29 | same faults | same as L21 | 140 |
| V09 | `system proxy: found our own SOCKS proxy left on…`, `…was on with no backup; set to direct` | 2 (1) | 10-31 | proxy left by a killed run | NOT A DEFECT (self-repair, Q0281) | - |
| V10 | `session id gone (dvpnd reconnected); stopping the current session` | 1 (1) | 10-29 | clock-change test | NOT A DEFECT | - |
| V11 | `[dns-pin] api.devnet.solana.com: ENOENT; using the saved addresses` | 2 (1) | 10-29 | DNS down under test | NOT A DEFECT | - |
| V12 | `post-timeout verification failed` · "Error: x" | 1 (1) | 10-31 | a lab build's injected fault | NOT A DEFECT | - |

### C2. Error sentences the app or the CLI printed in the saved logs

Each was matched against the current code only where a plan row depends on it.

| Sentence | Times | Status | Row |
|---|---|---|---|
| "The Solana network endpoint could not be reached. Check your internet connection and try again." | 25 | NOT A DEFECT (fault tests) | - |
| "Invalid public key input" | 12 | OPEN: a library sentence for a mistyped address reaches the user | NEW-11 |
| "Unexpected token '<', …" | 6 | IN CODE, UNPROVEN: later builds print "…did not answer like a Solana RPC endpoint" (9 times in later logs); the harness cell that failed on it was `edge-rpc-garbage` | 84 |
| "The VPN service is not running." → Open diagnostics | 4 | OPEN | 119, 125 |
| "The VPN service is not answering. Restart Windows, then press Restore network again." | 7 | OPEN: tells the user to restart Windows | 123 |
| "Something went wrong. Retry." → Retry | 3 | OPEN | 52 |
| "The administrator step took too long and the VPN service is not running. Try again; …" | 2 | IN CODE (`manager.ts:495` checks the service before saying so) | 119 |
| "System error 1378 has occurred." | 1 | fixed in 0.2.1 (d92ed1e) | - |
| Refusals that are correct and plain (wrong value for a setting, wallet already set up, key-file wallet is read-only, "Disconnect the current session first.", "Finish device setup first.", spending limit lower than the deposit, port in use, tunnel did not come up, server billed more than measured, no SOCKS endpoint, recovery phrase not valid, Chrome not installed) | 95 | NOT A DEFECT; wording goes through the glossary pass | 44-57 |

### C3. Harness FAIL lines

561 `FAIL` lines (398 distinct) from test runs on builds 0.1.0 to 0.1.3 and lab builds, 2026-10-22 to
2026-11-07. They are test verdicts, not app log lines, and each belongs to a Q row in the queue; they were
grouped (`out/saved/groups.tsv`) but **not re-judged one by one in this pass**. The groups that say
something about the app's own messages:

| Group | Lines | Row |
|---|---|---|
| "no UI errors" failed because the banner "Only the public devnet RPC is configured. It rate-limits real use; add your own endpoint in Settings." was on screen | 30 | 131 |
| "design rubric clean on every screen" | 40 | 58-67 |
| "plain message (no stack, no URL, no raw dump)" failed on an endpoint that answered HTML | 10 | 84 |
| "no error-level app.log line" failed on `settlement partly failed … ChannelNotOpen` | 4 | 84 |
| `egress=direct` empty right after Disconnect | 12 | known (W7 in fleet-bugs) |
| `CLI status` "Connected, but traffic is not going through the VPN" after a fault | 5 | 132 |

## D. New rows from this pass

Filed by UI-LEAD in `docs/UI-AUDIT.md` as UI-166 to UI-176, in this order (NEW-1 = UI-166 … NEW-11 = UI-176).
`src/main/services/plans.ts` (NEW-7) is UI-ENGINE's file from 2026-11-15.

| Id | What | Owner |
|---|---|---|
| NEW-1 | Closing the app logs a warning, starts a "service restarting" transition and reads the session list (L09) | UI-ENGINE |
| NEW-2 | A raw Windows account id (S-1-5-…) in the first-connect failure text (L14) | UI-ENGINE |
| NEW-3 | Electron's network helper killed once; does the app recover without a restart (L15) | UI-ENGINE |
| NEW-4 | The app's own Solana endpoint out of credit is never said; only the service's is (L19) | UI-ENGINE (`core/chain`), screen text UI-LEAD |
| NEW-5 | Deposit amount on screen against the service's cap (L24) | UI-ENGINE (money path) |
| NEW-6 | 137 one-second "reconnecting" reports in 75 minutes with nothing in the service log (L26) | fork owner for the cause; UI-LEAD for the display time |
| NEW-7 | Dead providers and a loopback address probed every 10 minutes for good (L27) | file owner to be named by UI-LEAD |
| NEW-8 | The service log records every destination on V2Ray and Xray sessions (S01) | fork owner; UPSTREAM-GAPS |
| NEW-9 | Hysteria2 TUN errors hidden at info level (S06) | fork owner |
| NEW-10 | A withdraw with nothing to take is sent and logged as an error (V06) | UI-ENGINE (money path) |
| NEW-11 | "Invalid public key input" for a mistyped address (C2) | connect-64 (`src/cli`) if it is CLI-only; to be traced |

## E. The guard for later builds

The VM walk ends with a log check that fails the run on any warning or error not on this list. Starting
allow-list (lines marked NOT A DEFECT above), to be reviewed when the service-state rows land:

- `[rpc] benched …` (once per rest period after row 139)
- `watch stream ended; polling instead`
- `rpc busy while starting a new deposit`, `rpc busy while starting; retrying`
- `system proxy: found our own SOCKS proxy left on…`, `…was on with no backup; set to direct`
- `session id gone (dvpnd reconnected); stopping the current session`
- `[dns-pin] …; using the saved addresses`

Everything else that is a warning or an error fails the walk.

## Not done in this pass

- The VM and device logs kept by #32, #33 and #34 in their own repos and on the control box were not read.
  Row 142 (the same states on macOS, Linux and Android) needs them.
- The 398 distinct harness FAIL groups were counted and grouped, not re-judged against their Q rows.
- Timelines that pair each failed connect with the screen journal exist only for rc.2 (the journal did not
  exist before it); there were no failed connects on rc.2 in this log.
- Nothing here has been proven on a VM. Every status is from reading the logs and the code.
