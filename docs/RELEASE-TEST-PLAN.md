# Devnet dVPN — mega plan: every function × every protocol, release-proof (app + CLI)

## Master queue (every pending task, in execution order; tick in the handoff STATE as done)
Running work is not disturbed: R3 persist is on the VM now and finishes first.
1. **R3** persist test (running) → record result; fix any bug.
2. **R4** full CLI sweep `vm-cli-sweep.ps1` on the current VM (find bugs early); fix each.
3. **Phase P** protocol parity: P1 matrix doc → P2 `vm-matrix.ps1` + baseline run → P3 fixes in
   the P5 order (kill switch WG/AWG/OVPN; persistent filters + job object; DNS NRPT; per-app
   split for all six; per-destination split; V2Ray/Xray full device; IPv6, MTU, adapter, fw
   rule) → app + CLI options for each (remove refusals) → matrix all green on the current VM.
4. **K1 / Phase 5b build items**: F16.2 browser launcher (app + `proxy browser`), in-app scenario
   driver `DVPN_UI_SCENARIO`, `vm-split-test.ps1`, Edge/Chrome/Firefox on the VMs.
5. **Phase 2** RC build gate on the laptop (no tunnels) → installer to the bucket.
6. **R11** settle every channel on the current VM wallet (stream now, voucher after grace), then
   delete `ddv-win-2`.
7. **Phase 3** fresh `ddv-win-a` (clean) + `ddv-win-b` (dirty), fingerprints (`vm-fingerprint.ps1`).
8. **Phase 4** installer I1–I9 (`vm-installer-test.ps1` install / repair / offline / dirty-setup /
   dirty-check / uninstall; fingerprint diff = only ours).
9. **Phase 5 + 5b** on fresh A (and B): full matrix by both drivers, CLI sweep, all 7 safety
   tests, kill switch matrix, split with real apps, in-app how-to followed literally; **Q12**
   live node-test run on the six nodes; **R8/R9** test runs + plans path.
10. **Phase 6** crash watch + `vm-soak.ps1` 2 h + fault injection.
11. **Phase 9** edge research → EDGE-MATRIX → `vm-edge.ps1` cases (clumsy, suspend/resume,
    reboots, IPv6, node faults, RPC faults, billing accuracy, races, odd machines, fuzz) → bug loop.
12. **R12** OpenVPN MTU confirmed green in the matrix (cause known; #28 patching).
13. **Phase 7** visual: ui-smoke sizes × DPI × themes × states, axe, overflow, aesthetic pass,
    screenshot gallery artifact.
14. **Phase 8** gate (tests only, evidence), settle, revoke, funds back to 9enW4x, delete VMs +
    bucket, tell agents "rig free" (#1b and #28 are waiting for it); `ddv-node-1` stays.
15. **Phase 10 LAST**: E1–E6 error standards, L1 plain language, D1 standards docs, D2
    STANDARDS-COMPARISON, D3 docs audit (PROTOCOL-MATRIX, UPSTREAM-GAPS #1–#32+, TEST-PLAN,
    STANDARDS-TRACE, BOX-RIG runbooks, **R13** docs), U1 UPSTREAM-PR-CANDIDATES (proposal only).
Bugs found anywhere: fix at once + regression test/cell, rerun neighbours; docs batched to 15.

## Context
Owner (2026-10-21): on top of the current queue, a very strong plan to test **everything**:
wipe the VM and put the installer on it fresh, prove the installer works flawlessly, every CLI
function works, dependencies install automatically on fresh systems, every design standard is
met with an aesthetic pass, no crashes or errors, stringent end to end. #31 has **priority on the
GCP rig**; any other agent that needs a VM spins up its own temporary one.

What exists (reuse, don't rewrite):
- `scripts/e2e/vm-installer-test.ps1` (install/uninstall phases, SHA check), `vm-safety-test.ps1`
  (drivers/protocols/dns/killswitch/killdaemon/persist/armed), `vm-cli-sweep.ps1` (every catalogue
  command, refusals, settings, wallet sandbox, per-GB x6, proxy, --switch, top-up, --follow),
  `vm-run.ps1 -Test X [-Script Y]` (SYSTEM task, survives SSH drops), `settings-e2e.sh` (local),
  `cli-e2e.sh` (local 38/38), ui-smoke (`DVPN_UI_SMOKE=<dir>` all screens + `errors.json`).
- Installer: `build/installer.nsh` + `resources/scripts/install-deps.ps1` with pinned
  `build/deps.lock.json` (WireGuard 1.1.1, AmneziaWG 3.1.0, OpenVPN 2.6), uninstall cleanup.
- Scratchpad helpers: `vm.sh`, `vm-put.sh` (chunked base64 upload; stdin uploads hang), `vm-wait.sh`.
- Coverage tests: cli-map, settings-coverage (CLI + UI control for every option).

Hard constraints (unchanged): no subagents; laptop never runs tunnels or kill switch; GCP
project `ddv-node-test-5821` only (never `bulla-c8a0d`); keep `ddv-node-1` up; 7 s between chain
txs; devnet key file never copied; PowerShell scripts ASCII; commit as the bot on `main`.
**Superseded:** project `ddv-node-test-5821` is RETIRED by owner order (never start or log in
there). GCP work now runs in the project and under the rules in `~/memory/gcp-account.md`; the
Mac host is `ddv-mac-host-dv` (see `CLAUDE.md`). This plan's other project/VM names are history.
GCP has no consumer Windows 11 image: the fresh-system targets are **Windows Server 2022
Desktop Experience** (same networking stack); the laptop (Win 11 Home) gets UI-only checks.

## Order of work (owner 2026-10-21: test everything first, ALL docs and copy work at the end)
Done: P0 notice, S1–S8, R1, R2 (gap #32 found, fixed app-side, rerun green except the upstream
part). Now, strictly in order:
R3 persist (running) → R4 CLI sweep on the current VM → **Phase P protocol parity (below):
build the matrix runner, fix every red cell** → Phase 2 RC → Phase 3 fresh VMs → Phase 4
installer → Phase 5 CLI + Phase 5b kill switch / split (both = matrix runs on the fresh VM) →
Phase 6 crashes/soak → Phase 9 edge matrix → Phase 7 visual → Phase 8 gate (tests only) →
**Phase 10 LAST: E1–E6 error-message standards, L1 plain language, D1–D3 docs, U1 upstream PRs**
(E3 draft docs/ERROR-STANDARDS.md + src/core/app/copy-rules.ts exist; E5 test and all fixes wait).
Bugs found on the way are fixed at once (code + regression test); their docs are batched into Phase 10.

## Phase P — Every function works on every protocol (owner 2026-10-21, top priority)
"Every single function has to work perfectly on every single protocol." Until now a broken
cell was answered with a refusal ("kill switch on is refused for WireGuard on Windows",
"split tunnel is V2Ray/Xray only"). **That is no longer an acceptable end state: a refusal is a
red cell.** The release gate needs the whole matrix green, in the app AND the CLI.

**P1 Matrix** `docs/PROTOCOL-MATRIX.md`: rows = every function, columns = WireGuard, AmneziaWG,
OpenVPN, Hysteria2, V2Ray, Xray. Rows: connect per-GB / per-hour / via plan; disconnect;
`--switch` (to each other protocol); top-up mid-session; auto-connect at start; reconnect after
NIC change, sleep/resume, service restart, reboot; kill switch off / on / persist; every DNS
preset + custom; allow LAN on/off; **split tunnel: full device, per-app, per-destination**;
system proxy; browser through VPN; IPv4 + IPv6 (no leak); MTU/throughput (no stall); live
stats / bytes / spend vs node meter; every close reason; settle + refund; node test run;
quality checks; restore network; crash / dvpnd death recovery; uninstall cleanup.
Each cell: the 4 oracles (network, money, message, health) from Phase 9.2, run by both drivers.

**P2 Runner** `scripts/e2e/vm-matrix.ps1 -Protocol X -Function Y|all` (via `vm-run.ps1`), reusing
the helpers in `vm-safety-test.ps1` / `vm-cli-sweep.ps1`; writes `matrix.json` (cell → PASS/FAIL +
evidence). The app driver (`DVPN_UI_SCENARIO`, Phase 5b) runs the same cell ids. First full
run on the current VM gives the baseline red list.

**P3 Known red cells and how each becomes green** (fix at the source, never a refusal):
| Cell | Today | Fix |
|---|---|---|
| Kill switch on/persist × WireGuard | refused (gap #29: WFP applied before the adapter exists, tunnel left up → offline) | dvpnd: create the tunnel first, then permit it by adapter LUID + endpoint, then block; on failure tear the tunnel down |
| Kill switch on/persist × AmneziaWG, OpenVPN | refused (connect, no egress) | dvpnd: permit the AmneziaWG / OpenVPN Wintun adapter and the openvpn.exe process; regression cell |
| Kill switch survives dvpnd death (all) | filters die with dvpnd (gaps #5, #32) | dvpnd: persistent WFP filters (session object only for "off on exit"), protocol children in a job object with KILL_ON_JOB_CLOSE, reap previous children on start |
| Split per-app × WG, AWG, OpenVPN, Hy2 | not offered (full tunnel only, D7) | proxy mode per protocol: WG/AWG `Table = off` + OpenVPN `route-nopull` (tunnel up, no default route) + a local SOCKS5 bound to the tunnel address; Hy2 native `socks5` client mode. Same proxy UI/CLI as V2Ray/Xray |
| Split per-destination × all | not offered (gap #1) | WG/AWG `AllowedIPs` from the user's list; OpenVPN `route` lines; Hy2/V2Ray/Xray: routing rules (direct vs proxy) in their client config |
| Full device × V2Ray, Xray | proxy-only | tun2socks (Wintun) in front of the SOCKS inbound, or Xray TUN inbound; then kill switch on works like the others |
| Kill switch + split (all) | needs kill switch off (gaps #6, #19) | defined: chosen apps fail closed (proxy/routes only through the tunnel), other apps direct; the kill switch blocks the chosen apps' direct path |
| DNS × all, kill switch off | leaks to the adapter's resolver (gap #30) | NRPT rule `.` → tunnel DNS for the session, removed on stop (dvpnd, elevated) |
| IPv6 × Hy2 | tunnel claims ::/0 with no node IPv6 (gap #28) | dvpnd writes IPv6 only if the node has it; else block IPv6 off-tunnel |
| OpenVPN throughput | stalls at MTU (no mssfix) | `mssfix` / `tun-mtu` in the client config (#28 is adding the case) |
| AWG then OpenVPN | AWG deletes the OpenVPN Wintun adapter (gap #27) | dvpnd recreates the adapter before an OpenVPN session; app `repair-drivers` as fallback |
| Hy2 firewall rule left (gap #31) | removed at uninstall only | dvpnd/hysteria2 config without the sing-tun firewall rule, or removed on stop |

**P4 Where the fixes live.** dvpnd + sentinel-go-sdk changes are made in #28's tree
(`Desktop/sentinel-solana/upstream`), coordinated with the #28 session that owns it. Each
change is a local commit there, built into our bundled `dvpnd.exe` (`build/deps.lock.json`
records the build id). Never vendored into this repo; never pushed upstream without per-change
owner approval (U1 collects them). App-side work: remove the refusals (`killSwitchBlocksProtocol`
in `src/core/session/state.ts`, D7 copy) as each cell goes green; split mode picker for every
protocol in Settings + connect (`src/main/system/proxy.ts`, Settings.tsx, CLI `proxy` / `connect
--split per-app|per-destination|off [--routes ...]`); F16.2 browser launcher; settings-coverage
test extended so every new option has a CLI path and a UI control.

**P5 Order inside P:** runner + baseline → kill switch WG/AWG/OVPN → dvpnd death/persistent
filters → DNS NRPT → per-app proxy mode for full-tunnel protocols → per-destination → V2Ray/Xray
full device → IPv6 / MTU / adapter fixes → full matrix rerun green on the current VM, then
again on the fresh VMs in Phases 4–5b.

## Phase 0 — Coordination (first action)
Message every live session (`ListAgents`): #31 has priority on project `ddv-node-test-5821`
VMs `ddv-*` and the six nodes on `ddv-node-1` until the release gate; others create their own
temporary VMs (`bw28-*`, `n1b-*`…) in their own projects or with their own names, never touch
`ddv-*`, and ask before any session on the six nodes (my tests are timed and count peers).

## Phase 1 — Finish the current queue items that change the build
S7 settings-e2e (ran: 109/110 — bug: `nodes fav <bad address>` prints "Added to favourites"
while the sanitizer silently drops it; fix = validate before saving, exit 1, test row) · S8 docs/ui-smoke · R2 killdaemon · R3 persist on the current VM ·
E1–E6 error standards (research → ERROR-STANDARDS.md → fixes → tests). The release-candidate
installer is built **after** E4 so the fresh-VM proof covers the final copy.

## Phase 2 — Release-candidate build gate (laptop, no tunnels)
`npm run typecheck`, all unit tests, cli-map/settings-coverage, `cli-e2e.sh`, `settings-e2e.sh`,
`poll watch`, ui-smoke both themes `errors.json == []`, mojibake grep, files ≤500 lines,
`npm run release:win` → SHA256SUMS → bucket. Tag the build id in the handoff.

## Phase 3 — Wipe: brand-new VMs from stock images
Delete `ddv-win-2` after R11 settle. Create **fresh** VMs (stock `windows-2022` image, nothing
pre-installed, new SSH key setup via `vm-startup.ps1`):
- `ddv-win-a` — main clean-install target (all tests below).
- `ddv-win-b` — dirty-machine target: pre-install the user's own WireGuard + an own tunnel
  `home-office`, an older OpenVPN, a set system proxy, a custom DNS — proves we touch none of it.
Record "before" fingerprint on each: services, drivers/adapters (`pnputil`, tapctl), WFP
sublayers, firewall rules, PATH, HKCU proxy, DNS per adapter, installed programs.

## Phase 4 — Installer proof (fresh + dirty, every path)
| # | Case | Pass when |
|---|---|---|
| I1 | Silent install `/S` on clean A | exit 0; WireGuard, AmneziaWG, OpenVPN 2.6 + Wintun adapter installed **automatically** with pinned versions/signers; dvpnd service Running; CLI on PATH (new shell); Start-menu + uninstaller entries; install-deps.log clean |
| I2 | Interactive install in a logged-on desktop session (autologon user, task `/IT`) | UAC once; wizard pages render; finish launches app; first-run onboarding screen shows |
| I3 | Offline install (egress blocked by VM firewall rule) | deps still install (bundled), app reports network missing clearly |
| I4 | Dirty B install | user's own tunnel/OpenVPN/proxy/DNS untouched (fingerprint diff = only ours) |
| I5 | Re-run same installer (repair) and upgrade from previous build | settings, wallet, device key kept; service restarted once |
| I6 | Driver removed after install → `daemon drivers` / app Diagnostics → `repair-drivers` | restored |
| I7 | Uninstall (clean, with live session, with persist armed) | fingerprint == before (+ device key folder kept by design); no leftover services, adapters, WFP sublayer, firewall rules (gap #31), PATH, proxy; internet works |
| I8 | Reinstall after uninstall | device key picked up again, no re-setup |
| I9 | Install path with spaces / non-default dir; non-admin user (UAC prompt path) | works |
Script: extend `vm-installer-test.ps1` with phases `fingerprint`, `diff`, `offline`, `repair`,
`upgrade`, `dirty-setup`.

## Phase 5 — CLI: every function on the fresh VM
Run on A after I1, through `vm-run.ps1 -Script vm-cli-sweep.ps1` extended with:
`poll` (show/set/refused/reset/run/watch visible+hidden), `daemon set` every flag
(`--basis --escrow --prepay-mb --prepay-minutes --rpc --rpc-ws --allow-lan`, every DNS preset +
custom, read back from config.toml), `test plan/run --online/stop/history/show --compare/export`
live on the six nodes (Q12/R8), plans path (R9: host a ddv- provider on `ddv-node-1` via box-rig
`provider` if available; else recorded as not provable), `channels fund`, `settle run/withdraw`,
`device setup/register/revoke`, `wallet send`. Plus `vm-safety-test` all seven tests, per-GB and
per-hour on all six protocols, kill switch matrix (refusal for WG/AWG/OVPN, filters for
Hy2/V2Ray/Xray by sublayer count), DNS leak on/off. Every command checked for exact exit code +
output; the sweep fails on any unknown command in the catalogue it did not run (coverage check).

## Phase 5b — Kill switch + split tunnelling, thoroughly, with real apps, in the app AND the CLI
Owner 2026-10-21: "has to work flawlessly end to end, simulate everything, in app as well as cli,
make sure all instructions are known properly". Runs on fresh VM A (and B for the dirty cases).

**Two drivers for every case**, same oracles:
- CLI: `vm-split-test.ps1` / `vm-safety-test.ps1` through `vm-run.ps1`.
- App: a scenario driver in the installed app (`DVPN_UI_SCENARIO=<name>`, extends the ui-smoke
  mode): clicks the real controls (Connect, Settings kill switch / DNS / allow LAN, Split tunnel
  proxy toggle, Open browser through VPN, Restore network), screenshots each step, writes
  `scenario.json` with every visible message; run in the autologon desktop session on the VM.
  A case is green only when both drivers pass.

**Kill switch matrix** (modes off / on / persist × Hy2, V2Ray, Xray; WG/AWG/OpenVPN = refused
before paying, gap #29): during session non-tunnel traffic blocked (adapter-pinned curl,
raw UDP, ICMP, IPv6 on B), DNS only via tunnel (pktmon 0 packets to the LAN resolver), LAN
reachable iff allow-lan; on disconnect / connect failure / node death / dvpnd death (gap #32)
/ service restart / reboot (persist must block until reconnect or Restore network) / uninstall
while armed → each ends with the state the copy promised and the internet back after the
documented action; app banner and CLI status say the same thing (blocked / leftover / restored).

**Split tunnelling with real apps** (V2Ray and Xray sessions, kill switch off, F16):
| App | Route expected | Oracle |
|---|---|---|
| Edge, system proxy ON (`proxy on` / app toggle) | VPN | ipify in Edge (headless `--dump-dom`) = node IP |
| Edge/Chrome launched by "Open browser through VPN" (F16.2, own profile, `--proxy-server=socks5://`) | VPN, DNS remote | node IP; pktmon: no DNS for the test host to the LAN resolver |
| Chrome/Edge normal window, system proxy OFF | direct | real IP |
| Firefox with SOCKS5 + remote DNS profile | VPN | node IP |
| PowerShell `Invoke-WebRequest` (WinINET-following) proxy on / off | VPN / direct | IP |
| `curl.exe --socks5-hostname` / plain `curl.exe` | VPN / direct | IP |
| .NET HttpClient, Windows Update / winhttp, ping, nslookup | direct (not proxy-aware) | IP / route, documented |
| Steady download through proxy + direct at once | both, no cross-talk | bytes per path vs node meter |
Plus: proxy restored to the user's own value on disconnect, on app crash (kill the app → next
start restores, F16.3), on dvpnd death, on `--switch`, and on uninstall (dirty B keeps its own
proxy); SOCKS port collision (something already on 1080); per-app mode refused/explained with
the kill switch on (F16.4); Hy2/WG sessions: proxy toggle hidden/refused with plain copy.

**Instructions are known and correct:** the in-app split-tunnel how-to (F16.1: endpoint,
copy button, browser / curl / app steps) and the CLI `proxy status` text are followed literally
by the test (each step in the how-to is a test step); any step that does not work as written
is a bug. Runbook for both drivers in `docs/BOX-RIG.md`; matrix + evidence in TEST-PLAN.

**To build for this phase:** F16.2 launcher (app button + CLI `proxy browser [--browser
edge|chrome]`), the app scenario driver, `vm-split-test.ps1`, Firefox/Chrome installs on the VMs.

## Phase 6 — No crashes, no errors (stringent)
- During every phase collect: app log + dvpnd log scanned for `error|panic|fatal|unhandled`
  (allow-list only expected, documented lines); Windows Event Log Application/System for
  WER crashes of `Devnet dVPN.exe`, `dvpnd.exe`, `hysteria2/v2ray/xray/openvpn`; Electron
  `render-process-gone` / `child-process-gone` / uncaught exceptions → app log (add if missing).
- Soak on A: 2 h loop of connect/disconnect across all six protocols + `--switch` + service
  restart mid-session + network flap (disable/enable NIC), memory/handle count of app and dvpnd
  sampled every minute (growth < 10 %), internet always back at the end of each cycle.
- Fault injection: RPC 429/garbage (bad `rpc set`), node offline, daemon killed, wallet empty,
  device out of SOL, allowance exhausted → each gives its E3 message, never a crash or raw error.
- Gate: zero unexplained error lines, zero crash events, zero failed checks.

## Phase 7 — Visual and design standards + aesthetic pass
- ui-smoke on VM A in the autologon desktop session (real installed app, not dev build) and on
  the laptop: every screen × dark/light × window 1024×700 / 1280×800 / 1920×1080 × DPI 100 %/150 %,
  plus states: onboarding, empty, loading skeleton, connecting, connected (each protocol),
  error banners, toasts, modals, CLI screen, Node test, Settings (all sections).
- Automated: `errors.json == []`, axe-core accessibility scan per screen in smoke (contrast,
  labels, focus order; add `axe-core` dev dep), no horizontal overflow, no text clipped
  (element scrollWidth checks), all strings from the catalogue, flags + country names per
  STANDARDS (ISO 3166, bundled SVG).
- Manual review against `docs/DESIGN.md` tokens and `sentinel-solana/docs/29-UI-UX-GUIDE.md` §9,
  house aesthetic with Solana branding: produce an aesthetic findings list
  (spacing, hierarchy, motion, empty states, iconography, tray icon, installer branding/icons),
  fix, re-shoot, compare before/after. Publish a screenshot gallery artifact for the owner.

## Phase 9 — Edge cases and outliers, every protocol, every feature (owner: "there will 100% be bugs")
Runs on the fresh VMs after Phase 5, before the gate. Assume each protocol is complex and
broken somewhere until a scenario proves otherwise.

**9.1 Research first → `docs/EDGE-RESEARCH.md`** (sources cited): VPN leak-test practice (IVPN
leak guide; the tor-talk study where 20 of 29 Windows clients leaked, many on reconnect; SamNet
leak vectors: reconnect window, IPv6 on dual stack, DNS per address family); WireGuard Windows
(handshake-before-MTU triage, roaming after a network change, sleep/resume reports;
wireguard-windows issue tracker); MTU/MSS decision tree (Defguard); Xray/V2Ray UDP (XUDP, UDP
over SOCKS5), Hysteria2 QUIC when UDP is blocked (Xray / Hysteria issue trackers); public
VPN-client audit reports (Cure53 / Mullvad, Proton, IVPN) for the failure classes auditors find;
Windows fault injection with clumsy (WinDivert: lag, drop, throttle, reorder, tamper, duplicate).
Output: a scenario catalogue, each with its source.

**9.2 Matrix `docs/EDGE-MATRIX.md`**: 6 protocols × scenarios (+ feature-only rows). Every
cell has four oracles, all automated:
(a) **network**: during = as designed (tunnel / blocked by kill switch); after = direct internet
and DNS back, no leftover services, adapters, WFP, routes, proxy;
(b) **money**: chain state as expected (channel escrow/redeemed/status, refund queued), never
a double charge or a lost refund;
(c) **message**: the E3 standard copy + exit code, never a raw error or "Something went wrong";
(d) **health**: no crash events, no unexplained error log lines, app + dvpnd still responsive.

**9.3 Scenarios** (each protocol unless marked):
- Network change: NIC disable/enable mid-session; DHCP renew / IP change; second NIC;
  route flap; guest suspend/resume (`gcloud compute instances suspend|resume`, a real Windows
  S3-style resume); VM reboot mid-session (persist and off); shutdown during a settle tx.
- Bad paths with clumsy: 1 / 5 / 20 % loss, 300 ms + jitter, reorder, duplicate, throttle 1 Mbps;
  UDP fully blocked (WG/AWG/Hy2 must fail clearly and fast, TCP protocols keep working);
  only TCP 443 open; path MTU 1280 (NIC MTU) and the GCP 1460 case with/without the clamp.
- IPv6: dual-stack VM (GCP IPv6 subnet on `ddv-win-b`): IPv6 leak per protocol, gap #28 (Hy2
  claims ::/0), DNS AAAA vs A resolver split, IPv6 DNS presets.
- Node side (our `ddv-node-1` only): node process stopped mid-session, restarted, slow
  (tc netem on the host), max peers reached, node listing expired, node price changed between
  view and connect, node clock skew.
- Chain/RPC: RPC down / 429 / garbage mid-session and at each connect step; tx dropped between
  steps; settle at the exact grace boundary; device out of SOL at settle; allowance = escrow
  exactly and one unit short; per-GB escrow exhausted mid-download (close-reason copy);
  per-hour expiry mid-session; billing accuracy (1 GB download: bytes vs charge vs node meter).
- Concurrency / races: app + CLI at once; connect ×20 rapid with disconnect; cancel at every
  connect step; disconnect while connecting; `--switch` while the old tunnel is still coming up;
  service restart / installer repair during a session; two settles at once.
- Machine: non-ASCII user name and profile path, long paths, low disk, system clock change,
  Defender firewall on/off, user's own VPN running (dirty B), user PAC proxy, LAN reachability
  with allow-lan true/false, split tunnel via SOCKS (app traffic vs system traffic).
- Inputs: property/fuzz tests (`fast-check` dev dep) for the CLI arg parser, settings and poll
  sanitizers, daemon flags, TOML renderer (no injection), amount parsers, node API parsing;
  CLI fuzz on the VM (random flags, unicode, huge / negative numbers, quotes in --rpc / --dns).

**9.4 Bug loop**: every failure → UPSTREAM-GAPS (dvpnd/protocol) or our fix + a regression test
(unit, or a named VM scenario) → rerun that cell and its neighbours. A cell is green only with
all four oracles passing on the final build. Scripts: new `scripts/e2e/vm-edge.ps1 -Case X`
(through `vm-run.ps1`), clumsy installed on the VMs, node-side cases via `box-rig.sh` on ddv-gcp.

## Phase 8 — Release gate + teardown
All of: **PROTOCOL-MATRIX every cell green for all six protocols, by the CLI and the app
driver, with zero refusal cells**, Phase 2 gate, I1–I9 PASS, Phase 5 sweep 0 FAIL, all seven safety tests 0 FAIL, Phase 6
gate, Phase 9 matrix all green on the final build, Phase 7 checklists ticked in STANDARDS-TRACE + TEST-PLAN with evidence (build id, VM,
time, numbers). Then settle every VM channel (stream now, voucher after 2 h grace), withdraw,
`device revoke`, return funds to 9enW4x (keep rent), delete `ddv-win-a/b` + bucket, tell agents
"VM done / rig free"; `ddv-node-1` stays until owner release. Handoff STATE + log, budget check,
commit.

## Files to change (representative)
- `scripts/e2e/vm-installer-test.ps1` (new phases), `vm-cli-sweep.ps1` (poll, daemon flags,
  test/plans/settle, coverage check), `vm-safety-test.ps1`, new `vm-soak.ps1`, `vm-fingerprint.ps1`
- ui-smoke runner (window sizes, DPI, states, axe, overflow checks); `src/main/index.ts`
  crash/gone handlers if missing
- `docs/TEST-PLAN.md`, `STANDARDS-TRACE.md`, `UPSTREAM-GAPS.md`, `BOX-RIG.md` (fresh-VM
  runbook), `ERROR-STANDARDS.md` (E3), handoff

## Verification
Each phase ends with its script's PASS/FAIL summary saved to `docs/evidence/<date>/` (logs,
fingerprints, screenshots, soak CSV) and a handoff tick. The release gate is a single checklist
in TEST-PLAN that links every piece of evidence; nothing is ticked without a log line behind it.

## Phase 10 — LAST, after the Phase 8 gate (owner 2026-10-21: "docs at the end, once everything is tested")
- **E1–E6 error-message standards**: inventory (`scripts/error-inventory.mjs`, done) → research
  (done: NN/g, Microsoft, Mullvad strings) → `docs/ERROR-STANDARDS.md` (draft) → fix every string → E5
  test over the inventory with `src/core/app/copy-rules.ts` + CLI error e2e → docs.
- **L1 Plain-language review** of every string a person sees (screens, toasts, banners, tray,
  notifications, installer, CLI): about grade-8 reading level, jargon explained or replaced
  (escrow → deposit, grant / mandate → permission, RPC), one glossary word per thing, what happened +
  what to do; before/after table; unit test that flags banned jargon in user copy.
- **D1** full update of our own standards docs, one structure, cross-linked.
- **D2** `docs/STANDARDS-COMPARISON.md`: ours vs Mullvad, Proton VPN, NordVPN, ExpressVPN, IVPN,
  WireGuard app, Tailscale + Windows/Apple guidelines, per area, ahead/behind/action.
- **D3** docs audit: every finding/test/decision in a permanent doc; docs index in README.
- **U1** `docs/UPSTREAM-PR-CANDIDATES.md`: ranked changes for dvpnd / go-sdk / protocol clients /
  devnet program from all our findings (problem, evidence, patch shape, risk, test). Proposal
  only; nothing pushed upstream without per-change owner approval.
