#!/bin/bash
# ─── Uninstall: leave networking exactly as it was before the app (root, macOS) ───
# Run by `devnet-dvpn daemon uninstall` / the app's Uninstall (a .dmg has no pre-remove hook):
#   1. the system SOCKS proxy back on every network service, if ours is still set (proxy-backup.json)
#   2. the service stopped gracefully (a clean stop ends the session and releases the kill switch
#      and DNS), its LaunchDaemon removed, root-owned copies and the CLI link removed
#   3. anything a dead session left (remove-tunnels.sh)
# Kept: the instance home (device key: on-chain permission + SOL; a reinstall picks it up again) and
# the sentinel-dvpn group (removing it would orphan the kept home's group owner).
# Args: [--User] [--Result]   (--User = the app user whose proxy backup is put back; none = no proxy restore)
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd -P)"
source "$HERE/_lib.sh"
parse_args "$@"
log() { echo "uninstall-cleanup: $*"; }

# 1. system proxy. Backup shape (src/main/system/proxy.ts):
#    {"ours":"socks 127.0.0.1:1080","state":{"backend":"networksetup","services":{"Wi-Fi":{"enabled":"No","server":"","port":"0"}}}}
# M33-3 (rc9-f-mac): this read EVERY /Users/*/.../proxy-backup.json, and the "still ours" value came from that same
# file, so another account could plant a backup that set the system-wide SOCKS proxy to its own server. Now: only
# the --User app user's backup, under that user's real home with no link in the chain, owned by that user; `ours`
# must be the app's own 127.0.0.1:<port> and the value put back a plain host + port (_lib.sh proxy_ours_ok,
# proxy_restore_ok).
USER_NAME="${ARG_User:-}"
BACKUPS=()
if [ -z "$USER_NAME" ]; then
  log "no --User: system proxy not restored (only the app user's own backup is ever used)"
elif ! user_is_asker "$USER_NAME"; then
  log "--User $USER_NAME is not the account that asked for this step: system proxy not restored"
elif [[ "$USER_NAME" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,31}$ ]] && uh="$(real_home "$USER_NAME")" && [ -n "$uh" ]; then
  bdir="$uh/Library/Application Support/Devnet dVPN"
  if [ -d "$bdir" ] && [ "$(cd -P -- "$bdir" 2>/dev/null && pwd -P)" = "$bdir" ]; then BACKUPS=("$bdir/proxy-backup.json"); fi
else
  log "no home for $USER_NAME: system proxy not restored"
fi
for b in ${BACKUPS[@]+"${BACKUPS[@]}"}; do
  [ -f "$b" ] && [ ! -L "$b" ] || continue
  [ "$(stat -f %Su "$b")" = "$USER_NAME" ] || { log "proxy backup $b is not owned by $USER_NAME: not used"; continue; }
  rows="$(/usr/bin/osascript -l JavaScript -e 'function run(a){var o=JSON.parse($.NSString.stringWithContentsOfFileEncodingError(a[0],4,null).js);var ours=String(o.ours||"").replace("socks ","");var s=(o.state&&o.state.services)||{};return Object.keys(s).map(function(k){var v=s[k];return [k,ours,v.enabled||"No",v.server||"",v.port||"0"].join("\t")}).join("\n")}' "$b" 2>/dev/null)" || { log "unreadable proxy backup $b"; continue; }
  while IFS=$'\t' read -r svc ours en server port; do
    [ -n "$svc" ] || continue
    proxy_ours_ok "$ours" || { log "proxy backup names '$ours', not the app's 127.0.0.1 endpoint: $svc left as it is"; continue; }
    proxy_restore_ok "$server" "$port" || { log "proxy backup value for $svc is not a host and port: left as it is"; continue; }
    cur="$(networksetup -getsocksfirewallproxy "$svc" 2>/dev/null)"
    cur_en="$(printf '%s\n' "$cur" | awk -F': ' '/^Enabled/{print $2}')"
    cur_host="$(printf '%s\n' "$cur" | awk -F': ' '/^Server/{print $2}')"
    cur_port="$(printf '%s\n' "$cur" | awk -F': ' '/^Port/{print $2}')"
    if [ "$cur_en" = Yes ] && [ "$cur_host:$cur_port" = "$ours" ]; then
      if [ -n "$server" ]; then networksetup -setsocksfirewallproxy "$svc" "$server" "$port" >/dev/null 2>&1; fi
      if [ "$en" = Yes ]; then networksetup -setsocksfirewallproxystate "$svc" on; else networksetup -setsocksfirewallproxystate "$svc" off; fi
      log "system proxy restored on $svc"
    fi
  done <<< "$rows"
  rm -f "$b"
done

# 2. service
if [ -f "$PLIST" ]; then
  svc_stop
  rm -f "$PLIST"
  log 'service stopped and removed'
fi
# 3. leftovers of a dead session (before the root-owned copies go: it matches their paths)
# AUDIT-FINAL-MACOS M1: a failure here ("still present: pf anchor …") was swallowed and the result still said
# "networking restored". Now it stops BEFORE the root copies go (a re-run needs them) and names the way out.
if ! rt_out="$(/bin/bash "$HERE/remove-tunnels.sh" 2>&1)"; then
  rt_err="$(printf '%s\n' "$rt_out" | tail -1)"
  log "remove-tunnels failed: $rt_out"
  die "Networking is NOT fully restored (${rt_err:-remove-tunnels failed}); the service is removed, nothing else was. Next: devnet-dvpn daemon restore-network, then devnet-dvpn daemon uninstall --yes again."
fi
if [ -L /usr/local/bin/devnet-dvpn ]; then
  case "$(readlink /usr/local/bin/devnet-dvpn)" in *Devnet\ dVPN*|*devnet-dvpn*) rm -f /usr/local/bin/devnet-dvpn ;; esac
fi
rm -rf "$LIB"
# cb33 (DIR 11-08): the tools root moved to /Library/devnet-dvpn. Remove either predecessor too
# (/usr/local/lib/devnet-dvpn and the short-lived "/Library/Application Support/devnet-dvpn") so
# uninstalling a build that was upgraded (or an old build directly) leaves nothing behind.
for LEGACY_LIB in /usr/local/lib/devnet-dvpn "/Library/Application Support/devnet-dvpn"; do
  [ "$LEGACY_LIB" != "$LIB" ] && [ -d "$LEGACY_LIB" ] && rm -rf "$LEGACY_LIB" 2>/dev/null
done
# pf: the daemon's Flush empties our anchors but leaves the `anchor "sentinel-dvpn-<tag>" quick all`
# ATTACHMENT line in the main ruleset (FWX 11-08). Empty our anchors, then if a stale attach line for
# ours is present, drop ONLY our line and reload the rest — exactly what the daemon's attachAnchor does
# (pfctl -sr | drop our line | pfctl -R -f -). Never `pfctl -f /etc/pf.conf` (that discards rules another
# program — a second VPN, a Little Snitch-style tool — loaded at runtime), never `pfctl -F all`/`-d`.
if [ "$(uname)" = Darwin ]; then
  pfctl -a dvpnd -F all >/dev/null 2>&1 || true
  pfctl -a "sentinel-dvpn-c0" -F all >/dev/null 2>&1 || true
  pf_drop_our_attach || die 'Networking is NOT fully restored (a pf anchor attach line is left). Next: devnet-dvpn daemon restore-network, then devnet-dvpn daemon uninstall --yes again.'
fi
write_result ok 'networking restored; service removed; device key kept in the instance home'
exit 0
