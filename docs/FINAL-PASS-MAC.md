# Mac final pass: checklist (driver TMC, grader ABW)

The final pass runs every Mac cell once on ONE combined build. It is the only proof of the fixes
marked FIXED-PENDING-FINAL. The soak runs only after this pass is 100% green.

## 0. Before the build lands
- [ ] `~/memory/cells/mac.tsv` is the 91-row manifest (git `~/memory`), `M-soak` is the last row,
      and n1 `~/cr/cells/mac.tsv` is the same file (`wc -l` = 91).
- [ ] FMC's uifire fixes are synced to n1 `~/ddvm` (latest Mac main `scripts/e2e/mac/`).
- [ ] No matrix driver holds the guest (`ssh ddv-mac 'cat ~/matrix-driver.lock/owner'` is empty).
- [ ] Hold every cell: the runner must not start a cell on RC3 while the build is swapped.

## 1. Install the combined build in the guest
- [ ] DIR names the build (Mac main commit + the dvpnd A/B hash from FWX).
- [ ] `bash scripts/e2e/mac/guest-update.sh ddv-mac` builds in the GUEST (never on the laptop),
      replaces `/Applications/Devnet dVPN.app` and runs `daemon install --yes`.
- [ ] Record the app version and `devnet-dvpn daemon version` (the dvpnd hash must match FWX's).
- [ ] Smoke: `devnet-dvpn status` shows the wallet, the device ready, and the daemon running the new hash.

## 2. Reset the results for a complete pass
- [ ] On n1, move (never delete) every current verdict to `~/cr/results/prev-rc3-<UTC stamp>/`
      (`*.pass *.fail *.unrun` and `logs/`). The runner then sees every cell as untested.
- [ ] Release all claims except: `M-soak` (last), `M-a19-ipv6` (archived, Q0136),
      `M-throughput` (node-4 solo slot), `M-plan-a3a4-ovh` / `-vx` (ticket windows).
- [ ] Release the combined-build holds (`~/cr/held-combined-build.txt`, 10 uifire cells).
- [ ] Add `finalbuild` to the runner flags in n1 `~/cr/run-mac.sh` (`--flags dualstack,finalbuild`):
      `M-edge:dns-suffix-leak` (Q0333 Mac twin) needs it. Check the guest dvpnd is the RC3-LIST final pin at the build call.

## 3. Run
- [ ] The runner takes one cell at a time (`--once` loop); devnet txs 7 s apart; Mac uses node-4 only.
- [ ] Every result goes to ctl-1 (verdict cron `push-ctl.sh` every 2 min, logs `push-logs.sh` every 5 min).
- [ ] Each FAIL gets a verdict (product / harness / env) and an owner within 15 min; the log is on ctl-1.
- [ ] Node-4 solo slot (booked by DIR, one window for the whole pass): set the `solo-node4` flag on n1
      for that window only, run `M-throughput`, then clear the flag.
- [ ] Ticket windows: `M-plan-a3a4-ovh` at 2026-10-30 09:45Z, `M-plan-a3a4-vx` 24 h after the ovh run.

## 4. Done
- [ ] Every row except `M-soak` and `M-a19-ipv6` has a `.pass` on the final build.
- [ ] ABW has graded each result; FIXED-PENDING-FINAL rows are closed with the pass log as evidence
      (by the proof owner DIR assigned, never by the fixer).
- [ ] Soaks are ARCHIVED (owner, 2026-10-30): `M-soak` stays held and out of counts. If they are ever
      brought back, release `M-soak` only after the steps above. Before it runs: `cmp` each `scripts/e2e/mac/soak-oracle/*.mjs` against
      `~/memory/bin/` (the vendored copies must be byte for byte the shared oracle), then sync to n1.
- [ ] `M-soak` passes only with `PASS money` and `PASS reconnects` in its log (SOAK-PLAN.md checks 1 + 2).

## Cells that need more than the runner
| Cell | Needs | Owner |
|---|---|---|
| M-throughput | node-4 solo window | DIR books, TMC flags n1 |
| M-plan-a3a4-ovh, -vx | 24 h ticket windows | TMC |
| M-uifire:export-csv | host QMP keystrokes for the Save sheet (no Accessibility: SIP on) | FMC script |
| M-uifire:sign-out, onboard-device-setup | the uifire wallet `~/.ddv/uifire-wallet.json` (back it up to `~/memory/ddv-vm-wallets/`); they rebind the service device, so they run last before soak | FMC script |
| M-soak | 100% final pass first | after everything |
