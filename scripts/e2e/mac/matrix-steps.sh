#!/bin/bash
# ─── One step of one matrix case on one protocol, run IN the guest (the laptop driver calls it) ───
#   bash matrix-steps.sh env                       measure the guest's own network (before a run)
#   bash matrix-steps.sh <case> <protocol> <step>  one step; results append to ~/matrix/<case>.tsv
#   bash matrix-steps.sh <case> - summary           totals for the case
# Steps that cut the rig's own link (allow LAN off while the kill switch holds) are started
# detached by the driver and write their results the same way.
# Mac twin of #32 scripts/e2e/linux/matrix.sh; the cases and their A-rows are in matrix.sh.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
CASE=${1:?case}
if [ "$CASE" = env ]; then env_init; exit 0; fi
P=${2:?protocol}; STEP=${3:?step}
case_init "$CASE"

ipify_routes() { dscacheutil -q host -a name api.ipify.org | awk '/ip_address:/{print $2"/32"}' | sort -u | paste -sd, -; }
other_egress() { curl -4 -s -m 12 https://checkip.amazonaws.com | tr -d '\n'; }
sid_now() { $CLI status --json 2>/dev/null | grep -oE '"(sessionId|id)"\s*:\s*"?[0-9]+' | head -1 | grep -oE '[0-9]+$'; }
channel_now() { $CLI status --json 2>/dev/null | grep -oE '"channel[A-Za-z]*"\s*:\s*"[1-9A-HJ-NP-Za-km-z]{32,44}"' | head -1 | grep -oE '[1-9A-HJ-NP-Za-km-z]{32,44}"$' | tr -d '"'; }
bytes_now() { $CLI status --json 2>/dev/null | grep -oE '"(rxBytes|txBytes)"\s*:\s*"?[0-9]+' | head -1 | grep -oE '[0-9]+$'; }
# keep the rig's SSH up while the kill switch holds: LAN on (internet still fails closed)
rig_safe() { run 0 '-' "kill switch $1, allow LAN on (rig link)" -- daemon set --kill-switch "$1" --allow-lan true --yes; }

step() {
  case "$CASE:$STEP" in
    # ─── shared ───
    *:reset) case_reset ;;
    *:begin)
      mark; info 'case start' "$(date -u +%FT%TZ) direct=$DIRECT nic=$NIC" ;;
    *:end)
      back_clean "$CASE"; health "$CASE"; gap ;;
    *:defaults)
      run 0 '-' 'kill switch off, LAN on, whole device on, split off, Cloudflare DNS (networksetup)' -- \
        daemon set --kill-switch off --allow-lan true --whole-device true --split-mode off --split-apps none --split-routes none --dns cloudflare --dns-mode networksetup --yes ;;

    # ─── A1/A2/A8/A25: pay per GB / per hour, live stats, disconnect gives the own IP back ───
    pay-gb:run|pay-hour:run)
      local basis=per_gb word='per GB'; [ "$CASE" = pay-hour ] && { basis=per_hour; word='per hour'; }
      connect_p "$P" --basis "$basis" || { restore; return; }
      sleep 4
      check 'egress = node' egress_is_node "$P"
      run 0 "$word" "status shows $word" -- status
      run 0 "$P" 'status names the protocol' -- status
      fetch_bytes 5000000 -m 30 -o /dev/null
      sleep 20
      local b; b=$(bytes_now); info 'bytes counted by the session (A25)' "${b:-none}"
      check 'live stats count traffic (A25)' bash -c "[ '${b:-0}' -gt 0 ] 2>/dev/null"
      run 0 '-' 'disconnect' -- disconnect
      sleep 3 ;;

    # ─── A3/A4: connect on a plan subscription (port of #32's plan case; DIR Q0277) ───
    # The plan must cover the nodes this run uses: node-4's six (nodes.env, solo node) = plan 55yEYsyU (#31's W
    # plan cell), node-3's six = plan 8z7U383V (#32). A plan whose roster lacks the node refuses ("couldn't give
    # this server access"). Its max_connections (2) counts this WALLET's servers with an unexpired ticket (24 h),
    # and dvpnd binds the service device to ONE owner (another wallet's ticket: "ticket was issued for another
    # owner", run 2). So the main wallet covers two protocols per 24 h: M-plan-a3a4 (all), M-plan-a3a4-ovh
    # (openvpn hysteria2, +24 h) and M-plan-a3a4-vx (v2ray xray, +48 h) are held until its tickets expire (DIR (a)).
    # Each protocol subscribes and closes its own subscription (also after a failed connect).
    plan-a3a4:run)
      # ~/matrix/plan-wallet names another key file. It only works when dvpnd's CLIENT OWNER is that wallet:
      # `device setup` alone does not re-own the service (10-29 21:2xZ: "ticket was issued for another owner")
      local plan w last=''
      w=$(cat ~/matrix/plan-wallet 2>/dev/null); w=${w:-$HOME/.ddv/test-wallet.json}
      case $NODE_IP in 136.115.100.141) plan=55yEYsyUd87AFEhLg9PuL39cfaDMktjEg74CSw8PdRzc ;; *) plan=8z7U383V2goPWDTUBgHfrsDCFAyc39wC15utQ9mLrXo7 ;; esac
      plan=${PLAN_ADDR:-$plan}
      check "plan roster covers the $P node ($(node_of "$P" | cut -c1-8))" bash -c "$CLI plans roster $plan 2>/dev/null | grep -q '^$(node_of "$P") '"
      last=1 # one subscription per protocol (0.001 tDVPN), closed right after: no state between steps
      [ -s "$w" ] || { record FAIL "plan wallet $(basename "$w") present in the guest" ''; return; }
      export DVPN_KEYFILE=$w
      info 'plan wallet' "$($CLI wallet show 2>/dev/null | grep -v '^\[rpc\]' | head -1)"
      if $CLI device show 2>/dev/null | grep -qE '^Ready +no'; then
        gap; run 0 '-' 'device setup for this wallet (spending permission on the shared device key)' -- device setup --yes
      fi
      local sf="$OUT/plan-sub-$(basename "$w" .json)" sub
      sub=$(cat "$sf" 2>/dev/null)
      if [ -z "$sub" ]; then
        gap; run 0 '-' "plans subscribe $plan" -- plans subscribe "$plan" --yes
        sub=$($CLI plans subscriptions --json 2>/dev/null | node -e "let t='';process.stdin.on('data',d=>t+=d).on('end',()=>{try{const j=JSON.parse(t);const a=(Array.isArray(j)?j:j.subscriptions||[]).filter(s=>s.plan==='$plan'&&s.active!==false).sort((x,y)=>(x.openedAt||0)-(y.openedAt||0));const s=a[a.length-1];console.log(s?(s.address||s.subscription||''):'')}catch(e){console.error('plan parse: '+e.message);console.log('')}})")
        if [ -z "$sub" ]; then record FAIL 'subscription found after subscribe' "$($CLI plans subscriptions 2>&1 | head -5)"; return; fi
        echo "$sub" > "$sf"; info 'subscription' "$sub"
      fi
      gap
      hold
      if ! run 0 'Connected|connected' 'connect on the subscription' -- connect "$(node_of "$P")" --plan "$sub" --yes; then
        restore
        if [ -n "$last" ]; then gap; run 0 '-' 'plans close the subscription (after a failed connect)' -- plans close "$sub" --yes; rm -f "$sf"; fi
        return
      fi
      sleep 4
      check 'egress = node' egress_is_node "$P"
      run 0 "$P" 'status names the protocol' -- status
      info 'status' "$LAST"
      sleep 20 # a few voucher rounds on the plan ledger
      run 0 '-' 'disconnect' -- disconnect
      sleep 3
      run 0 '-' "plans roster $plan (recorded)" -- plans roster "$plan"
      info 'roster' "$LAST"
      if [ -n "$last" ]; then gap; run 0 '-' 'plans close the subscription' -- plans close "$sub" --yes; rm -f "$sf"; fi ;;

    # ─── A10: live top-up ───
    topup:run)
      # a once-case (P=all): channel billing is protocol-independent, so it tops up a WireGuard session
      [ "$P" = all ] && local P=wireguard
      connect_p "$P" || { restore; return; }
      sleep 4
      local ch; ch=$(channel_now)
      if [ -z "$ch" ]; then record FAIL 'channel in status --json' "$($CLI status --json 2>&1 | head -c 300)"; restore; return; fi
      gap
      run 0 '-' "channels fund $ch +1 tDVPN mid-session" -- channels fund "$ch" --tdvpn 1 --yes
      sleep 6
      check 'session still up after the top-up, egress = node' egress_is_node "$P"
      run 0 "$P" 'status still connected' -- status
      run 0 '-' 'disconnect' -- disconnect
      sleep 3 ;;

    # ─── A5: a new process adopts the running session; a service restart keeps control ───
    adopt:run)
      connect_p "$P" || { restore; return; }
      sleep 4
      run 0 "$P" 'new process: status adopts the running session' -- status
      if is_proxy "$P"; then run 0 '127\.0\.0\.1:[0-9]+' 'new process: proxy status shows the SOCKS endpoint' -- proxy status; fi
      check 'adopted session: egress = node' egress_is_node "$P"
      sudo launchctl kickstart -k "system/$LABEL"; sleep 12
      run 0 '-' 'after a service restart: status (recorded)' -- status
      info 'status after restart' "$LAST"
      run 0 '-' 'after a service restart: disconnect still works' -- disconnect
      sleep 3 ;;

    # ─── A7: whole device — every app, not only proxy-aware ones ───
    whole:run)
      run 0 '-' 'whole device on' -- daemon set --whole-device true --yes
      connect_p "$P" || { restore; return; }
      sleep 5
      check 'curl (no proxy settings) exits at the node' bash -c "[ \"\$(curl -4 -s -m 12 --noproxy '*' https://api.ipify.org)\" = '$NODE_IP' ]"
      check 'NSURLSession (nscurl, the path Mac apps use) exits at the node' bash -c "nscurl https://api.ipify.org 2>/dev/null | grep -qF '$NODE_IP'"
      check 'Python urllib (ignores system proxy) exits at the node' bash -c "[ \"\$(/usr/bin/python3 -c 'import urllib.request;print(urllib.request.urlopen(\"https://api.ipify.org\",timeout=12).read().decode())' 2>/dev/null)\" = '$NODE_IP' ]"
      check 'a utun carries the session' bash -c "[ -n \"\$($(declare -f new_utuns); OUT='$OUT'; new_utuns)\" ]"
      run 0 '-' 'disconnect' -- disconnect
      sleep 3 ;;

    # ─── A15–A17: DNS through the tunnel, nothing in clear on the NIC, first lookup fast ───
    dns:run)
      run 0 '-' 'kill switch off, Cloudflare DNS, networksetup' -- daemon set --kill-switch off --dns cloudflare --dns-mode networksetup --yes
      connect_p "$P" || { restore; return; }
      sleep 4
      if is_proxy "$P"; then
        local s; s=$(socks)
        check "SOCKS-resolved names never hit $NIC port 53" bash -c "$(declare -f dns_on_nic); NIC=$NIC; c() { curl -s -m 8 --socks5-hostname $s -o /dev/null https://\$1; }; [ \"\$(dns_on_nic c)\" = 0 ]"
      else
        check 'system resolver = the session DNS forwarder, 127.0.0.1 (scutil --dns; Q0365/Q0377)' bash -c "a=\$(sudo -n grep -F 'dns forwarder racing' /Library/Logs/DevnetDVPN/dvpnd.log | tail -1 | grep -oE 'addr.:.[0-9.]+:53' | grep -oE '[0-9.]+:53' | cut -d: -f1); [ -n \"\$a\" ] && scutil --dns | awk '/resolver #1/{f=1} f && /nameserver\\[0\\]/{print \$3; exit}' | grep -qx \"\$a\""
        check "no lookup leaves in clear on $NIC" bash -c "$(declare -f dns_on_nic sys_lookup); NIC=$NIC; [ \"\$(dns_on_nic sys_lookup)\" = 0 ]"
        check 'positive control: a lookup straight to the QEMU resolver IS seen on the NIC' bash -c "$(declare -f dns_on_nic); NIC=$NIC; d() { dig +time=2 +tries=1 @10.0.2.3 \$1 >/dev/null; }; [ \"\$(dns_on_nic d)\" -gt 0 ]"
      fi
      local t0 t1; t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000'); sys_lookup "ddv-first-$RANDOM.cloudflare.com" >/dev/null 2>&1; dscacheutil -q host -a name www.wikipedia.org >/dev/null; t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
      check "first lookups answered in < 3 s ($((t1 - t0)) ms) (A17)" bash -c "[ $((t1 - t0)) -lt 3000 ]"
      run 0 '-' 'disconnect' -- disconnect
      sleep 3
      check 'system DNS back to the resolvers from before' dns_back ;;

    # ─── A11–A14: kill switch on / persist: path lost, service restart, SIGKILL, protocol death ───
    ks-on:a|ks-persist:a)
      faulted_live
      local mode=on; [ "$CASE" = ks-persist ] && mode=persist
      rig_safe "$mode"
      connect_p "$P" || { restore; return; }
      sleep 4
      check 'egress = node' egress_is_node "$P"
      check 'pf anchor dvpnd holds (block drop out all first)' anchor_blocks
      if is_proxy "$P"; then check 'a direct (non-proxied) request is blocked' bash -c '! curl -4 -s -m 8 https://api.ipify.org'; fi
      hold ;;
    ks-on:lost|ks-persist:lost) # the driver has cut the path to the node on the host
      hold; sleep 4; never_direct 'path to the server lost'
      check 'pf anchor still holds while the node is unreachable' anchor_blocks ;;
    ks-on:restart|ks-persist:restart)
      # A service restart is a CLEAN stop: mode "on" releases the kill switch by design (dvpnd
      # keepsFirewall; #31 ks-edge svcrestart records the direct samples as INFO). Persist keeps it.
      restarted_live; hold; sudo launchctl kickstart -k "system/$LABEL"; sleep 2
      if [ "$CASE" = ks-persist ]; then
        never_direct 'during a service restart'
      else
        info 'during a service restart (mode on releases on a clean stop, by design)' "egress $(curl -4 -s -m 10 https://api.ipify.org)"
      fi
      sleep 15
      run 0 '-' 'status after the restart (recorded)' -- status
      if [ "$CASE" = ks-persist ]; then
        check 'after the restart: kill switch in pf (not just recorded)' anchor_blocks
        never_direct 'after the restart'
      else
        check 'after the restart: the internet works (block released with the session)' bash -c "[ -n \"\$(curl -4 -s -m 10 https://api.ipify.org)\" ]"
      fi
      live_again ;;
    ks-on:kill|ks-persist:kill)
      # A death is not a stop: in both modes the block stays until the user disconnects (ddv10+)
      hold; restarted_live; sudo launchctl kill SIGKILL "system/$LABEL"; sleep 2
      never_direct 'dvpnd SIGKILLed'
      check 'launchd brings dvpnd back (answers the CLI)' svc_back
      sleep 10
      check 'after SIGKILL + restart: kill switch in pf' anchor_blocks
      never_direct 'after SIGKILL + restart' ;;
    ks-on:proto|ks-persist:proto)
      live_again # the SIGKILL step ended the session; this step needs a live protocol process
      hold; restarted_live; proto_killed # the protocol process is killed on purpose: no final sample, stats fail
      local pids; pids=$(proto_pids "$P" | tr '\n' ' ')
      check "a protocol process is running to kill (${pids:-none found})" bash -c "[ -n \"$pids\" ]"
      [ -n "$pids" ] && sudo kill -9 $pids
      sleep 3; never_direct 'protocol process killed'
      sleep 25; never_direct 'tunnel dead 25 s later' ;;
    ks-on:close|ks-persist:close)
      hold
      # dvpnd keepsFirewall: Disconnect (StopSession) releases the block in every mode; persist keeps
      # a block that is HELD (the session already ended under the user: dvpnd death, protocol death).
      local live=0; $CLI status 2>/dev/null | grep -q '^Session  Protected' && live=1
      run 0 '-' 'disconnect' -- disconnect; sleep 3
      if [ "$CASE" = ks-persist ] && [ "$live" = 0 ]; then
        check 'persist: a held block is kept after disconnect until restore-network' anchor_blocks
        never_direct 'persist: nothing direct after disconnect'
      elif [ "$CASE" = ks-persist ]; then
        check 'persist: disconnecting a live session releases the block (StopSession, by design)' bash -c '! sudo pfctl -a dvpnd -s rules 2>/dev/null | grep -q "block drop out all"'
      fi
      run 0 '-' 'restore network' -- daemon restore-network; sleep 3
      run 0 '-' 'kill switch off' -- daemon set --kill-switch off --yes ;;

    # ─── ks-edge (twin of vm-ks-edge.ps1): failures with the kill switch on ───
    # connfail (once): a server that does not exist → refused before any payment, nothing armed.
    ks-connfail:run)
      rig_safe on
      local before; before=$(tdvpn_now)
      run 1 '-' 'kill switch on: connect to a server that does not exist is refused' -- connect 11111111111111111111111111111111 --basis per_gb --units 1 --yes
      check 'the refusal is plain copy (no stack, no "Something went wrong")' plain_copy "$LAST"
      check 'internet still direct (no half-armed kill switch)' bash -c "[ \"\$(curl -4 -s -m 10 https://api.ipify.org)\" = '$DIRECT' ]"
      check 'no pf rules left in the dvpnd anchor' bash -c "[ \$(sudo pfctl -a dvpnd -s rules 2>/dev/null | grep -c .) = 0 ]"
      check 'nothing paid' bash -c "[ '$(tdvpn_now)' = '$before' ]"
      run 0 '-' 'kill switch off' -- daemon set --kill-switch off --yes ;;
    # nodedown: the server is unreachable from before connect (the driver blocks it on the host).
    ks-nodedown:a)
      faulted_live
      rig_safe on; hold ;;
    ks-nodedown:b)
      hold
      run 1 '-' "kill switch on: connect while the $P server is unreachable fails" -- connect "$(node_of "$P")" --basis per_gb --units 1 --yes
      check 'the failure is plain copy' plain_copy "$LAST"
      info 'failure copy' "$LAST"
      check 'internet direct after the failed connect (block released)' bash -c "for i in 1 2 3 4 5; do [ \"\$(curl -4 -s -m 8 https://api.ipify.org)\" = '$DIRECT' ] && exit 0; sleep 3; done; exit 1"
      run 0 '-' 'status after the failure' -- status
      run 0 '-' 'restore network' -- daemon restore-network; sleep 3
      run 0 '-' 'kill switch off' -- daemon set --kill-switch off --yes ;;
    # exhausted (Q0353, dvpnd issuer.go fail-open): the driver cuts the node for up to 600 s, long
    # enough for every reconnect to fail. Kill switch "on" must keep the block when dvpnd gives up,
    # and after the node answers again, until the user restores the network.
    ks-exhausted:a)
      faulted_live
      rig_safe on
      connect_p "$P" || { restore; return; }
      sleep 4
      check 'egress = node' egress_is_node "$P"
      check 'pf anchor dvpnd holds (block drop out all first)' anchor_blocks
      hold ;;
    ks-exhausted:exhaust)
      local t=0 st=''
      while [ $t -lt 540 ]; do
        hold
        st=$($CLI status 2>/dev/null | grep -E '^Session ' | head -1)
        echo "$st" | grep -qiE 'Protected|Reconnect|Connecting' || break
        [ $((t % 60)) = 0 ] && never_direct "path lost, $t s (${st:-no session line})"
        sleep 15; t=$((t + 15))
      done
      info 'session state when dvpnd stopped reconnecting' "${st:-no session line} after ${t} s"
      check 'dvpnd gave up reconnecting within 540 s (else this case proves nothing)' bash -c "[ $t -lt 540 ]"
      check 'reconnects exhausted: pf anchor still blocks (fail closed)' anchor_blocks
      never_direct 'reconnects exhausted' ;;
    ks-exhausted:after) # the driver has lifted the host block: the node answers again
      hold
      check 'node reachable again: pf anchor still blocks until Restore network' anchor_blocks
      never_direct 'node reachable again, no session'
      run 0 '-' 'status shows the held block (recorded)' -- status ;;
    ks-exhausted:close)
      run 0 '-' 'restore network' -- daemon restore-network; sleep 3
      check 'restore network releases the block' bash -c "for i in 1 2 3 4 5; do [ \"\$(curl -4 -s -m 8 https://api.ipify.org)\" = '$DIRECT' ] && exit 0; sleep 3; done; exit 1"
      run 0 '-' 'kill switch off' -- daemon set --kill-switch off --yes ;;
    # deposit-out (DIR 10-29; FLX2 found RC3 Linux lifts the whole kill switch when a session ends by itself):
    # a 1 GB deposit used up by downloads, dvpnd ends the session. KS off = positive control (direct after);
    # KS on = 30 s of samples: pf anchor loaded and blocking, egress never direct, an IPv6 probe blocked.
    ks-deposit-out:run)
      faulted_live
      local ks i st bad v6a
      v6a=$(curl -6 -s -m 8 https://api64.ipify.org)
      info 'direct IPv6 before any session (the v6 probe below proves nothing if none)' "${v6a:-none}"
      for ks in off on; do
        rig_safe "$ks"
        connect_p "$P" || { restore; continue; } # 1 GB per-GB deposit (connect_p default)
        sleep 4
        check "[ks $ks] egress = node" egress_is_node "$P"
        [ "$ks" = on ] && check '[ks on] pf anchor dvpnd holds before the deposit runs out' anchor_blocks
        i=0
        while [ $i -lt 15 ]; do # 15 x 100 MB > the 1 GB paid
          hold; fetch_bytes 100000000 -m 180 -o /dev/null; i=$((i + 1))
          $CLI status 2>/dev/null | grep -qE '^Session +Not connected' && break
        done
        sleep 10; hold
        st=$($CLI status 2>/dev/null | grep -E '^Session ' | head -1)
        info "[ks $ks] after $i x 100 MB" "${st:-no session line}; last end: $(sudo -n grep -F '"ending the session"' "$DVPND_LOG" | tail -1 | grep -oE '"reason":"[^"]*"')"
        check "[ks $ks] the deposit ran out and dvpnd ended the session by itself" bash -c "printf '%s' '$st' | grep -qE 'Not connected'"
        # On = persist since 97eb1077. Per FMC (cb33092e issuer.go:550, session.go:404-405, issuer.go:272): a node close
        # (escrow exhausted or any node reason) releases the block in every mode; only "reconnect attempts exhausted"
        # (a dead tunnel, no close seen) keeps it under persist until Restore network.
        end=$(sudo -n grep -F '"ending the session"' "$DVPND_LOG" | tail -1 | grep -oE '"reason":"[^"]*"')
        held=0
        [ "$ks" = on ] && printf '%s' "$end" | grep -qiE 'reconnect attempts exhausted|connection lost' && held=1
        info "[ks $ks] end reason $end -> expect $([ $held = 1 ] && echo 'block held until Restore network' || echo 'normal internet')" ''
        if [ "$held" = 0 ]; then
          check "[ks $ks] direct again after the session ended (node close: ${end:-no reason})" bash -c "for i in 1 2 3 4 5 6; do [ \"\$(curl -4 -s -m 8 https://api.ipify.org)\" = '$DIRECT' ] && exit 0; sleep 5; done; exit 1"
          [ "$ks" = on ] && { run 0 '-' 'restore network (tidy, no block expected)' -- daemon restore-network; sleep 3; }
        else
          bad=0
          for i in 1 2 3 4 5 6 7 8 9 10; do # ~30 s of samples
            hold
            anchor_blocks >/dev/null 2>&1 || { bad=1; info "sample $i" 'pf anchor NOT blocking'; }
            st=$(curl -4 -s -m 2 https://api.ipify.org) # no session + KS on: ANY answer is a leak (direct or a third IP)
            [ -n "$st" ] && { bad=1; info "sample $i" "IPv4 egress answered: $st$([ "$st" = "$DIRECT" ] && echo ' (DIRECT)')"; }
            [ -n "$(curl -6 -s -m 2 https://api64.ipify.org)" ] && { bad=1; info "sample $i" 'IPv6 probe answered'; }
            sleep 1
          done
          fx_line "egress none during 30 s after the deposit ran out (direct $DIRECT never seen: $([ $bad = 0 ] && echo yes || echo NO))"
          check '[ks on] 30 s after the deposit ran out: anchor loaded, never direct, IPv6 blocked (every sample)' test "$bad" = 0
          run 0 '-' 'restore network' -- daemon restore-network; sleep 3
          check '[ks on] restore network releases the block' bash -c "for i in 1 2 3 4 5; do [ \"\$(curl -4 -s -m 8 https://api.ipify.org)\" = '$DIRECT' ] && exit 0; sleep 3; done; exit 1"
        fi
        sleep 7
      done
      rig_safe off ;;
    # rpcdown: the Solana RPC names stop resolving mid-session; the tunnel must carry on.
    ks-rpcdown:run)
      rig_safe on
      connect_p "$P" || { restore; return; }
      sleep 4; hold
      sudo cp /etc/hosts "$OUT/hosts.bak"
      printf '\n0.0.0.0 api.devnet.solana.com\n0.0.0.0 devnet.helius-rpc.com\n' | sudo tee -a /etc/hosts >/dev/null
      sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder 2>/dev/null
      sleep 60
      check 'RPC names unresolvable for 60 s: traffic still through the server' egress_is_node "$P"
      run 0 '-' 'status still answers with the RPC unreachable' -- status
      check 'status copy is plain' plain_copy "$LAST"
      sudo cp "$OUT/hosts.bak" /etc/hosts; sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder 2>/dev/null
      sleep 5
      check 'RPC back: traffic still through the server' egress_is_node "$P"
      run 0 '-' 'disconnect' -- disconnect; sleep 3
      run 0 '-' 'restore network' -- daemon restore-network; sleep 3
      run 0 '-' 'kill switch off' -- daemon set --kill-switch off --yes ;;

    # ─── safety (twin of vm-safety-test.ps1 drivers / armed) ───
    # drivers (once): a service tool goes missing → `daemon drivers` says so → repair puts it back.
    safety-drivers:run)
      local T=/usr/local/lib/devnet-dvpn/tools
      sudo mv "$T/amneziawg-go" "$T/amneziawg-go.ddv-moved"
      run 0 'AmneziaWG.*(missing|FAIL)|repair-drivers' 'drivers notices AmneziaWG missing' -- daemon drivers
      check 'the missing line names AmneziaWG' bash -c "printf '%s' \"\$1\" | grep -Eq '^(miss|FAIL) +AmneziaWG'" _ "$LAST"
      run 0 'ready' 'repair-drivers puts it back (cached build, one admin step)' -- daemon repair-drivers --yes
      check 'amneziawg-go back in the service folder, root-owned' bash -c "[ -x $T/amneziawg-go ] && [ \"\$(stat -f %Su $T/amneziawg-go)\" = root ]"
      sudo rm -f "$T/amneziawg-go.ddv-moved"
      connect_p amneziawg && { check 'an AmneziaWG session works after the repair' egress_is_node amneziawg; run 0 '-' 'disconnect' -- disconnect; sleep 3; } ;;
    # armed (once): uninstall while "Always" holds the block → network fully back → reinstall.
    safety-armed:run)
      rig_safe persist
      connect_p wireguard || { restore; return; }
      sleep 4; hold
      check 'persist armed: pf anchor blocks' anchor_blocks
      run 0 '-' 'daemon uninstall while the kill switch is armed' -- daemon uninstall --yes
      sleep 5
      check 'internet direct after uninstall' bash -c "for i in 1 2 3 4 5; do [ \"\$(curl -4 -s -m 8 https://api.ipify.org)\" = '$DIRECT' ] && exit 0; sleep 3; done; exit 1"
      check 'no pf rules left in the dvpnd anchor' bash -c "[ \$(sudo pfctl -a dvpnd -s rules 2>/dev/null | grep -c .) = 0 ]"
      check 'no tunnel interface left' bash -c "[ -z \"\$(ifconfig -l | tr ' ' '\n' | grep '^utun' | grep -vxF -f '$OUT/utun-base.txt')\" ]"
      check 'system DNS back' dns_back
      check 'service gone from launchd' bash -c "! sudo launchctl print system/$LABEL >/dev/null 2>&1"
      run 0 '-' 'daemon install puts the service back' -- daemon install --yes
      sleep 8
      run 0 'OK' 'service answers after the reinstall' -- daemon version
      # dvpnd keeps a persist kill switch in its database: uninstall must release it there too
      check 'reinstall: no kill switch re-armed (dvpnd anchor empty)' bash -c "[ \$(sudo pfctl -a dvpnd -s rules 2>/dev/null | grep -c .) = 0 ]"
      check 'reinstall: internet direct' bash -c "for i in 1 2 3; do [ \"\$(curl -4 -s -m 8 https://api.ipify.org)\" = '$DIRECT' ] && exit 0; sleep 3; done; exit 1"
      run 0 '-' 'kill switch off' -- daemon set --kill-switch off --yes ;;

    # ─── A18: allow LAN (run detached by the driver: LAN off cuts the rig link) ───
    lan:run)
      run 0 '-' 'kill switch on, LAN off' -- daemon set --kill-switch on --allow-lan false --yes
      connect_p "$P" || { restore; return; }
      sleep 5
      check 'LAN off: the LAN host (10.0.2.2:22) is blocked' bash -c '! nc -z -G 3 10.0.2.2 22'
      never_direct 'LAN off: internet only through the node'
      run 0 '-' 'allow LAN on (live)' -- daemon set --allow-lan true --yes; restarted_live
      sleep 5
      check 'LAN on: the LAN host is reachable' nc -z -G 3 10.0.2.2 22
      # a settings change restarts dvpnd, which ends the session cleanly and releases the "On" block
      # (dvpnd recover.go: only a run that died mid-session keeps it), so reconnect with LAN on first
      live_again
      check 'LAN on: internet still only through the node' egress_is_node "$P"
      run 0 '-' 'disconnect' -- disconnect; sleep 3
      run 0 '-' 'kill switch off' -- daemon set --kill-switch off --yes ;;

    # ─── A21: split by route without the kill switch ───
    split-route:run)
      local r; r=$(ipify_routes)
      run 0 '-' "split include $r" -- daemon set --kill-switch off --split-mode include --split-routes "$r" --yes
      connect_p "$P" || { restore; return; }
      sleep 5
      check 'include: chosen route (ipify) exits at the node' egress_is_node "$P"
      check 'include: other sites (amazonaws) go direct' bash -c "[ \"\$(curl -4 -s -m 12 https://checkip.amazonaws.com | tr -d '\n')\" = '$DIRECT' ]"
      run 0 '-' 'disconnect' -- disconnect; sleep 3; gap
      run 0 '-' "split exclude $r" -- daemon set --split-mode exclude --split-routes "$r" --yes
      connect_p "$P" || { restore; return; }
      sleep 5
      check 'exclude: excluded route (ipify) goes direct' bash -c "[ \"\$(curl -4 -s -m 12 https://api.ipify.org)\" = '$DIRECT' ]"
      if is_proxy "$P"; then
        check 'exclude: other sites through the proxy exit at the node' bash -c "[ \"\$(curl -4 -s -m 12 --socks5-hostname $(socks) https://checkip.amazonaws.com | tr -d '\n')\" = '$NODE_IP' ]"
      else
        info 'exclude: other site (amazonaws) observed egress' "$(other_egress)"
        check 'exclude: other sites (amazonaws) exit at the node' bash -c "[ \"\$(curl -4 -s -m 12 https://checkip.amazonaws.com | tr -d '\n')\" = '$NODE_IP' ]"
      fi
      run 0 '-' 'disconnect' -- disconnect; sleep 3
      run 0 '-' 'split off' -- daemon set --split-mode off --split-routes none --yes ;;

    # ─── A22: split by route + kill switch (pf passes the split; chosen traffic fails closed) ───
    split-ks:run)
      local r; r=$(ipify_routes)
      run 0 '-' 'split include (ipify) + kill switch on (LAN on)' -- daemon set --kill-switch on --allow-lan true --split-mode include --split-routes "$r" --yes
      connect_p "$P" || { restore; return; }
      sleep 5
      check 'chosen route exits at the node' egress_is_node "$P"
      run 0 '-' 'status (recorded: what the split does under the kill switch)' -- status
      info 'status text' "$LAST"
      info 'other site (amazonaws) egress' "$(other_egress)"
      check 'pf passes the split (table ddvsplit or permit rules present)' bash -c "sudo pfctl -a dvpnd -s rules | grep -qE 'ddvsplit|group'"
      run 0 '-' 'disconnect' -- disconnect; sleep 3
      run 0 '-' 'restore network' -- daemon restore-network; sleep 3
      run 0 '-' 'split off, kill switch off' -- daemon set --kill-switch off --split-mode off --split-routes none --yes ;;

    # ─── A20: split by app (curl chosen, Python not) ───
    split-app:run)
      # macOS split apps are bundle executables (app + dvpnd rule): Firefox is the chosen app, curl the other
      local CH="$PROBE_APP" ip
      # Q0019 evidence: ipify (104.26.x / 172.67.x) sockets with local address + pid, and live Firefox pids
      sdiag() { info "split diag $1 @$(date -u +%H:%M:%SZ)" "$(netstat -anv -p tcp 2>/dev/null | grep -E '(104\.26\.|172\.67\.)[0-9.]+\.443 ' | awk '{print $4, $5, $6, "pid=" $11}' | tr '\n' ';') firefox: $(pgrep -f "$PROBE_APP" | tr '\n' ' ')"; }
      # Q0019: who pulls MBs in the first second of a session (before the split router is up)? Per-process bytes
      # (nettop) + established TCP at connect start and +1/+3/+6 s, kept as $OUT/split-net-<label>.txt
      nsamp() { ( f="$OUT/split-net-$P-$1.txt"; : > "$f"; t=$(date +%s)
        for s in 0 1 3 6 10; do while [ "$(date +%s)" -lt $((t + s)) ]; do sleep 0.2; done
          { echo "=== +${s}s $(date -u +%H:%M:%SZ)"; nettop -P -L 1 -x -J bytes_in,bytes_out 2>&1 | awk -F, 'NR==1 || $2+0 > 20000' | head -25
            netstat -anv -p tcp 2>/dev/null | grep ESTABLISHED | awk '{print $4, $5, "pid=" $11}' | head -30; } >> "$f" 2>&1
        done ) & }
      # Q0019 (FMC): which utun the split router's /1../32 pieces point at, and whether they outlive a disconnect
      rsnap() { { echo "=== $1 $(date -u +%H:%M:%SZ)"; netstat -rn -f inet 2>/dev/null | head -90
        ifconfig 2>/dev/null | grep -A3 '^utun'; } >> "$OUT/split-routes-$P.txt" 2>&1; }
      nlog() { log show --last 40s --predicate 'process == "softwareupdated" OR process == "mobileassetd" OR process == "nsurlsessiond"' 2>/dev/null | tail -20 > "$OUT/split-oslog-$P-$1.txt"; }
      run 0 '-' 'split include Firefox' -- daemon set --kill-switch off --split-mode include --split-apps "$CH" --yes
      # Strict first-minute probes (one try each, no retry): Xray caches local addresses for 60 s on
      # its first process lookup, and a miss in that window sent every app the default way (#31 gap #72)
      nsamp include; connect_p "$P" || { restore; return; }
      local t0; t0=$(date +%s)
      rsnap "include, after connect"; sdiag "include, before probes"; ip=$(app_ip); sdiag "include, after Firefox"; rsnap "include, after Firefox"; check "include, first minute: chosen app (Firefox) exits at the node ($ip)" test "$ip" = "$NODE_IP"
      ip=$(curl -4 -s -m 12 https://api.ipify.org); check "include, first minute: other app (curl) goes direct ($ip)" test "$ip" = "$DIRECT"
      info 'first-minute probes done' "$(( $(date +%s) - t0 )) s after connect"
      run 0 '-' 'split status (recorded)' -- split status
      info 'split status' "$LAST"
      sleep 60
      ip=$(app_ip); check "include, after a minute: chosen app (Firefox) exits at the node ($ip)" test "$ip" = "$NODE_IP"
      run 0 '-' 'disconnect' -- disconnect; sleep 3; rsnap 'after include disconnect'
      run 0 '-' 'split exclude Firefox' -- daemon set --split-mode exclude --split-apps "$CH" --yes
      nsamp exclude; connect_p "$P" || { restore; return; }
      rsnap "exclude, after connect"; sdiag "exclude, before probes"; ip=$(app_ip); sdiag "exclude, after Firefox"; rsnap "exclude, after Firefox"; check "exclude, first minute: excluded app (Firefox) goes direct ($ip)" test "$ip" = "$DIRECT"
      ip=$(curl -4 -s -m 12 https://api.ipify.org); check "exclude, first minute: other app (curl) exits at the node ($ip)" test "$ip" = "$NODE_IP"
      wait; nlog exclude
      run 0 '-' 'disconnect' -- disconnect; sleep 3; rsnap 'after exclude disconnect'
      run 0 '-' 'split off' -- daemon set --split-mode off --split-apps none --yes
      check 'a non-bundle path is refused in plain words (exit 3, a usage error)' bash -c "out=\$($CLI daemon set --split-mode include --split-apps /usr/bin/curl --yes 2>&1); [ \$? = 3 ] && printf '%s' \"\$out\" | grep -qi 'app'" ;;

    # ─── A28: node unreachable 75 s (driver cuts it), NIC unplugged, VM paused (sleep) ───
    reconnect:a|flap:a|pause:a)
      faulted_live
      connect_p "$P" || { restore; return; }
      sleep 4
      check 'egress = node' egress_is_node "$P"
      sid_now > "$OUT/$CASE.$P.sid"; info 'session id before' "$(cat "$OUT/$CASE.$P.sid")" ;;
    reconnect:b|flap:b|pause:b)
      run 0 '-' 'status after the fault cleared (recorded)' -- status
      info 'status after' "$LAST"
      info 'session id after' "$(sid_now) (before $(cat "$OUT/$CASE.$P.sid" 2>/dev/null))"
      [ "$CASE" != reconnect ] && check 'session works again after the fault' egress_is_node "$P"
      run 0 '-' 'disconnect stops whatever session is live' -- disconnect; sleep 3
      check 'no session left in status' bash -c "! $CLI status --json 2>/dev/null | grep -qE '\"phase\"\s*:\s*\"(connected|connecting)\"'" ;;

    # ─── A9: --switch to every other protocol, no direct gap ───
    switch:run)
      connect_p "$P" || { restore; return; }
      restarted_live # every --switch stops the old session on purpose (its final voucher: #77)
      sleep 4
      local q
      for q in $ALL_PROTOCOLS; do
        [ "$q" = "$P" ] && continue
        gap
        hold
        run 0 'Connected|connected' "--switch $P → $q" -- connect "$(node_of "$q")" --units 1 --switch --yes
        sleep 4
        check "after --switch to $q: egress = node" egress_is_node "$q"
        run 0 "$q" "status names $q" -- status
      done
      run 0 '-' 'disconnect' -- disconnect; sleep 3 ;;

    # ─── gap #67 on macOS: --switch with the kill switch on never leaves directly ───
    ks-switch:run)
      rig_safe on
      connect_p "$P" || { restore; return; }
      sleep 4
      local samples="$OUT/ks-switch.$P.samples" sp q
      : > "$samples"
      # the flag first: the loop checks it on its first pass (run 3: the loop exited at once, 0 samples)
      touch "$OUT/ks-switch.sampling"
      ( while [ -f "$OUT/ks-switch.sampling" ]; do curl -4 -s -m 2 https://api.ipify.org >> "$samples" 2>/dev/null; echo >> "$samples"; sleep 0.5; done ) &
      sp=$!
      restarted_live # every --switch stops the old session on purpose (its final voucher: #77)
      for q in $ALL_PROTOCOLS; do
        [ "$q" = "$P" ] && continue
        gap; hold
        run 0 'Connected|connected' "kill switch on: --switch $P → $q" -- connect "$(node_of "$q")" --units 1 --switch --yes
        sleep 4
      done
      rm -f "$OUT/ks-switch.sampling"; wait "$sp" 2>/dev/null
      info 'egress samples (node / direct / none)' "$(grep -cx "$NODE_IP" "$samples") / $(grep -cx "$DIRECT" "$samples") / $(grep -cx '' "$samples")"
      check 'kill switch on through 5 switches: 0 samples left with the direct IP' bash -c "[ \$(grep -cx '$DIRECT' '$samples') = 0 ]"
      check 'positive control: the sampler saw the node' bash -c "[ \$(grep -cx '$NODE_IP' '$samples') -gt 0 ]"
      run 0 '-' 'disconnect' -- disconnect; sleep 3
      run 0 '-' 'restore network' -- daemon restore-network; sleep 3
      run 0 '-' 'kill switch off' -- daemon set --kill-switch off --yes ;;

    # ─── A6 + A23: coverage is honest; system proxy on/off restores exactly ───
    coverage:run)
      run 0 '-' 'whole device on' -- daemon set --whole-device true --yes
      connect_p "$P" || { restore; return; }
      sleep 8
      check 'whole device: coverage = device' bash -c "$CLI status --json | grep -qE '\"coverage\"\s*:\s*\"device\"'"
      run 0 '-' 'disconnect' -- disconnect; sleep 3
      case $P in v2ray|xray) ;; *) return ;; esac
      gap
      run 0 '-' 'whole device off (SOCKS proxy only)' -- daemon set --whole-device false --yes
      connect_p "$P" || { restore; return; }
      sleep 8
      # proxyOnConnect is on by default: connect set the system proxy (proxy-apps). Turn it off first.
      run 0 '-' 'system proxy off (proxy-only session)' -- proxy off
      sleep 6
      info 'coverage now' "$($CLI status --json 2>/dev/null | grep -oE '"coverage" *: *("[a-z-]+"|null)')"
      check 'proxy, system proxy off: coverage = proxy-only (never "device")' bash -c "$CLI status --json | grep -qE '\"coverage\"\s*:\s*\"proxy-only\"'"
      check 'proxy, system proxy off: a plain request still goes direct (that is what proxy-only means)' bash -c "[ \"\$(curl -4 -s -m 12 https://api.ipify.org)\" = '$DIRECT' ]"
      run 0 '-' 'proxy on (A23)' -- proxy on --yes
      sleep 3
      check 'every network service: SOCKS proxy = 127.0.0.1 (networksetup)' bash -c "$(declare -f services); services | while read -r s; do networksetup -getsocksfirewallproxy \"\$s\" | grep -q 'Server: 127.0.0.1' || { echo \"\$s\"; exit 1; }; done"
      check 'NSURLSession (uses the system proxy) exits at the node' bash -c "for i in 1 2 3; do nscurl https://api.ipify.org 2>/dev/null | grep -qF '$NODE_IP' && exit 0; sleep 3; done; exit 1"
      sleep 6
      check 'proxy on: coverage = proxy-apps' bash -c "$CLI status --json | grep -qE '\"coverage\"\s*:\s*\"proxy-apps\"'"
      run 0 '-' 'proxy off' -- proxy off
      check 'proxy off: every service back exactly as before the run' bash -c "$(declare -f services proxy_snapshot); proxy_snapshot | diff - '$OUT/proxy-base.txt'"
      run 0 '-' 'proxy on again, then disconnect (disconnect must put it back too)' -- proxy on --yes
      run 0 '-' 'disconnect' -- disconnect; sleep 3
      run 0 '-' 'whole device on again' -- daemon set --whole-device true --yes ;;

    # ─── A24: 100 MB through the session with no stall; tunnel MTU ───
    # gap #73: a slow app left bytes the node had counted in the client's receive window; the
    # usage audit ended V2Ray sessions "node overcharging". Two slow readers for ~3 min must not.
    slowread:run)
      connect_p "$P" || { restore; return; }
      sleep 4
      local a b i sa sb
      fetch_bytes 7200000 -m 260 --limit-rate 40k -o /dev/null -w '%{size_download} curl_exit=%{exitcode} %{time_total}s' > "$OUT/slow-a" & a=$!
      fetch_bytes 1800000 -m 260 --limit-rate 10k -o /dev/null -w '%{size_download}' > "$OUT/slow-b" & b=$!
      for i in 1 2 3 4 5 6; do sleep 30; $CLI status 2>/dev/null | grep -q '^Session  Protected' || break; done
      wait "$a" "$b"; sa=$(cat "$OUT/slow-a"); sb=$(cat "$OUT/slow-b")
      info 'slow reader 40 KB/s: bytes, curl exit, seconds (a short read names who closed it)' "$sa"
      sa=${sa%% *}
      info 'slow readers: bytes at 40 KB/s, at 10 KB/s' "$sa $sb"
      check 'session still connected after ~3 min of slow readers' bash -c "$CLI status | grep -q '^Session  Protected'"
      check 'the 40 KB/s reader got its 7.2 MB' test "${sa:-0}" = 7200000
      check 'no node overcharging / usage audit end in dvpnd' bash -c "! sudo tail -n +\$(( \$(cat '$OUT/$CASE.$P.mark' 2>/dev/null || echo 0) + 1 )) '$DVPND_LOG' | grep -iE 'overcharg|usage audit'"
      restore ;;

    throughput:run)
      connect_p "$P" || { restore; return; }
      sleep 4
      # Cloudflare's test endpoint refuses more than 25 MB per request (403): 4 × 25 MB = 100 MB
      local r i tb=0 tt=0 b t
      for i in 1 2 3 4; do
        r=$(fetch_bytes 25000000 -m 150 -o /dev/null -w '%{size_download} %{time_total}')
        b=${r%% *}; t=${r##* }; tb=$((tb + ${b:-0})); tt=$(awk -v a="$tt" -v b="${t:-0}" 'BEGIN{print a+b}')
      done
      info '100 MB: bytes, seconds, Mbit/s' "$tb $tt $(awk -v b="$tb" -v t="$tt" 'BEGIN{if (t>0) printf "%.1f", b*8/t/1e6; else print 0}')"
      check '100 MB download completes through the session' test "$tb" = 100000000
      local l; l=$(tunnel_link)
      if [ -n "$l" ]; then info "MTU of $l" "$(ifconfig "$l" | awk '/mtu/{print $NF; exit}')"; fi
      # 1252 + 28 header bytes = a 1280-byte packet with Don't Fragment set
      case $P in
        wireguard|amneziawg|openvpn) check 'a 1280-byte DF packet passes the tunnel (ping -D -s 1252)' ping -D -s 1252 -c 3 -t 10 1.1.1.1 ;;
        *) info 'ICMP through a proxy-engine tunnel (not required)' "$(ping -D -s 1252 -c 2 -t 6 1.1.1.1 2>&1 | tail -2 | tr '\n' ' ')" ;;
      esac
      run 0 '-' 'disconnect' -- disconnect; sleep 3 ;;

    # ─── A26: the copy for each close reason the user can cause on this rig ───
    close:run)
      connect_p "$P" || { restore; return; }
      sleep 4
      run 0 '-' 'user disconnect' -- disconnect; sleep 3
      run 0 'Not connected|idle|Disconnected|disconnected' 'status after a user disconnect says not connected' -- status
      info 'status text (user stop)' "$LAST"
      gap
      connect_p "$P" || { restore; return; }
      sleep 4
      restarted_live; hold; sudo launchctl stop "$LABEL" 2>/dev/null; sudo launchctl kill SIGTERM "system/$LABEL"; sleep 3
      run 0 '-' 'status while the service restarts (recorded copy)' -- status
      info 'status text (service stopped)' "$LAST"
      check 'launchd brings dvpnd back (answers the CLI)' svc_back
      sleep 10
      run 0 '-' 'status after the service came back (recorded copy)' -- status
      info 'status text (service back)' "$LAST"
      run 0 '-' 'disconnect' -- disconnect; sleep 3 ;;

    # ─── A29: crash leftovers — dvpnd and the protocol process killed together ───
    crash:run)
      connect_p "$P" || { restore; return; }
      sleep 4
      hold
      local pids; pids=$(proto_pids "$P" | tr '\n' ' ')
      info 'killing dvpnd + protocol process' "${pids:-no protocol process}"
      restarted_live; proto_killed; sudo launchctl kill SIGKILL "system/$LABEL"; [ -n "$pids" ] && sudo kill -9 $pids
      check 'launchd brings dvpnd back (answers the CLI)' svc_back
      sleep 5
      run 0 '-' 'status after the crash (recorded)' -- status
      info 'status after the crash' "$LAST"
      run 0 '-' 'disconnect (whatever is left)' -- disconnect; sleep 3
      run 0 '-' 'restore network' -- daemon restore-network; sleep 3 ;;

    # ─── CF6 keepalive: idle 5 min mid-session (no traffic of ours), then traffic must flow at once ───
    keepalive:run)
      case $P in wireguard|amneziawg) ;; *) info 'keepalive' 'n/a: not a WireGuard protocol'; return ;; esac
      connect_p "$P" || { restore; return; }
      check 'egress is the node before idling' egress_is_node "$P"
      info 'idle' "300 s from $(date -u +%T)"; sleep 300
      local t0 e; t0=$(date +%s); e=$(egress_p "$P")
      info 'first request after idle' "egress=$e in $(( $(date +%s) - t0 )) s"
      check 'after 5 min idle: first request goes out via the node' test "$e" = "$NODE_IP"
      check 'after 5 min idle: session still live' bash -c "$CLI status --json | grep -qiE '\"(state|status)\"\s*:\s*\"(connected|active)\"'"
      run 0 '-' 'disconnect' -- disconnect; sleep 3 ;;

    # ─── T13: no session config or secret left in dvpnd's home after disconnect ───
    wipe:run)
      sudo touch "$OUT/wipe.mark"; sleep 1
      connect_p "$P" || { restore; return; }
      sleep 4
      info 'files written during the session' "$(sudo find /var/db/dvpnd -type f -newer "$OUT/wipe.mark" ! -name 'data.db*' ! -name '*.log' ! -path '*/keys/*' 2>/dev/null | tr '\n' ' ')"
      run 0 '-' 'disconnect' -- disconnect; sleep 5
      local left; left=$(sudo find /var/db/dvpnd -type f -newer "$OUT/wipe.mark" ! -name 'data.db*' ! -name '*.log' ! -name '*.token' ! -path '*/keys/*' 2>/dev/null)
      info 'left after disconnect' "${left:-none}"
      check 'after disconnect: no session config file left' test -z "$left"
      check 'after disconnect: no tunnel secret on disk' bash -c "! sudo grep -rlsE 'PrivateKey|private_key|\"password\"|\"id\" *: *\"[0-9a-f]{8}-' /var/db/dvpnd/client --exclude='data.db*' --exclude='*.log' --exclude-dir=keys" ;;

    # ─── D6: another VPN owns the default route (a foreign wireguard-go utun with 0/1 + 128/1) ───
    rival:run)
      hold
      local wg=/usr/local/bin/wireguard-go nf=/tmp/ddv-rival.name rv
      [ -x "$wg" ] || { record FAIL 'rival tunnel tool present' "$wg missing"; return; }
      sudo rm -f "$nf"; sudo env WG_TUN_NAME_FILE="$nf" "$wg" utun >/dev/null 2>&1; sleep 2
      rv=$(sudo cat "$nf" 2>/dev/null)
      [ -n "$rv" ] || { record FAIL 'rival tunnel up' 'wireguard-go made no utun'; return; }
      sudo ifconfig "$rv" inet 10.250.0.2 10.250.0.1 up
      sudo route -q -n add -net 0.0.0.0/1 -interface "$rv"; sudo route -q -n add -net 128.0.0.0/1 -interface "$rv"
      info 'rival tunnel' "$rv owns 0/1 + 128/1; direct egress now: $(egress || echo none)"
      # The rival is on and broken (no peer): like Windows vm-rival-test, either we connect via the
      # node or refuse in plain words within 150 s (it black-holes the Solana RPC too).
      local t0=$(date +%s); try_run 'connect with a rival VPN' -- connect "$(node_of "$P")" --units 1 --yes; local rc=$? secs=$(( $(date +%s) - t0 ))
      info 'connect with a rival VPN' "exit=$rc after ${secs}s $(printf '%s' "$LAST" | tail -c 300)"
      if [ $rc = 0 ]; then check 'with a rival VPN: our traffic goes via the node' egress_is_node "$P"
      else check 'with a rival VPN: the refusal is plain words' plain_copy "$LAST"
        check 'with a rival VPN: refused within 150 s' test "$secs" -le 150; fi
      run 0 '-' 'disconnect' -- disconnect; sleep 3
      check "after disconnect: the rival's routes are untouched" bash -c "netstat -rn -f inet | grep -E '^0/1 .*$rv' >/dev/null && netstat -rn -f inet | grep -E '^128.0/1 .*$rv' >/dev/null"
      sudo route -q -n delete -net 0.0.0.0/1 >/dev/null 2>&1; sudo route -q -n delete -net 128.0.0.0/1 >/dev/null 2>&1
      sudo pkill -f "[w]ireguard-go utun" ; sudo rm -f "/var/run/wireguard/$rv.sock" "$nf"; sleep 2
      sudo rm -f /var/run/ddv-deadman.hold ;;

    # ─── T10/T11: after a crash the proxy goes back to the user's OWN settings (SOCKS + PAC) ───
    proxy-crash:run)
      local s pac='http://127.0.0.1:8099/own.pac'
      services | while read -r s; do printf '%s|%s|%s\n' "$s" "$(networksetup -getsocksfirewallproxy "$s" | awk '/^Server:/{print $2}')" "$(networksetup -getsocksfirewallproxy "$s" | awk '/^Port:/{print $2}')"; done > "$OUT/proxy-orig.txt"
      services | while read -r s; do sudo networksetup -setsocksfirewallproxy "$s" 127.0.0.1 9050; sudo networksetup -setautoproxyurl "$s" "$pac"; done
      proxy_snapshot > "$OUT/proxy-own.txt"
      run 0 '-' 'system proxy on connect: on' -- settings set proxyOnConnect=true
      run 0 '-' 'whole device off (proxy mode)' -- daemon set --whole-device false --yes
      connect_p "$P" || { restore; return; }
      sleep 4
      info 'proxy during the session' "$(proxy_snapshot | head -1)"
      hold
      local pids; pids=$(proto_pids "$P" | tr '\n' ' ')
      restarted_live; proto_killed; sudo launchctl kill SIGKILL "system/$LABEL"; [ -n "$pids" ] && sudo kill -9 $pids
      check 'launchd brings dvpnd back (answers the CLI)' svc_back
      run 0 '-' 'disconnect after the crash' -- disconnect; sleep 3
      run 0 '-' 'proxy off' -- proxy off
      check "after the crash: every service has the user's own SOCKS + PAC back" bash -c "$(declare -f services proxy_snapshot); proxy_snapshot | diff - '$OUT/proxy-own.txt'"
      local sv h pt; while IFS='|' read -r sv h pt; do sudo networksetup -setsocksfirewallproxy "$sv" "${h:-}" "${pt:-0}" 2>/dev/null; sudo networksetup -setsocksfirewallproxystate "$sv" off; pac_clear "$sv"; sudo networksetup -setautoproxystate "$sv" off; done < "$OUT/proxy-orig.txt"
      run 0 '-' 'whole device back on' -- daemon set --whole-device true --yes
      check 'test proxy settings removed again (rig baseline)' bash -c "$(declare -f services proxy_snapshot); proxy_snapshot | diff -q - '$OUT/proxy-base.txt'"
      sudo rm -f /var/run/ddv-deadman.hold ;;

    # ─── Edge: a bad path (the driver sets loss / latency / a bandwidth cap on the host first) ───
    loss5:run|loss20:run|lat300:run|bw1m:run|mtu1280:run)
      faulted_live
      if [ "$CASE" = mtu1280 ]; then
        info 'mtu' "$NIC $(ifconfig "$NIC" | awk '/mtu/{print $NF; exit}') → 1280"; sudo ifconfig "$NIC" mtu 1280
      fi
      local t0 secs; t0=$(date +%s)
      connect_p "$P"; local rc=$?
      secs=$(( $(date +%s) - t0 )); info 'connect on the bad path' "exit=$rc in $secs s"
      if [ $rc = 0 ]; then
        check 'bad path: egress is the node' egress_is_node "$P"
        local got; got=$(if is_proxy "$P"; then fetch_bytes 1000000 -m 90 --socks5-hostname "$(socks)" -o /dev/null -w '%{size_download} %{time_total}'
          else fetch_bytes 1000000 -m 90 -o /dev/null -w '%{size_download} %{time_total}'; fi)
        info '1 MB download on the bad path' "$got"
        check 'bad path: a 1 MB download completes' test "${got%% *}" = 1000000
        run 0 '-' 'disconnect' -- disconnect; sleep 3
      else
        # 20 % loss may legitimately defeat a handshake; then the refusal must be plain and timely
        check 'bad path: the refusal is plain words' plain_copy "$LAST"
        check 'bad path: refused within 120 s' test "$secs" -le 120
        restore
      fi
      [ "$CASE" = mtu1280 ] && sudo ifconfig "$NIC" mtu 1500 ;;

    # ─── Edge Q0357: path-MTU black hole (host `bigudp`: UDP > 1280 B dropped both ways, no ICMP) ───
    # dvpnd (FAN 0001-0005) checks large packets AFTER Protected (2 x 10 s rounds, then the TCP MSS clamp +
    # a retry) and never fails a connect for them. The darwin clamp is not per protocol (FMC 10-30), so the rule
    # for EVERY protocol is: banner (Session.warning large-packets) <=> dvpnd logged "…the session stays up,
    # warned" or "…this OS has no clamp". WireGuard/AmneziaWG must also log "TCP MSS clamped and traffic passes"
    # and get the IPv4 routes via the tunnel at mtu 1200; IPv6 untouched. OpenVPN over TCP never meets bigudp
    # ("full-size requests pass", no banner). Kill switch off, then on; then the app.
    mtu-blackhole:run)
      faulted_live
      local ks t0 rc ut v6a rt i w out clamped warned
      local END_RE='TCP MSS clamped and traffic passes|still fail after clamping TCP|has no clamp|clamping TCP MSS failed|full-size requests pass|small packets stopped passing too'
      local WARN_RE='still fail after clamping TCP|has no clamp'
      v6a=$(curl -6 -s -m 8 https://api64.ipify.org)  # the guest's own IPv6 egress before any session (often none)
      info 'direct IPv6 before the session' "${v6a:-none}"
      for ks in off on; do
        rig_safe "$ks"
        t0=$(date +%FT%T)  # dvpnd logs local time
        connect_p "$P"; rc=$?
        check "[ks $ks] connect succeeds (large packets never fail a connect)" test "$rc" = 0 || { restore; continue; }
        i=0
        while [ $i -lt 50 ]; do # 2 x 10 s rounds + clamp + retry
          hold
          sudo -n grep -F '"time":"' "$DVPND_LOG" | awk -v t="$t0" 'substr($0, index($0,"\"time\":\"")+8, 19) >= t' > /tmp/ddv-mtu.log
          grep -qE "$END_RE" /tmp/ddv-mtu.log && break
          sleep 3; i=$((i + 3))
        done
        sleep 3 # the warning reaches the session after the log line
        w=$($CLI status --json 2>/dev/null | node -e 'let s = ""; process.stdin.on("data", (d) => s += d).on("end", () => { try { console.log(JSON.parse(s).session?.warning ?? "") } catch (e) { console.log("unparsable: " + e.message) } })')
        out=$(grep -oE "$END_RE" /tmp/ddv-mtu.log | head -1)
        clamped=no; grep -q 'TCP MSS clamped and traffic passes' /tmp/ddv-mtu.log && clamped=yes
        warned=no; grep -qE "$WARN_RE" /tmp/ddv-mtu.log && warned=yes
        info "[ks $ks] large-packet check after ${i} s" "outcome: ${out:-none}; rounds failed: $(grep -c 'a full-size request failed through the tunnel' /tmp/ddv-mtu.log); session.warning: '${w}'"
        check "[ks $ks] dvpnd's large-packet check reached an outcome within 50 s" test -n "$out"
        check "[ks $ks] banner <=> warned log line (warning '${w:-none}', warned=$warned)" \
          bash -c "if [ '$warned' = yes ]; then [ '$w' = large-packets ]; else [ -z '$w' ]; fi"
        [ "$P" = openvpn ] || check "[ks $ks] dvpnd: TCP MSS clamped and traffic passes" test "$clamped" = yes
        check "[ks $ks] the session stays Protected after the check" bash -c "$CLI status 2>/dev/null | grep -qE '^Session +Protected'"
        check "[ks $ks] HTTPS through the tunnel answers from the node (cloudflare trace ip=)" bash -c "curl -s -m 20 https://www.cloudflare.com/cdn-cgi/trace | grep -qx 'ip=$NODE_IP'"
        check "[ks $ks] egress = the node" egress_is_node "$P"
        ut=$(tunnel_link)
        if [ "$clamped" = yes ]; then
          for d in 1.1.1.1 200.1.1.1; do
            rt=$(route -n get -inet "$d" 2>/dev/null)
            info "route to $d" "$(printf '%s' "$rt" | awk '/interface:/{i=$2} /mtu/{getline; m=$7} END{print "interface " i " mtu " m}')"
            check "[ks $ks] route to $d goes via $ut at mtu 1200" bash -c "printf '%s' \"\$1\" | grep -q 'interface: $ut' && [ \"\$(printf '%s' \"\$1\" | awk '/mtu/{getline; print \$7}')\" = 1200 ]" _ "$rt"
          done
          check "[ks $ks] IPv6 untouched: $ut interface mtu is not the 1200 clamp" bash -c "! ifconfig '$ut' | grep -q 'mtu 1200\$'"
        fi
        if [ "$ks" = off ]; then
          check '[ks off] no direct IPv6 egress during the session' bash -c "v=\$(curl -6 -s -m 8 https://api64.ipify.org); [ -z \"\$v\" ] || [ \"\$v\" != '${v6a:-none}' ] || [ -z '$v6a' ]"
        fi
        run 0 '-' "[ks $ks] disconnect" -- disconnect; sleep 3
        rt=$(route -n get -inet 1.1.1.1 2>/dev/null)
        check "[ks $ks] after disconnect: 1.1.1.1 no longer via a tunnel, no 1200 left" bash -c "! printf '%s' \"\$1\" | grep -q 'interface: utun' && [ \"\$(printf '%s' \"\$1\" | awk '/mtu/{getline; print \$7}')\" != 1200 ]" _ "$rt"
      done
      # The app (KS on, as left above). "Checking the connection…" is the connect gate before Protected: dvpnd
      # logs no line for it (FMC 10-30), so the 100 ms in-page poll started before connect is the proof.
      # Banner: the count step's ok = shown; it must match dvpnd's warned line in this run's log.
      local scen uo="$OUT/ui-mtu-blackhole-$P" t1 seen shown
      t1=$(date +%FT%T)
      scen="watch=Checking the connection;connect-start=$(node_of "$P");wait-text=Protected:120;watched;sleep=55;shot=after-check;count=[data-session-warning=\"large-packets\"]:1;wait-text=Protected:5;disconnect"
      hold; rm -rf "$uo"; mkdir -p "$uo"
      DVPN_UI_SCENARIO="$scen" DVPN_UI_DIRECT_IP="$DIRECT" DVPN_UI_EXPECT_NODE_IP="$NODE_IP" \
        bash scripts/e2e/mac/ui-smoke.sh dark "$uo" > "$uo/smoke.log" 2>&1
      node -e 'const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const s = Array.isArray(r) ? r : (r.steps ?? []);
        for (const x of s) console.log(`  ui ${x.ok ? "ok  " : "FAIL"} ${x.step} :: ${String(x.detail ?? "").slice(0, 120)}`);' "$uo/scenario.json" 2>&1 | tee -a "$LOG"
      step_ok() { node -e 'const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const s = Array.isArray(r) ? r : (r.steps ?? []); const re = new RegExp(process.argv[2]); const w = s.filter((x) => re.test(x.step)); process.exit(w.length && w.every((x) => x.ok) ? 0 : 1);' "$uo/scenario.json" "$1"; }
      check '[ui] app: connect-start, Protected (twice), disconnect' step_ok '^(connect-start|wait-text|disconnect)'
      seen=no; step_ok '^watched' && seen=yes
      shown=no; step_ok '^count' && shown=yes
      sudo -n grep -F '"time":"' "$DVPND_LOG" | awk -v t="$t1" 'substr($0, index($0,"\"time\":\"")+8, 19) >= t' > /tmp/ddv-mtu-ui.log
      warned=no; grep -qE "$WARN_RE" /tmp/ddv-mtu-ui.log && warned=yes
      info '[ui] app run' "Checking the connection… seen by the 100 ms poll: $seen; banner shown: $shown; dvpnd warned: $warned; outcome: $(grep -oE "$END_RE" /tmp/ddv-mtu-ui.log | head -1)"
      # INFO only (FMC 10-30): the app learns "checking" by polling dvpnd every 1 s, and bigudp leaves small
      # packets alone, so the gate often passes in < 1 s and the label never shows, by design. The label is
      # proven in the checking-label case (600 ms netem: the gate surely takes > 1 s).
      check "[ui] banner [data-session-warning=large-packets] shown <=> dvpnd warned (shown=$shown warned=$warned)" test "$shown" = "$warned"
      restore
      rig_safe off ;;

    # ─── dns-forwarder (Q0365, FMC 10-30): during a session dvpnd runs a DNS forwarder on the session utun's own
    # IPv4:53 that races the configured servers; networksetup points every service at it. HNSDNS preset, KS on.
    # a: 10 connects (Protected < 5 s after the forwarder starts; first lookup < 1 s after Protected; log lines;
    #    after each disconnect DNS is back and nothing listens on :53), the 10th left up.
    # b: during it, lookups; dig @utun answers, dig @router/@8.8.8.8 fail at once. Host counts QEMU DNS = 0.
    # c: disconnect, KS off, positive control: dig @10.0.2.3 (slirp) must be counted on the host. d: verdicts. ───
    dns-forwarder:a)
      faulted_live
      local n a t0 tp tf tl ms dns0 lsn st
      # Q0267: the Handshake preset = 103.196.38.38, .39 + 1.1.1.1. An RC3 app still writes two, so a lab run
      # with only a new dvpnd puts the 3-server list in ~/matrix/dnsfwd.dns (FMC 10-30); the final build uses the preset.
      local dsv; dsv=$(cat ~/matrix/dnsfwd.dns 2>/dev/null); dsv=${dsv:-handshake}
      run 0 '-' "kill switch on, DNS $dsv, networksetup" -- daemon set --kill-switch on --allow-lan true --dns "$dsv" --dns-mode networksetup --yes
      dns0=$(services | while IFS= read -r s; do printf '%s=%s;' "$s" "$(networksetup -getdnsservers "$s" | tr '\n' ',')"; done)
      printf '%s' "$dns0" > "$OUT/dnsfwd.before"
      # 10 COUNTED connects. A session dvpnd's usage guard ends itself before the DNS read (rig slirp UDP loss,
      # Q0211: "local counter stalled") is skipped and replaced by an extra connect, at most 5 extras, so a rig that
      # keeps losing sessions FAILs instead of looping (FMC 10-30).
      local att=0 skips=0 sst gnum
      n=0
      while [ "$n" -lt 10 ] && [ "$att" -lt 15 ]; do
        att=$((att + 1)); n=$((n + 1))
        hold; sudo -n dscacheutil -flushcache; sudo -n killall -HUP mDNSResponder 2>/dev/null
        t0=$(date +%FT%T)
        connect_p "$P" || { check "[$n] connect" false; restore; continue; }
        tp=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
        dscacheutil -q host -a name example.com > /tmp/ddv-fwd-q.txt
        tl=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
        a=$(sudo -n grep -F 'dns forwarder racing' "$DVPND_LOG" | tail -1 | grep -oE 'addr.:.[0-9.]+:53' | grep -oE '[0-9.]+:53' | cut -d: -f1)
        # Q0377: on macOS the forwarder is 127.0.0.1:53 (a netstack TUN never delivers packets to its own address)
        check "[$n] the forwarder listens on 127.0.0.1 (Q0377; got ${a:-none})" test "$a" = 127.0.0.1
        # the DNS read right away (the full-log grep below is slow), with the session state at that moment
        local dnow; dnow=$(services | while IFS= read -r s; do printf '%s=%s;' "$s" "$(networksetup -getdnsservers "$s" | tr '\n' ',')"; done)
        sst=$($CLI status 2>/dev/null | grep -E '^Session' | head -1)
        sudo -n grep -F '"time":"' "$DVPND_LOG" | awk -v t="$t0" 'substr($0, index($0,"\"time\":\"")+8, 19) >= t' > /tmp/ddv-fwd.log
        if ! printf '%s' "$sst" | grep -qE 'Protected|Checking' && grep -q 'local counter stalled' /tmp/ddv-fwd.log; then
          gnum=$(grep -m1 'local counter stalled' /tmp/ddv-fwd.log | grep -oE 'node [0-9]+, local [0-9]+')
          info "[$n] SKIPPED (attempt $att): dvpnd's usage guard ended the session before the DNS read (rig UDP loss, Q0211)" "$gnum; host UdpRcvbuf drops are on n1 (nstat)"
          skips=$((skips + 1)); n=$((n - 1)); sleep 7; continue
        fi
        tf=$(grep -m1 'dns forwarder racing the session' /tmp/ddv-fwd.log | grep -oE '"time":"[^"]+"' | cut -d'"' -f4)
        ms=$(node -e 'const f = Date.parse(process.argv[1]); console.log(isNaN(f) ? "none" : String(Number(process.argv[2]) - f))' "$tf" "$tp")
        info "[$n] forwarder $a; Protected $ms ms after the forwarder line; first lookup $((tl - tp)) ms" "$(grep -m1 'dns forwarder racing' /tmp/ddv-fwd.log | grep -oE '"addr":"[^"]+"')"
        check "[$n] dvpnd: \"dns forwarder racing the session's servers\" addr=$a:53" bash -c "grep 'dns forwarder racing the session' /tmp/ddv-fwd.log | grep -qF '\"addr\":\"$a:53\"'"
        [ "$n" = 1 ] && info '[1] forwarder line' "$(grep -m1 'dns forwarder racing' /tmp/ddv-fwd.log | grep -oE '"servers":[^]]*]' | head -1)"
        check "[$n] dvpnd races 103.196.38.38, 103.196.38.39 and 1.1.1.1 (Q0267)" bash -c "l=\$(grep -m1 'dns forwarder racing' /tmp/ddv-fwd.log); for s in 103.196.38.38 103.196.38.39 1.1.1.1; do printf '%s' \"\$l\" | grep -qF \"\$s\" || exit 1; done"
        # lab runs 1+2: one connect in ten read the old DNS here. Retry 5 s and log what was there, so "late" and
        # "never" are told apart (FMC triage).
        printf '%s' "$dnow" | grep -qF "=$a," || info "[$n] services' DNS at Protected (not yet the forwarder)" "$dnow | scutil #1: $(scutil --dns | awk '/resolver #1/{f=1} f && /nameserver\[0\]/{print $3; exit}')"
        check "[$n] every service's DNS = the forwarder $a (within 5 s of Protected)" bash -c "for i in 1 2 3 4 5 6 7 8 9 10; do bad=0; while IFS= read -r s; do networksetup -getdnsservers \"\$s\" | grep -qx '$a' || bad=1; done < <(networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*'); [ \$bad = 0 ] && [ -n '$a' ] && exit 0; sleep 0.5; done; exit 1"
        check "[$n] scutil resolver #1 nameserver[0] = $a (within 5 s)" bash -c "for i in 1 2 3 4 5 6 7 8 9 10; do scutil --dns | awk '/resolver #1/{f=1} f && /nameserver\\[0\\]/{print \$3; exit}' | grep -qx '$a' && exit 0; sleep 0.5; done; exit 1"
        check "[$n] Protected < 5 s after the forwarder started (second-resolution log: $ms ms)" bash -c "[ '$ms' != none ] && [ '$ms' -lt 5000 ]"
        check "[$n] first lookup answered < 1 s after Protected ($((tl - tp)) ms)" bash -c "grep -q ip_address /tmp/ddv-fwd-q.txt && [ $((tl - tp)) -lt 1000 ]"
        echo "$a" > "$OUT/dnsfwd.addr"
        [ "$n" = 10 ] && break # the 10th stays up for b
        run 0 '-' "[$n] disconnect" -- disconnect; sleep 3
        sudo -n grep -F '"time":"' "$DVPND_LOG" | awk -v t="$t0" 'substr($0, index($0,"\"time\":\"")+8, 19) >= t' > /tmp/ddv-fwd.log
        st=$(grep 'dns forwarder stopped' /tmp/ddv-fwd.log | tail -1 | grep -oE '"(lookups|unanswered)":[0-9]+' | tr '\n' ' ')
        check "[$n] dvpnd: \"dns forwarder stopped\" with lookups/unanswered ($st)" bash -c "printf '%s' '$st' | grep -q lookups"
        lsn=$(sudo -n lsof -nP -iUDP:53 -iTCP:53 2>/dev/null | grep -F "$a:53" | head -1)
        check "[$n] after disconnect nothing listens on $a:53" test -z "$lsn"
        sleep 7
      done
      info "10 counted connects" "$n counted, $skips skipped by the usage guard, $att attempts"
      check "10 counted connects (skips replaced, at most 5 extras: $skips skipped)" test "$n" -ge 10 ;;
    dns-forwarder:b) # the host counter runs (c:start); the 10th session is up
      local a; a=$(cat "$OUT/dnsfwd.addr" 2>/dev/null); hold
      check 'session still Protected' bash -c "$CLI status 2>/dev/null | grep -qE '^Session +Protected'"
      local x; for x in example.com wikipedia.org ddv-$RANDOM.example.net cloudflare.com; do dscacheutil -q host -a name "$x" >/dev/null; curl -s -m 8 -o /dev/null "https://$x" ; done
      check "dig @$a (the forwarder) answers" bash -c "dig +time=2 +tries=1 @'$a' example.com A +short | grep -qE '^[0-9.]+$'"
      # A direct dig @8.8.8.8 rides the full tunnel (default route = utun), so an answer is fine; the host count
      # (0 during the session) is the leak verdict. No dig @<router>: on QEMU slirp 10.0.2.2:53 is the HOST's
      # resolver (LAN is allowed), which the host counter would see (lab run 2 counted exactly that 1 packet).
      local t0 t1
      t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000'); dig +time=2 +tries=1 @8.8.8.8 example.com > /tmp/ddv-dig.txt 2>&1; t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
      info 'dig @8.8.8.8 (through the tunnel)' "$((t1 - t0)) ms, $(grep -oE 'status: [A-Z]+|timed out|no servers could be reached' /tmp/ddv-dig.txt | head -1)"
      sleep 10 ;;
    dns-forwarder:c)
      local a; a=$(cat "$OUT/dnsfwd.addr" 2>/dev/null)
      run 0 '-' 'disconnect' -- disconnect; sleep 3
      check "after disconnect nothing listens on $a:53" bash -c "[ -z \"\$(sudo -n lsof -nP -iUDP:53 -iTCP:53 2>/dev/null | grep -F '$a:53')\" ]"
      run 0 '-' 'restore network' -- daemon restore-network; sleep 3
      run 0 '-' 'kill switch off' -- daemon set --kill-switch off --yes; sleep 3
      check 'after restore: every service DNS is back as before' bash -c "[ \"\$(cat '$OUT/dnsfwd.before')\" = \"\$(networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*' | while IFS= read -r s; do printf '%s=%s;' \"\$s\" \"\$(networksetup -getdnsservers \"\$s\" | tr '\n' ',')\"; done)\" ]"
      dig +time=2 +tries=1 @10.0.2.3 "ddv-ctl-$RANDOM.example.com" >/dev/null 2>&1; dig +time=2 +tries=1 @10.0.2.3 example.org >/dev/null 2>&1; sleep 3 ;;
    # e (DIR 10-30): KS OFF, a session up, a host route sends the HNSDNS server 103.196.38.38 out the card. The
    # forwarder pins every upstream socket to the utun (IP_BOUND_IF), so the lookups must still answer and the
    # host must count 0 DNS packets. Answers with 0 counted = pass; failures with 0 counted = product (FMC).
    dns-forwarder:e1)
      rig_safe off
      connect_p "$P" || { restore; return; }
      # the lab/final dvpnd shows "Checking" for a while after connect (Q0357): wait for Protected
      check '[ks off] session Protected (within 60 s)' bash -c "for i in \$(seq 1 30); do $CLI status 2>/dev/null | grep -qE '^Session +Protected' && exit 0; sleep 2; done; exit 1"
      $CLI status 2>/dev/null | grep -qE '^Session +Protected' && echo up > "$OUT/dnsfwd.e1up" || rm -f "$OUT/dnsfwd.e1up" ;;
    dns-forwarder:e2) # the host counter was read just before (connect noise discarded)
      local gw ok=0 x i
      gw=$(route -n get default -ifscope en0 2>/dev/null | awk '/gateway:/{print $2}')
      [ -n "$gw" ] || gw=$(netstat -rn -f inet | awk '$1 == "default" && $NF == "en0" {print $2; exit}')
      info '[ks off] en0 router' "${gw:-none}"
      # an UNSCOPED host route: a -ifscope en0 route only binds sockets scoped to en0, so the system route stays
      # the utun and the test proves nothing (lab run 3: route get said utun4)
      sudo -n route -n add -host 103.196.38.38 "$gw" > /tmp/ddv-rt.txt 2>&1
      local rif; rif=$(route -n get -inet 103.196.38.38 2>/dev/null | awk '/interface:/{print $2}')
      info '[ks off] route to 103.196.38.38 now' "$rif ($(tail -1 /tmp/ddv-rt.txt))"
      check '[ks off] the test route really sends 103.196.38.38 out the card (route get = en0)' test "$rif" = en0
      sudo -n dscacheutil -flushcache; sudo -n killall -HUP mDNSResponder 2>/dev/null
      for i in 1 2 3 4 5; do x="ddv-rt$i-$RANDOM.example.com"; [ "$i" = 1 ] && x=example.com; [ "$i" = 2 ] && x=wikipedia.org
        dscacheutil -q host -a name "$x" | grep -q ip_address && ok=$((ok + 1)); done
      # example.com / wikipedia.org must answer; the random names are NXDOMAIN (an answer, not an address)
      echo "$ok" > "$OUT/dnsfwd.e2ok"
      info '[ks off] lookups with 103.196.38.38 routed out the card' "$ok of 2 real names answered with an address"
      # the session must have lasted through the lookups, else the count proves nothing (lab run 2: dvpnd ended it at 9 s)
      $CLI status 2>/dev/null | grep -qE '^Session +Protected' || rm -f "$OUT/dnsfwd.e1up"
      check '[ks off] the session was still Protected after the lookups' test -f "$OUT/dnsfwd.e1up"
      sudo -n route -n delete -host 103.196.38.38 -ifscope en0 > /dev/null 2>&1; sudo -n route -n delete -host 103.196.38.38 > /dev/null 2>&1
      check '[ks off] the test route is removed' bash -c "! netstat -rn -f inet | grep -q '^103.196.38.38 '" ;;
    dns-forwarder:e3)
      run 0 '-' '[ks off] disconnect' -- disconnect; sleep 3 ;;
    dns-forwarder:d)
      local q s c; q=$(cat ~/matrix/hostdns.quiet 2>/dev/null); s=$(cat ~/matrix/hostdns.session 2>/dev/null); c=$(cat ~/matrix/hostdns.control 2>/dev/null)
      local k e2; k=$(cat ~/matrix/hostdns.ksoff 2>/dev/null); e2=$(cat "$OUT/dnsfwd.e2ok" 2>/dev/null)
      info 'host: KS off, 103.196.38.38 routed out the card' "${k:-unread} DNS packets counted; ${e2:-?} of 2 real names answered"
      check '[ks off] the session stayed up through the lookups (else the count below proves nothing)' test -f "$OUT/dnsfwd.e1up"
      check '[ks off] host: 0 DNS packets while the HNSDNS server was routed out the card (upstreams pinned to the utun)' bash -c "[ '${k:-x}' = 0 ]"
      check "[ks off] the lookups still answered (${e2:-0}/2; with 0 counted a failure here = IP_BOUND_IF needs a scoped route, product → FMC)" bash -c "[ '${e2:-0}' = 2 ]"
      info 'host: DNS packets the QEMU process sent' "quiet 20 s (session up, no lookups) ${q:-unread}; session lookups ${s:-unread}; positive control ${c:-unread}"
      fx_line "dns: ${s:-unread} DNS packets left the host from the guest during the session (control ${c:-unread})"
      check 'host positive control: a guest lookup to the slirp resolver IS counted' bash -c "[ '${c:-0}' -gt 0 ] 2>/dev/null"
      check 'host: 0 DNS packets from the guest during the session (KS on, forwarder)' bash -c "[ '${s:-x}' = 0 ]"
      rm -f ~/matrix/hostdns.* ; rig_safe off ;; # the next case's "defaults" step resets the DNS preset

    # ─── checking-label (Q0357 UI, FMC 10-30): the driver adds 600 ms netem delay (guest outbound), so dvpnd's
    # connect gate surely outlasts the app's 1 s poll. "Checking the connection…" must show before Protected,
    # for an app connect and for a CLI-started connect (the app polls the session every 1 s then too). ───
    checking-label:run)
      faulted_live
      local uo scen how sigd w0
      for how in app cli; do
        uo="$OUT/ui-checking-label-$how"; sigd="$uo/sig"; hold; rm -rf "$uo"; mkdir -p "$sigd"
        if [ "$how" = app ]; then
          scen="nav=Connect;watch=Checking the connection;connect-start=$(node_of "$P");wait-text=Protected:180;watched;shot=protected;disconnect"
        else # the harness connects from the CLI between signal and ack, while the app watches
          scen="nav=Connect;sleep=3;watch=Checking the connection;signal=cliconn;await=cliconn:240;wait-text=Protected:30;watched;shot=protected;disconnect"
        fi
        DVPN_UI_SIG_DIR="$sigd" DVPN_UI_SCENARIO="$scen" DVPN_UI_DIRECT_IP="$DIRECT" DVPN_UI_EXPECT_NODE_IP="$NODE_IP" \
          bash scripts/e2e/mac/ui-smoke.sh dark "$uo" > "$uo/smoke.log" 2>&1 &
        local up=$!
        if [ "$how" = cli ]; then
          w0=0; while [ ! -f "$sigd/cliconn" ] && [ $w0 -lt 180 ]; do hold; sleep 2; w0=$((w0 + 2)); done
          check '[cli] the app asked for the CLI connect (signal seen)' test -f "$sigd/cliconn"
          run 0 'Connected|connected' '[cli] connect from the CLI while the app is open' -- connect "$(node_of "$P")" --units 1 --yes
          date +%s000 > "$sigd/cliconn.ack"
        fi
        w0=0; while kill -0 $up 2>/dev/null && [ $w0 -lt 420 ]; do hold; sleep 5; w0=$((w0 + 5)); done
        kill $up 2>/dev/null
        node -e 'const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const s = Array.isArray(r) ? r : (r.steps ?? []);
          for (const x of s) console.log(`  ui ${x.ok ? "ok  " : "FAIL"} ${x.step} :: ${String(x.detail ?? "").slice(0, 120)}`);' "$uo/scenario.json" 2>&1 | tee -a "$LOG"
        check "[$how] \"Checking the connection…\" seen before Protected on a 600 ms path, then Protected and disconnect (every step ok)" \
          node -e 'const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const s = Array.isArray(r) ? r : (r.steps ?? []); process.exit(s.length && s.every((x) => x.ok) ? 0 : 1);' "$uo/scenario.json"
        $CLI status 2>/dev/null | grep -qE '^Session +Not connected' || run 0 '-' "[$how] disconnect (left over)" -- disconnect
        sleep 7
      done ;;

    # ─── Edge: UDP blocked / only TCP 443 open — connect works via the node or refuses fast and plainly ───
    udpblock:run|tcp443:run)
      faulted_live
      # A refusal is a correct outcome here (WG/AWG/OVPN/Hy2 over UDP when UDP is dropped), so the
      # connect itself is not a check: rig 1 r9 recorded 4 "exit 1, want 0" for plain refusals in 9-31 s.
      local t0 secs; t0=$(date +%s); hold
      try_run 'connect with the path restricted' -- connect "$(node_of "$P")" --units 1 --yes; local rc=$?
      secs=$(( $(date +%s) - t0 )); info 'connect with the path restricted' "exit=$rc in $secs s"
      if [ $rc = 0 ]; then
        check 'restricted path: "Connected" carries traffic via the node (no false Connected)' egress_is_node "$P"
        run 0 '-' 'disconnect' -- disconnect; sleep 3
      else
        check 'restricted path: the refusal is plain words' plain_copy "$LAST"
        check 'restricted path: refused within 90 s' test "$secs" -le 90
        restore
      fi ;;

    # ─── L2 split-dyn: the system proxy while things change (V2Ray/Xray proxy mode; #31 vm-split-dyn) ───
    sdyn-toggle:run)
      sdyn_begin
      connect_p "$P" || { restore; sdyn_end; return; }
      local sk bad=0 i dl; sk=$(socks)
      fetch_bytes 24000000 -m 150 --limit-rate 250K --socks5-hostname "$sk" -o /dev/null -w '%{size_download}' \
        > "$OUT/sdyn-dl.txt" 2>/dev/null &
      dl=$!
      for i in 1 2 3 4 5 6 7 8 9 10; do
        $CLI proxy on --yes >/dev/null 2>&1
        [ "$(sys_socks)" = "$sk" ] || { bad=$((bad + 1)); info "toggle $i on" "$(sys_socks)"; }
        sleep 0.7
        $CLI proxy off >/dev/null 2>&1
        proxy_is "$OUT/sdyn-user.txt" >/dev/null || { bad=$((bad + 1)); info "toggle $i off" "$(proxy_snapshot | head -1)"; }
        sleep 0.7
      done
      check 'every on pointed at the session, every off restored the user value' test "$bad" = 0
      run 0 '-' 'proxy on' -- proxy on --yes
      check 'a system-proxy app (nscurl) follows the proxy after 10 toggles' sys_app_is_node
      run 0 '-' 'proxy off' -- proxy off
      wait "$dl"
      check 'the SOCKS download kept going through the toggles (24 MB; Cloudflare refuses > 25 MB)' test "$(cat "$OUT/sdyn-dl.txt")" = 24000000
      sdyn_end ;;

    sdyn-switch-proxy:run)
      sdyn_begin
      connect_p "$P" || { restore; sdyn_end; return; }
      run 0 '-' 'proxy on' -- proxy on --yes
      local q pp; q=$(other_proxy "$P"); gap; hold
      run 0 'Connected|connected' "--switch $P → $q" -- connect "$(node_of "$q")" --units 1 --switch --yes
      sleep 3; pp=$(sys_socks)
      if [ -n "$pp" ]; then
        check 'the system proxy points at a live port' listening "$pp"
        check 'a system-proxy app still goes through the VPN' sys_app_is_node
      else
        check 'proxy restored to the user value (not left dead)' proxy_is "$OUT/sdyn-user.txt"
        info 'switch-proxy' 'the proxy did not follow the new session (the user turns it on again)'
      fi
      sdyn_end ;;

    sdyn-switch-full:run)
      sdyn_begin
      connect_p "$P" || { restore; sdyn_end; return; }
      run 0 '-' 'proxy on' -- proxy on --yes
      gap; hold
      run 0 'Connected|connected' "--switch $P → hysteria2" -- connect "$(node_of hysteria2)" --units 1 --switch --yes
      sleep 4
      check 'system proxy restored (no SOCKS port of ours left set)' proxy_is "$OUT/sdyn-user.txt"
      check 'plain traffic now tunnelled' egress_is_node hysteria2
      check 'a system-proxy app works (not pointed at a dead proxy)' sys_app_is_node
      sdyn_end ;;

    sdyn-user-change:run)
      sdyn_begin
      connect_p "$P" || { restore; sdyn_end; return; }
      run 0 '-' 'proxy on' -- proxy on --yes
      set_user_proxy 10.8.8.8 3128
      proxy_snapshot > "$OUT/sdyn-usernew.txt"
      run 0 '-' 'proxy off' -- proxy off
      check 'proxy off keeps the value the user set mid-session' proxy_is "$OUT/sdyn-usernew.txt"
      run 0 '-' 'disconnect' -- disconnect; sleep 3
      check 'disconnect keeps it too' proxy_is "$OUT/sdyn-usernew.txt"
      sdyn_end "$OUT/sdyn-usernew.txt" ;;

    sdyn-user-pac:run)
      sdyn_begin
      set_user_proxy 10.9.9.9 8080 'http://wpad.example.invalid/proxy.pac'
      proxy_snapshot > "$OUT/sdyn-userpac.txt"
      connect_p "$P" || { restore; sdyn_end "$OUT/sdyn-userpac.txt"; return; }
      run 0 '-' 'proxy on' -- proxy on --yes
      check 'proxy on points at the session' bash -c "[ \"\$1\" = \"\$2\" ]" _ "$(sys_socks)" "$(socks)"
      sdyn_end "$OUT/sdyn-userpac.txt" ;;

    sdyn-svc-restart:run)
      sdyn_begin
      connect_p "$P" || { restore; sdyn_end; return; }
      run 0 '-' 'proxy on' -- proxy on --yes
      restarted_live; hold; sudo launchctl kickstart -k "system/$LABEL"; sleep 15
      run 0 '-' 'status after the service restart (recorded)' -- status
      info 'status after the restart' "$LAST"
      local pp; pp=$(sys_socks)
      check 'after the next CLI command the proxy is not left on a dead port' bash -c "[ -z \"\$1\" ] || sudo lsof -nP -iTCP:\"\${1##*:}\" -sTCP:LISTEN >/dev/null" _ "$pp"
      check 'system-proxy apps still reach the internet' sys_app_online
      sdyn_end ;;

    sdyn-browser:run)
      sdyn_begin
      connect_p "$P" || { restore; sdyn_end; return; }
      local sk prof; sk=$(socks)
      run 0 '-' 'proxy browser (Chrome through the session)' -- proxy browser --browser chrome --url https://api.ipify.org
      sleep 8
      prof=$(ps -axww -o command | grep -F "socks5://$sk" | grep -oE -- '--user-data-dir=[^ ]+' | head -1 | cut -d= -f2-)
      check 'Chrome opened through the session' test -n "$prof"
      run 0 '-' 'disconnect' -- disconnect; sleep 3
      if [ -n "$prof" ]; then
        # ask the open window to load a page: with the SOCKS port gone it must fail, never go direct
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --user-data-dir="$prof" 'https://example.com/?after-disconnect' >/dev/null 2>&1 &
        sleep 10
        local direct; direct=$(sudo lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null | awk '$1 ~ /^Google/ && $9 !~ /127\.0\.0\.1/ && $9 ~ /:443$/ {print $9}' | sort -u | tr '\n' ' ')
        check 'that window makes no direct web connections after disconnect' test -z "$direct"
        info 'chrome direct 443 after disconnect' "${direct:-none}"
        pkill -f -- "--user-data-dir=$prof"; sleep 2
      fi
      sdyn_end ;;

    sdyn-port-taken:run)
      sdyn_begin
      python3 -c 'import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 1080)); s.listen(); time.sleep(240)' &
      local holder=$!; sleep 1
      info 'port-taken' "holding 127.0.0.1:1080 (pid $holder)"
      hold
      local out code; out=$($CLI connect "$(node_of "$P")" --units 1 --yes 2>&1); code=$?; LAST=$out
      info 'connect with 1080 taken' "exit=$code $(printf '%s' "$out" | tail -1)"
      if [ $code = 0 ] && printf '%s' "$out" | grep -q Connected; then
        local sk; sk=$(socks)
        check 'the session got a different SOCKS port' bash -c "[ -n \"\$1\" ] && [ \"\$1\" != 127.0.0.1:1080 ]" _ "$sk"
        check 'that port carries VPN traffic' bash -c "[ \"\$(curl -4 -s -m 12 --socks5-hostname \"\$1\" https://api.ipify.org)\" = '$NODE_IP' ]" _ "$sk"
      else
        check 'refused with a plain message (no raw error)' bash -c "! printf '%s' \"\$1\" | grep -Eq 'EADDRINUSE|bind: |rpc error'" _ "$LAST"
        check 'nothing half-set after the refusal' bash -c "$(declare -f services proxy_snapshot our_procs); LIB='$LIB'; proxy_snapshot | diff -q - '$OUT/sdyn-user.txt' >/dev/null && [ -z \"\$(our_procs)\" ]"
      fi
      kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
      sdyn_end ;;

    sdyn-races:run)
      sdyn_begin
      local ok=0 i
      for i in 1 2 3 4 5 6 7 8; do
        hold
        $CLI connect "$(node_of "$P")" --units 1 --yes >/dev/null 2>&1 && ok=$((ok + 1))
        $CLI proxy on --yes >/dev/null 2>&1
        $CLI disconnect >/dev/null 2>&1
        gap
      done
      info 'races' "$ok/8 connects succeeded"
      sleep 3
      check 'system proxy not left on after the last disconnect' proxy_is "$OUT/sdyn-user.txt"
      check 'at least one race connect worked (the rig is not just down)' test "$ok" -ge 1
      sdyn_end ;;

    # the driver cuts the node between a and b (150 s): proxy apps must still reach the internet
    sdyn-nodedown:a)
      faulted_live; sdyn_begin
      connect_p "$P" || { restore; return; }
      run 0 '-' 'proxy on' -- proxy on --yes
      check 'proxy on points at the session' bash -c "[ \"\$1\" = \"\$2\" ]" _ "$(sys_socks)" "$(socks)" ;;
    sdyn-nodedown:b)
      run 0 '-' 'status with the node gone (recorded)' -- status
      info 'status with the node gone' "$LAST"
      local pp; pp=$(sys_socks)
      check 'the proxy is not pointing at a dead port' bash -c "[ -z \"\$1\" ] || sudo lsof -nP -iTCP:\"\${1##*:}\" -sTCP:LISTEN >/dev/null" _ "$pp"
      check 'system-proxy apps reach the internet (direct or via a live session)' sys_app_online
      sdyn_end ;;

    # ─── A30: node test run ───
    test:run)
      hold
      run 0 'FAST|SLOW' "test run on the $P node" -- test run "$(node_of "$P")" --yes
      info 'test run' "$LAST"
      sleep 5 ;;

    # ─── A27: settle + refund (once, after the paid cases) ───
    # ─── settle races (port of #31 vm-edge double-settle; FMC Q0242 / Q0280 final-pass cells) ───
    # Both need a deposit that is due; with none the settles print "Nothing was due." and test nothing,
    # so a short session makes one first.
    double-settle:run|settle-stop:run)
      local due n=0
      due_n() { $CLI settle list 2>/dev/null | grep -cE '^[1-9A-HJ-NP-Za-km-z]{32,}[[:space:]]+(open|ready)\b'; }
      due=$(due_n)
      if [ "${due:-0}" = 0 ]; then
        info 'no deposit is due' 'one short session to make one'
        if connect_p wireguard; then sleep 15; $CLI disconnect >/dev/null 2>&1; sleep 10; else info 'connect failed' "$LAST"; fi
        due=$(due_n); gap
      fi
      info 'deposits due before the settle' "${due:-0}"
      local a="$OUT/settle-a.txt" b="$OUT/settle-b.txt" t0; t0=$(date -u +%FT%TZ)
      if [ "$CASE" = double-settle ]; then
        ( $CLI settle run --yes > "$a" 2>&1; echo "(exit $?)" >> "$a" ) & local pa=$!
        ( $CLI settle run --yes > "$b" 2>&1; echo "(exit $?)" >> "$b" ) & local pb=$!
        wait $pa $pb
        printf '\n### [%s] two settle runs at once\n--- a\n%s\n--- b\n%s\n' "$P" "$(cat "$a")" "$(cat "$b")" >> "$LOG"
        check 'a deposit was due, so the two settles really raced (path exercised)' bash -c "[ '${due:-0}' -gt 0 ] && grep -qh '^Done:' '$a' '$b'"
        check 'both settles end without an Error line' bash -c "! grep -qhiE '^Error' '$a' '$b'"
        info 'refund-already-withdrawn skip (Q0242, dvpnd/app log)' "$(grep -hi 'already withdrawn' "$a" "$b" | head -2 | tr '\n' ' ')"
      else
        ( $CLI settle run --yes > "$a" 2>&1; echo "(exit $?)" >> "$a" ) & local pa=$!
        sleep 3
        run 0 '-' 'service answers just before the mid-settle stop (SIGTERM next; launchd KeepAlive brings it back)' -- daemon version
        sudo launchctl kill SIGTERM "system/$LABEL" 2>&1 | head -1 >> "$LOG"
        wait $pa
        printf '\n### [%s] settle run while the service stopped\n%s\n' "$P" "$(cat "$a")" >> "$LOG"
        check 'a deposit was due, so the settle was mid-way (path exercised)' test "${due:-0}" -gt 0
        check 'settle with the service gone: no Error line (a warning instead, Q0280)' bash -c "! grep -qiE '^Error' '$a'"
        check 'settle with the service gone: says it was deferred, in plain words' bash -c "grep -qiE 'deferred|later|service' '$a'"
        check 'the VPN service comes back by itself' svc_back
      fi
      local ch; ch=$($CLI settle list 2>&1 | grep -v '^\[rpc\]')
      info 'settle list after' "$ch"
      check 'no deposit is left in an error state' bash -c "! printf '%s' \"\$1\" | grep -qiE 'error|fail'" _ "$ch" ;;

    # ─── #31 fixes ported to Mac (FMC list for the final pass): Q0013 / Q0078 / Q0229 ───
    disc-2nd:run) # Q0013: a disconnect from a second terminal while the first is still connecting/paying stops it
      local a="$OUT/disc2-connect.txt" pa
      hold
      ( $CLI connect "$(node_of wireguard)" --units 1 --yes > "$a" 2>&1; echo "(exit $?)" >> "$a" ) & pa=$!
      sleep 4
      run 0 '-' 'disconnect from a second terminal while the first connect is still running' -- disconnect
      check 'the second-terminal disconnect does not say "No active session"' bash -c "! printf '%s' \"\$1\" | grep -qi 'no active session'" _ "$LAST"
      wait $pa
      printf '\n### [%s] first terminal connect\n%s\n' "$P" "$(cat "$a")" >> "$LOG"
      sleep 5
      check 'no session left after the second-terminal disconnect' bash -c "$CLI status 2>/dev/null | grep -q '^Session *Not connected'"
      check 'own IP back after the second-terminal disconnect' bash -c "for i in 1 2 3 4; do [ \"\$(curl -4 -s -m 8 https://api.ipify.org)\" = '$DIRECT' ] && exit 0; sleep 4; done; exit 1"
      restore ;;
    zero-byte-conf:run) # dvpnd 18.36: a power cut mid-connect leaves the WG/AWG conf as zero bytes; the next connect moves it aside and connects
      local p f d
      for p in wireguard amneziawg; do
        case $p in wireguard) d=wireguard f=dvpn-wg-client.conf ;; amneziawg) d=amneziawg f=dvpn-awg-client.conf ;; esac
        f=/var/db/dvpnd/client/client/$d/$f
        # 0600 like dvpnd's own conf: `truncate` on a missing file made it 0644, and the moved-aside copy then
        # failed cli-daemon's "no world-readable file" check (harness artifact, 2026-10-29)
        sudo -n mkdir -p "${f%/*}" && sudo -n install -m 0600 /dev/null "$f" && sudo -n truncate -s 299 "$f"
        check "[$p] a 299-byte zero-filled conf is in place, no tunnel up" bash -c "sudo -n test -s '$f' && [ -z \"\$(sudo -n tr -d '\000' < '$f')\" ] && $CLI status 2>/dev/null | grep -q '^Session *Not connected'"
        local t0; t0=$(date +%FT%T)  # dvpnd logs local time
        connect_p "$p" || { restore; continue; }
        check "[$p] connected through the node after the zero-byte conf" egress_is_node "$p"
        check "[$p] dvpnd moved the zero-byte conf aside" bash -c "sudo -n grep -F '\"time\":\"' /Library/Logs/DevnetDVPN/dvpnd.log | awk -v t='$t0' 'substr(\$0, index(\$0,\"\\\"time\\\":\\\"\")+8, 19) >= t' | grep -q 'moved it aside'"
        run 0 '-' "[$p] disconnect" -- disconnect
        # the moved-aside copy is our own zero-filled file: remove it only when it is all NUL bytes
        for g in $(sudo -n sh -c "ls '$f'.foreign-* 2>/dev/null"); do
          [ -z "$(sudo -n tr -d '\000' < "$g")" ] && sudo -n rm -f "$g" || info "[$p] kept $g (not our zero-filled file)" ''
        done
        sleep 7
      done
      check 'own IP back after the zero-byte-conf connects' bash -c "for i in 1 2 3 4; do [ \"\$(curl -4 -s -m 8 https://api.ipify.org)\" = '$DIRECT' ] && exit 0; sleep 4; done; exit 1"
      restore ;;
    rpc-nonsolana:run) # Q0078: an https endpoint that is not a Solana RPC gets plain copy, never raw HTML
      local sf="$DVPN_DATA_DIR/settings.json" bk="$OUT/settings.json.bak"
      cp -p "$sf" "$bk" || { record FAIL 'settings backed up before the rpc change' ''; return; } # holds the RPC key: never printed
      run 0 '-' 'rpc set https://example.com (not a Solana RPC)' -- rpc set https://example.com
      try_run 'connect with that endpoint (must fail)' -- connect "$(node_of wireguard)" --units 1 --yes; check 'connect with a non-Solana endpoint fails (non-zero exit)' test $? -ne 0
      check 'says the endpoint is not a Solana RPC, in plain words' bash -c "printf '%s' \"\$1\" | grep -qiE 'not a Solana RPC|not an RPC|does not answer like'" _ "$LAST"
      check 'no raw HTML in the error' bash -c "! printf '%s' \"\$1\" | grep -qiE '<html|<!doctype|<body'" _ "$LAST"
      cp -p "$bk" "$sf" && rm -f "$bk"
      check 'own RPC back afterwards (rpc state answers with a slot)' bash -c "$CLI rpc state 2>/dev/null | grep -q 'slot [0-9]'"
      restore ;;
    switch-comingup:run) # Q0229: switching while the first session is still coming up logs a warning, never an ERROR
      local a="$OUT/switch-first.txt" pa t0; t0=$(date +%Y-%m-%dT%H:%M:%S)
      hold
      ( $CLI connect "$(node_of wireguard)" --units 1 --yes > "$a" 2>&1; echo "(exit $?)" >> "$a" ) & pa=$!
      sleep 3
      try_run 'connect OpenVPN --switch while WireGuard is still coming up' -- connect "$(node_of openvpn)" --units 1 --switch --yes
      wait $pa
      printf '\n### [%s] first connect\n%s\n' "$P" "$(cat "$a")" >> "$LOG"
      sleep 5
      local errs; errs=$(sudo awk -v t="\"time\":\"$t0" 'index($0, "\"time\":\"") && substr($0, index($0, "\"time\":\"") , 27) >= t' /Library/Logs/DevnetDVPN/dvpnd.log 2>/dev/null | grep '"level":"error"' | head -3 | cut -c1-300)
      info 'dvpnd error lines since the switch' "${errs:-none}"
      check 'no ERROR in the service log from the switch-while-coming-up' test -z "$errs"
      run 0 '-' 'disconnect' -- disconnect
      restore ;;

    basis-override:run) # Q0283: a per-GB connect bills per GB even when the service default (client.toml) is per hour
      local was; was=$($CLI daemon settings 2>/dev/null | awk '/^basis/{print $2}'); was=${was:-per_gb}
      run 0 '-' 'service default basis = per_hour' -- daemon set --basis per_hour --yes
      sleep 5
      connect_p wireguard --basis per_gb || { run 0 '-' "service default basis back to $was" -- daemon set --basis "$was" --yes; restore; return; }
      sleep 4
      run 0 'per GB' 'status shows per GB (the connect basis, not the per-hour default)' -- status
      check 'status does not show per hour' bash -c "! printf '%s' \"\$1\" | grep -qi 'per hour'" _ "$LAST"
      # status --json carries no basis field (the label is worked out from the channel's mode for the text line only),
      # so the text line above is the check; the deposit being cut by bytes below proves per-GB billing
      fetch_bytes 5000000 -m 30 -o /dev/null
      sleep 20
      local b; b=$(bytes_now); info 'bytes counted' "${b:-none}"
      check 'the deposit is cut by bytes (live stats count traffic)' bash -c "[ '${b:-0}' -gt 0 ] 2>/dev/null"
      run 0 '-' 'disconnect' -- disconnect
      sleep 3
      run 0 '-' "service default basis back to $was" -- daemon set --basis "$was" --yes
      sleep 5 ;;
    proxy-orphan:run) # Q0281: `proxy off` clears our own SOCKS proxy left on with no backup (no session)
      local s0="$OUT/proxy-before.txt" bf="$DVPN_DATA_DIR/proxy-backup.json"
      proxy_snapshot > "$s0"
      [ -e "$bf" ] && mv "$bf" "$OUT/proxy-backup.json.moved"
      local svc o_host o_port o_on; svc=$(services | head -1)
      o_host=$(networksetup -getsocksfirewallproxy "$svc" | awk -F': ' '/^Server/{print $2}')
      o_port=$(networksetup -getsocksfirewallproxy "$svc" | awk -F': ' '/^Port/{print $2}')
      o_on=$(networksetup -getsocksfirewallproxy "$svc" | awk -F': ' '/^Enabled/{print $2}')
      sudo networksetup -setsocksfirewallproxy "$svc" 127.0.0.1 1080 >/dev/null 2>&1
      sudo networksetup -setsocksfirewallproxystate "$svc" on >/dev/null 2>&1
      check "precondition: SOCKS 127.0.0.1:1080 is on for $svc, no backup file, no session" bash -c "networksetup -getsocksfirewallproxy '$svc' | grep -q '^Enabled: Yes' && [ ! -e '$bf' ] && $CLI status 2>/dev/null | grep -q '^Session *Not connected'"
      run 0 '-' 'proxy off (no backup)' -- proxy off
      check 'SOCKS is off on every network service after proxy off' bash -c "$(declare -f services); services | while read -r s; do networksetup -getsocksfirewallproxy \"\$s\" | grep -q '^Enabled: Yes' && exit 1; done; exit 0"
      # back to exactly the rig's own setting
      sudo networksetup -setsocksfirewallproxy "$svc" "${o_host:-}" "${o_port:-0}" >/dev/null 2>&1
      [ "$o_on" = Yes ] && o_on=on || o_on=off
      sudo networksetup -setsocksfirewallproxystate "$svc" "$o_on" >/dev/null 2>&1
      [ -e "$OUT/proxy-backup.json.moved" ] && mv "$OUT/proxy-backup.json.moved" "$bf"
      check 'proxy settings back to how they were before the test' bash -c "$(declare -f services proxy_snapshot); proxy_snapshot | diff -q - '$s0' >/dev/null" ;;

    money:run)
      run 0 '-' 'channels (recorded)' -- channels
      info 'channels' "$LAST"
      run 0 '-' 'settle list' -- settle list
      info 'settle list' "$LAST"
      local before; before=$($CLI wallet --json 2>/dev/null | grep -oE '"(tdvpn|ownerTdvpn)"\s*:\s*"?[0-9.]+' | head -1 | grep -oE '[0-9.]+$')
      info 'wallet tDVPN before settle' "$before"
      run 0 '-' 'settle run' -- settle run --yes
      info 'settle run' "$LAST"
      gap
      run 0 '-' 'settle withdraw' -- settle withdraw --yes
      info 'withdraw' "$LAST"
      gap
      local after; after=$($CLI wallet --json 2>/dev/null | grep -oE '"(tdvpn|ownerTdvpn)"\s*:\s*"?[0-9.]+' | head -1 | grep -oE '[0-9.]+$')
      info 'wallet tDVPN after withdraw' "$after"
      run 0 '-' 'history summary' -- history summary
      info 'history summary' "$LAST" ;;

    *:lost-*) record FAIL "step ${STEP#lost-} never ran: the driver lost the guest (ssh exit 255)" '' ;;
    *) record FAIL "unknown step $CASE:$STEP" '' ;;
  esac
}

if [ "$STEP" = summary ]; then summary; exit $?; fi
step
