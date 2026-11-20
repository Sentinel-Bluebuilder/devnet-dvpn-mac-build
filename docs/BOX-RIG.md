# Box rig — every node type, a plan provider, real sessions

> **Stale project names:** the GCP commands below name `ddv-node-test-5821`, which is RETIRED by
> owner order: never start anything there and never log back in. Use the project and rules in
> `~/memory/gcp-account.md` instead.

`scripts/e2e/box-rig.sh` runs **six dVPN nodes (one per protocol), a plan provider and a client
daemon** on a shared Linux host (ssh alias in `BOX_HOST`), so the CLI and the app can be proven
end to end against real nodes without touching this laptop's networking.

## Layout

| where | what |
|---|---|
| host | `ddv-node@{wg,awg,v2ray,xray,ovpn,hy2}` + `ddv-provider` systemd units, under `/home/ubuntu/ddvpn-test` |
| netns `ddvapp` | the client daemon. Its full tunnel and kill switch stay inside the namespace; the host's routes and SSH are never touched. A dead-man timer (`ddv-deadman`, 30 min, re-armed by `client`) removes it if nobody does |
| laptop | the CLI / app over `ssh -L` (client gRPC on `127.0.0.1:50071`, node APIs `18711–18716`, provider API `18719`) |

| node | service | protocol bit | API | tunnel ports |
|---|---|---|---|---|
| wg | wireguard | 1 | 18711 | udp 18721 |
| awg | amneziawg | 32 | 18712 | udp 18722 |
| v2ray | v2ray | 2 | 18713 | tcp 18723, 18724 |
| xray | xray | 4 | 18714 | tcp 18726, 18727 |
| ovpn | openvpn | 8 | 18715 | udp 18729 |
| hy2 | hysteria2 | 16 | 18716 | udp 18730 |

All owned by a **fresh operator key made on the host**. The devnet wallet key never leaves the
laptop; it funds the operator with the app's own `wallet send`.

## Run it

```bash
bash scripts/e2e/box-rig.sh snapshot baseline   # host state before anything
bash scripts/e2e/box-rig.sh ship                 # binaries + RPC URL (never printed)
bash scripts/e2e/box-rig.sh operator             # prints the operator address
node out/cli/devnet-dvpn.cjs wallet send --to <operator> --sol 1.5 --yes   # (rig-env / box-env)
node out/cli/devnet-dvpn.cjs wallet send --to <operator> --tdvpn 20 --yes
bash scripts/e2e/box-rig.sh nodes                # init + open_node + start, all six
bash scripts/e2e/box-rig.sh provider             # init + open_provider + list_provider + start
bash scripts/e2e/box-rig.sh plan                 # open_plan + every node on the roster
bash scripts/e2e/box-rig.sh client               # netns + client daemon + gRPC bridge + dead-man
bash scripts/e2e/box-rig.sh tunnel               # laptop ssh -L
source scripts/e2e/box-env.sh                    # CLI/app -> box client, own data dir
node out/cli/devnet-dvpn.cjs device register <device printed by client>
node out/cli/devnet-dvpn.cjs device setup --allowance 50 --yes
bash scripts/e2e/box-rig.sh client               # the daemon starts once the device has its permission
```

`push` re-sends only the scripts (binaries are busy while daemons run). `pull <bytes>` and `ip`
generate traffic inside the namespace.

UI proof: `DVPN_UI_SMOKE=<dir> DVPN_UI_SMOKE_CONNECT=<node>:<per_gb|per_hour>` (or
`<node>:plan:<subscription>`) runs the normal screen walk, then clicks a real connect and
disconnect and saves `09-*`…`11-*` screenshots. It spends; use it only against this rig.

## GCP host (all six protocols reachable from the laptop)

The shared box blocks UDP, so full-tunnel protocols are tested against a throwaway Google Cloud
VM. Project `ddv-node-test-5821` (personal gcloud login, never another project's), VM `ddv-node-1`
(e2-micro, us-central1-a, 35.232.17.117), firewall rule `ddv-nodes` (TCP+UDP 18711–18730, tag
`ddv-node`), SSH alias `ddv-gcp` (`~/.ssh/ddv_gcp`). gcloud on this laptop needs
`CLOUDSDK_PYTHON` = the SDK's bundled python (set for the user; `scripts/e2e/gcloud-login.sh`).

- Every verb takes `BOX_HOST=ddv-gcp`; `ship` with `BOX_IP=35.232.17.117 BOX_WAN=ens4
  BOX_COUNTRY=US` writes `host.env` on the host. Operator `J1oXtjyx…` (made on the VM).
- **Kernel 6.8 (`linux-image-gcp-lts-24.04`), not the image's 7.0**: AmneziaWG's DKMS module
  doesn't build on 7.0 and userspace `amneziawg-go` passed no data (UPSTREAM-GAPS #23).
- Windows clients: WireGuard for Windows, AmneziaWG for Windows, **OpenVPN 2.6.x** (2.7 removed
  Wintun, #21), `resources/bin/hysteria2/hysteria2.exe`. If Hysteria2 starts failing with
  `finding hy2-client`, remove the stale `SWD\WINTUN\{…}` sing-tun device (#22).
- Safety: SYSTEM task `devnet-dvpn-deadman` with `-WatchMinutes 60` (3 failed dials → stop
  dvpnd, remove tunnel services, kill openvpn/hysteria2). Run each test as ONE command that
  ends with `disconnect`, so the laptop recovers even if the session drops mid-test.

> **⚠ KS-on sustained-cut tests MUST disarm the dead-man first.** The dead-man's trigger is
> *N failed dials → stop dvpnd* (Mac: `network.sentinel.ddv-deadman`, `StartInterval 40`,
> `launchctl bootout …sentinel-dvpnd.c0`; Windows: `devnet-dvpn-deadman -WatchMinutes 60`,
> 3 failed dials → stop; Linux netns: `ddv-deadman`). A deliberate kill-switch test that
> **blocks the node for ≥ the dial-fail window** (e.g. a 90 s `plat_cut`) looks exactly like
> "the guest lost its net" to the dead-man, so it boots dvpnd mid-cut — which *removes the pf
> anchor and lifts the kill switch*, then normal direct egress follows. That reads as a
> **false KS fail-open** (this was Q0464: dvpnd itself ended the session correctly at the cut
> with the KS KEPT; the dead-man killed it 61 ms after, not dvpnd). Before any KS-on cut whose
> duration ≥ the dead-man's fail window: **disarm the dead-man for the cut window** (set its
> fail-count N past the cut seconds, or pause its hold-renew / unload the job), run the cut,
> then **re-arm it immediately** — it is the guest's only network lifeline, never leave it off.
> Pass criterion for such a test: pcap shows **0 direct (non-tunnel) packets while KS is on**,
> and dvpnd stays up through the cut.
- Teardown: settle (per-GB channels need 2 h) → `box-rig.sh close` → 3600 s → `withdraw` →
  send leftovers back → `gcloud projects delete ddv-node-test-5821`.

Evidence (2026-10-20): WG 2.3, AWG 1.4, OVPN 2.1, Hy2 3.1, V2Ray 2.3, Xray 2.5 MB/s (10 MB
each), IP = 35.232.17.117 in tunnel, 49.43.228.6 after; per-GB WG 19.5 MB metered; `--switch`
WG → Hy2; app UI connect/disconnect over WireGuard with IP chip = node.

## Installer VM (clean Windows, TEST-PLAN T1)

Proves the setup .exe on a machine that never saw the app. Same project, same personal
account; **pass `--account` + `--project` on every command**. The default gcloud config on
this laptop belongs to another project's service account, and it is left alone.

What works (2026-10-20). The image has no OpenSSH and `gcloud compute ssh`/`scp` (plink)
failed, so a startup script installs sshd and the laptop's gcloud key; then plain `ssh`, and
files go up over stdin (`scp` is refused):

```bash
export CLOUDSDK_PYTHON="/c/Program Files (x86)/Google/Cloud SDK/google-cloud-sdk/platform/bundledpython/python.exe"
G="gcloud --account <personal> --project ddv-node-test-5821"
$G storage buckets create gs://ddv-node-test-5821-artifacts --location us-central1 --uniform-bucket-level-access
$G storage cp dist/Devnet-dVPN-Setup-<v>-x64.exe dist/SHA256SUMS.txt gs://ddv-node-test-5821-artifacts/<v>/
# __ADMINCIDR__ = this laptop's carrier range (curl api.ipify.org → its /16): SSH is closed to everyone else (bots)
sed "s|__PUBKEY__|$(cat ~/.ssh/google_compute_engine.pub)|; s|__ADMINCIDR__|49.43.0.0/16|" scripts/e2e/vm-startup.ps1 > "$TEMP/vm-startup.ps1"
$G compute instances create ddv-win-N --zone us-central1-a --machine-type e2-standard-2 \
  --image-family windows-2022 --image-project windows-cloud --boot-disk-size 50GB \
  --metadata enable-windows-ssh=TRUE --metadata-from-file windows-startup-script-ps1="$TEMP/vm-startup.ps1" \
  --scopes storage-ro
O="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ~/.ssh/google_compute_engine"
ssh $O Connect@<ip> hostname                      # ready after ~3-5 min
ssh $O Connect@<ip> "powershell -NoProfile -Command \"New-Item -ItemType Directory -Force C:\ddv | Out-Null; [IO.File]::WriteAllText('C:\ddv\vm-installer-test.ps1', [Console]::In.ReadToEnd())\"" < scripts/e2e/vm-installer-test.ps1
ssh $O Connect@<ip> "powershell -NoProfile -ExecutionPolicy Bypass -File C:\ddv\vm-installer-test.ps1 -Phase install"
# … CLI flow: key-file wallet (DPAPI has no key for an SSH logon), device setup, daemon install, connect …
ssh $O Connect@<ip> "powershell … -Phase uninstall"
$G compute instances delete ddv-win-N --zone us-central1-a --quiet; $G storage rm -r gs://ddv-node-test-5821-artifacts
```

Multi-step CLI runs go up as a `.cmd` file and run with `cmd /c file > log 2>&1`: cmd quoting
over SSH breaks otherwise. Use forward slashes in paths inside uploaded JS.

The SSH user is an administrator with a full token, so the app's elevated steps run
directly (no UAC: `elevate.ts` checks for that). That makes the SSH session behave like a
user who clicked Yes.

## Laptop client (Windows service, proxy protocols only)

The cloud firewall passes only TCP 22/443, so the laptop reaches the box's V2Ray/Xray nodes
through SSH. dvpnd dials the tunnel at the node's **API host** (`hosts.apiAddrs[0]`) plus the
inbound port, so moving a node's on-chain uri to `https://127.0.0.1:<port>` makes the laptop
client dial loopback, which `ssh -L` forwards. UDP protocols (WireGuard, AmneziaWG, Hysteria2,
OpenVPN-UDP) cannot use this trick; they need TCP+UDP 18711–18730 opened in the provider's
security group (owner, provider console; no API credentials on this machine).

1. `box-rig.sh loopback v2ray xray` (rewrites `[api] addrs`, restarts, checks the on-chain uri);
   `box-rig.sh tunnel` (forwards the API ports and the V2Ray/Xray tunnel ports).
2. `source scripts/e2e/win-env.sh` (own data dir, `DVPN_KEYFILE`, no WSL overrides).
3. Arm the dead-man: a SYSTEM scheduled task `devnet-dvpn-deadman` running
   `scripts/e2e/win-deadman.ps1 -Sid <user SID>` once, ~45 min out. It clears the user's
   system proxy and stops the dvpnd service. Push it out while testing; remove it at the end.
4. `daemon init`, then patch the staged client config: `kill_switch = 'off'`, `dns = 'none'`,
   your RPC. `device setup --yes`, `daemon install --yes` (one UAC). The install writes a
   **per-service** `Environment` PATH (`HKLM\…\Services\dvpnd`) ending in
   `resources\bin\v2ray;resources\bin\xray`. dvpnd finds those binaries only on PATH, and the
   machine PATH stays untouched.
5. `connect <node> --basis per_hour|per_gb --units 1 --yes`, `quality ip` (direct IP + VPN IP via
   SOCKS), `proxy on|off --yes`, `connect --switch`, `disconnect`, `settle run --yes`.
6. End: `box-rig.sh public v2ray xray`; leave the service installed only with the kill switch off.
   Otherwise uninstall it with `resources/scripts/uninstall-cleanup.ps1`.

Evidence (2026-10-20, laptop): Xray per hour + V2Ray per GB sessions through the service, VPN IP
103.192.199.225 vs direct 49.43.228.6, about 4–5 MB/s over the SSH forward; `--switch` refused
without the flag; usage tick 10.5 MB; real system proxy: on → Chromium resolves `SOCKS
127.0.0.1:1080` and exits at the box, off → DIRECT with the registry restored; proxy left on, then
app start → cleared (crash path); app UI connect/disconnect on the service shows VPN IP, DNS
System, live clock, usage.

## Tear down (in order)

1. `settle run --yes` (stream channels close at once; voucher channels after the 2-hour grace),
   then `settle withdraw --yes`; `plans close <subscription> --yes`.
2. `box-rig.sh close` (delist + close nodes and provider), wait out the unbonding period,
   `box-rig.sh withdraw` (bonds back to the operator), send what is left back to the wallet.
3. `box-rig.sh teardown`, then `box-rig.sh check` must say CLEAN against the baseline snapshot.

## Evidence — 2026-10-20 run

Every row ran from the laptop CLI against the box; tunnel proof is a download inside the
namespace and the route it took.

| function | result |
|---|---|
| `wallet send` SOL + tDVPN | operator funded, 2 txs |
| `device register` / `device plan` / `device setup` | new device ready in one tx; re-run tops up only what is missing |
| `nodes list --online` | all 6 verified online (signed metadata, TLS pin) |
| connect per GB / per hour × 6 protocols | 12/12 Protected; traffic via `dvpn-wg-client`, `dvpn-awg-client`, `ovpn-client`, `hy2-client`, SOCKS 127.0.0.1:1080 for V2Ray/Xray |
| `connect --switch` | each protocol change; plain connect while connected refused |
| `plans list` / `roster` / `subscribe` | plan `C6QCzd…` with 6 live servers; subscription `A8rg26…` |
| ticketed connect | WireGuard + Xray; reconnect reuses the held ticket; third server refused early with `plan-limit` copy |
| `channels fund` | top-up landed on chain; reused on reconnect (see UPSTREAM-GAPS #13) |
| `disconnect` / `settle run` / withdraw | 5 stream closes + 10 voucher start-closes + withdraw in one command |
| `proxy on` | refused: SOCKS endpoint not answering on this computer; Windows proxy untouched |
| app UI connect | Servers → sheet → Protected → Disconnect (OpenVPN per hour); Plans → roster → Protected (Xray, held ticket) |

Bugs this run found and fixed are in the git log (`Box e2e fixes`, `round 2`, `Plans: reuse held
tickets`); protocol findings are UPSTREAM-GAPS #13–#17.
