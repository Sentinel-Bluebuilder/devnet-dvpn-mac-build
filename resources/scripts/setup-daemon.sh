#!/bin/bash
# ─── Install the VPN service from a home the app already initialised (F1.5, macOS, cb33) ───
# Order matters: sentinel-dvpnd refuses to start until its device key holds a grant, so the app first
# runs `sentinel-dvpnd init --instance c0` as the user into a staging folder, the owner signs device
# setup, and only then this step runs as root (one prompt) to: create the socket group and add the
# user, copy the home into the real instance dir /Library/Application Support/sentinel-dvpn/c0, lock
# the key folder to root, copy the binaries + Homebrew tools the service runs into root-owned
# /Library/devnet-dvpn, write + load our own LaunchDaemon (root-owned PATH, so finding 1 of the
# cb33 launchd PATH issue cannot apply here), link the CLI, and delete the staging copy (it holds the
# device secret).
# The daemon runs `run --instance c0` with NO --home, so it reads the real instance dir and gives its
# control socket the group — cb33 has no socket_group config key.
# Args: --Dvpnd --Staging --DaemonHome --BinRoot --Group --Service [--Instance] [--Label] [--User] [--Cli] --Result
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd -P)"
source "$HERE/_lib.sh"
# Q0508 guest 11-12: the root step inherits the caller's umask. Under 077 the /usr/local/bin/devnet-dvpn
# link came out lrwx------ (the user's CLI: "the app is not at /") and the protocol folders 0700. Modes that
# must stay private (keys, config) are set explicitly below and kept by cp -Rp, so 022 loosens nothing secret.
umask 022
parse_args "$@"
DVPND="${ARG_Dvpnd:-}"; STAGING="${ARG_Staging:-}"; HOME_DIR="${ARG_DaemonHome:-}"
BIN_ROOT="${ARG_BinRoot:-}"; GROUP="${ARG_Group:-sentinel-dvpn}"; USER_NAME="${ARG_User:-}"; CLI="${ARG_Cli:-}"
INSTANCE="${ARG_Instance:-c0}"
LABEL="${ARG_Label:-$LABEL}"; PLIST="/Library/LaunchDaemons/$LABEL.plist"

[ -f "$DVPND" ] && [ -x "$DVPND" ] || die "sentinel-dvpnd not found at $DVPND"
[ "$(basename "$DVPND")" = sentinel-dvpnd ] || die 'unexpected daemon binary name'
[[ "$INSTANCE" =~ ^c[0-9]+$ ]] || die "bad instance tag $INSTANCE"
under "$HOME_DIR" "$DAEMON_ROOT" || die "daemon home must be under $DAEMON_ROOT"
[[ "$GROUP" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "bad group name $GROUP"
if [ -n "$USER_NAME" ]; then id -u "$USER_NAME" >/dev/null 2>&1 || die "no such user $USER_NAME"; fi
# Staging is deleted as root at the end: only ever the app's own daemon-staging folder (first setup) or
# daemon-switch folder (wallet switch, #31 rc.4 E-55 switchHome), no link.
if [ -n "$STAGING" ]; then
  [[ "$STAGING" == /Users/?*/daemon-staging || "$STAGING" == /Users/?*/daemon-switch ]] || die "unexpected staging folder $STAGING"
  [[ "$STAGING" != *..* ]] && [ ! -L "$STAGING" ] || die "unsafe staging folder $STAGING"
  # AUDIT-FINAL-MACOS M8: the glob is on the string (`*` crosses `/`) and -L checks the last part only, so a symlinked
  # parent sent `cp -Rp` and the final `rm -rf` elsewhere. The canonical path must equal the given one (no link in the
  # chain), end in one of the two names, and, with --User, sit under that user's real home (DVPN_DATA_DIR keeps working).
  staging_real="$(cd -P -- "$STAGING" 2>/dev/null && pwd -P)" || die "staging folder not found: $STAGING"
  [ "$staging_real" = "$STAGING" ] || die "unsafe staging folder $STAGING (resolves to $staging_real)"
  case "$(basename -- "$staging_real")" in daemon-staging|daemon-switch) ;; *) die "unexpected staging folder $STAGING" ;; esac
  if [ -n "$USER_NAME" ]; then
    user_home="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    user_home_real="$(cd -P -- "${user_home:-/nonexistent}" 2>/dev/null && pwd -P)" || die "no home folder for $USER_NAME"
    case "$staging_real" in "$user_home_real"/?*) ;; *) die "staging folder $STAGING is not under $USER_NAME's home $user_home_real" ;; esac
  fi
fi

# 1. socket group + the desktop user in it; an inherited ACL on the home gives THIS user access to
#    the socket sentinel-dvpnd re-creates on every start (macOS resolves the new membership at once too).
dseditgroup -o read "$GROUP" >/dev/null 2>&1 || dseditgroup -o create -r 'Devnet dVPN' "$GROUP" || die "could not create group $GROUP"
if [ -n "$USER_NAME" ]; then dseditgroup -o edit -a "$USER_NAME" -t user "$GROUP" || die "could not add $USER_NAME to $GROUP"; fi

# 2. the home
# A wallet switch stages a NEW operator key while the service home still holds the old one (fleet bug
# W1): keeping the old home would lose the new key and leave the service on the old device. When the
# staged key differs, the old home is moved aside (kept: it may still hold deposits to settle).
# cb33 names the key "operator" (a home from before cb33 said "device").
device_key() { "$DVPND" key list --instance "$INSTANCE" --home "$1" 2>/dev/null | grep -oE '"name":"(operator|device)","public_key":"[1-9A-HJ-NP-Za-km-z]{32,44}"' | grep -oE '[1-9A-HJ-NP-Za-km-z]{32,44}"' | tr -d '"' | head -1; }
if [ -f "$HOME_DIR/config.toml" ] && [ -n "$STAGING" ] && [ -f "$STAGING/config.toml" ]; then
  staged_key=$(device_key "$STAGING"); installed_key=$(device_key "$HOME_DIR")
  if [ -n "$staged_key" ] && [ "$staged_key" != "$installed_key" ]; then
    svc_stop || die 'could not stop the VPN service to replace its device'
    prev="$HOME_DIR.prev-$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$HOME_DIR" "$prev" || die 'could not move the old service home aside'
    echo "replaced device ${installed_key:-unknown} with $staged_key; old home kept at $prev" >&2
  fi
fi
if [ ! -f "$HOME_DIR/config.toml" ]; then
  [ -f "$STAGING/config.toml" ] || die "staging home has no config.toml: $STAGING"
  mkdir -p "$HOME_DIR"
  # AC-MAC-1 P2-1: the staging folder is the user's and `cp -Rp` keeps symlinks; below, root writes
  # device.pub and migrates config.toml, which would follow a planted link to a root file. Copy into a
  # root-owned folder first (the user can no longer change it), refuse any link there, then copy on.
  copy="$(mktemp -d "$DAEMON_ROOT/.staged.XXXXXX")" || die 'could not make a folder for the staged home'
  cp -Rp "$STAGING/." "$copy/" || { rm -rf -- "$copy"; die 'could not copy the staged home'; }
  if [ -n "$(find "$copy" -type l -print 2>/dev/null | head -1)" ]; then
    rm -rf -- "$copy"; die "the staged home holds a symbolic link; refusing it: $STAGING"
  fi
  cp -Rp "$copy/." "$HOME_DIR/" || { rm -rf -- "$copy"; die 'could not copy the staged home'; }
  rm -rf -- "$copy"
fi
# a home kept from an older sentinel-dvpnd (reinstall) may still carry pre-cb33 key names / a stray
# socket_group; the migrate step brings its one config.toml up to the cb33 shape (no-op if already so).
/bin/bash "$HERE/migrate-daemon-config.sh" --DaemonHome "$HOME_DIR" >/dev/null || die 'could not update the service settings to the cb33 layout'
# E-ST owner (#38 rc.9 blocker, macOS twin of the Windows wallet-switch bug): a home kept above (same device key)
# still names the owner it was set up for. --Owner = the wallet the app recorded for this device; the service runs
# for that owner from now on (its grant is the one dvpnd checks). Older callers pass no --Owner: unchanged.
if [ -n "${ARG_Owner:-}" ]; then
  owner_set=$(set_config_owner "$HOME_DIR/config.toml" "$ARG_Owner") || die "could not set the service owner to $ARG_Owner"
  [ "$owner_set" = changed ] && echo "service owner set to $ARG_Owner" >&2
fi
chown -R root:"$GROUP" "$DAEMON_ROOT"
# closed to other users: the group (and below, the setup user by ACL before a new login) gets in
chmod 750 "$DAEMON_ROOT"
# `sentinel-dvpnd doctor` wants the instance home 0750 (so a group member can reach the socket path),
# every config SUBdir 0700 and config.toml 0600 (root only). The setup user reaches them through the
# ACLs granted below. Match doctor exactly so it prints no notes.
chmod 750 "$HOME_DIR"
find "$HOME_DIR" -mindepth 1 -type d ! -path '*/keys' ! -path '*/keys/*' -exec chmod 700 {} +
find "$HOME_DIR" -name config.toml -type f ! -path '*/keys/*' -exec chmod 600 {} +
for k in "$HOME_DIR/keys" "$HOME_DIR/client/keys"; do
  if [ -d "$k" ]; then chown -R root:wheel "$k"; chmod -R go-rwx "$k"; fi
done
# the device ADDRESS (public half) for the app: the key folder itself stays root-only
PUB=$("$DVPND" key list --instance "$INSTANCE" --home "$HOME_DIR" 2>/dev/null | grep -oE '"name":"(operator|device)","public_key":"[1-9A-HJ-NP-Za-km-z]{32,44}"' | grep -oE '[1-9A-HJ-NP-Za-km-z]{32,44}"$' | tr -d '"')
[ -n "$PUB" ] || die 'could not read the device public key'
rm -f -- "$HOME_DIR/device.pub"   # P2-1: never write through a link left in the home
printf '%s\n' "$PUB" > "$HOME_DIR/device.pub" && chmod 600 "$HOME_DIR/device.pub"
# the database holds signed vouchers, plan tickets and the session history: root only. A home
# from an older setup has it 0644 (launchd's default umask; the plist now sets 077).
find "$HOME_DIR" -name 'data.db*' -type f -exec chmod 600 {} +
if [ -n "$USER_NAME" ]; then
  # AUDIT-FINAL-MACOS M3: no `chmod -N` here. It ran on every setup / wallet switch and wiped the ACEs
  # grant-socket.sh gave other accounts; add_ace (_lib.sh) only adds the setup user's entries.
  add_ace 'search,readattr' "$DAEMON_ROOT" || die 'could not grant the home folder ACL'
  add_ace 'list,search,read,write,readattr,readextattr,file_inherit' "$HOME_DIR" || die 'could not grant the socket ACL'
  while IFS= read -r -d '' d; do add_ace 'list,search,readattr' "$d"; done \
    < <(find "$HOME_DIR" -mindepth 1 -type d ! -path '*/keys' ! -path '*/keys/*' -print0 2>/dev/null)
  # M6: -type f, so root never puts an ACE on a symlink's target
  while IFS= read -r -d '' f; do add_ace 'read,readattr' "$f"; done \
    < <(find "$HOME_DIR" -name config.toml -type f ! -path '*/keys/*' -print0 2>/dev/null)
  # device.pub is the device ADDRESS the app shows; base mode is 0600, so grant the setup user a read ACE
  [ -f "$HOME_DIR/device.pub" ] && add_ace 'read,readattr' "$HOME_DIR/device.pub"
fi

# 3. root-owned copies of everything the service runs. The app bundle can be replaced on update
#    or be writable by the user; Homebrew's prefix is user-writable. Root must not exec either.
install -d -m 755 "$LIB" "$LIB/tools" || die "could not create $LIB"
install -m 755 "$DVPND" "$LIB/sentinel-dvpnd.new" && mv -f "$LIB/sentinel-dvpnd.new" "$LIB/sentinel-dvpnd" || die 'could not install sentinel-dvpnd'
for d in v2ray xray hysteria2; do
  if [ -n "$BIN_ROOT" ] && [ -d "$BIN_ROOT/$d" ]; then
    rm -rf "$LIB/$d.new" && cp -R "$BIN_ROOT/$d" "$LIB/$d.new" && rm -rf "$LIB/$d" && mv "$LIB/$d.new" "$LIB/$d" || die "could not install $d"
  fi
done
# AUDIT-FINAL-MACOS M4: a failed copy of the Homebrew tools was silent. Log it and say so in the result
# (toolsCopied:false); setup goes on, the protocols that need them read "missing" in daemon drivers.
TOOLS_FIELD='"toolsCopied":true'
if ! deps_out="$(/bin/bash "$HERE/install-deps.sh" --CopyOnly 1 ${USER_NAME:+--User "$USER_NAME"} 2>&1)"; then
  echo "setup-daemon: install-deps --CopyOnly failed: $(printf '%s\n' "$deps_out" | tail -3 | tr '\n' ' ')" >&2
  TOOLS_FIELD='"toolsCopied":false'
fi
# the helper scripts too: later prompts run these root-owned copies, not the app bundle's
rm -rf "$LIB/scripts.new" && cp -R "$HERE" "$LIB/scripts.new" && rm -rf "$LIB/scripts" && mv "$LIB/scripts.new" "$LIB/scripts" || die 'could not install the helper scripts'
chown -R root:wheel "$LIB"; chmod -R go-w "$LIB"
xattr -dr com.apple.quarantine "$LIB" 2>/dev/null
DVPND="$LIB/sentinel-dvpnd"
# cb33 upgrade (DIR 11-08): the install root moved to "$LIB" (/Library/devnet-dvpn, every parent
# root:wheel, no space). Two predecessors existed: /usr/local/lib/devnet-dvpn (uid-501 ancestor on
# Homebrew-Intel — the trusted-path check refused its own binaries on connect) and a short-lived
# "/Library/Application Support/devnet-dvpn" (its space broke wg-quick). Remove any of them so an
# upgrade is not left with a stale tool tree (the new PATH never points there).
for LEGACY_LIB in /usr/local/lib/devnet-dvpn "/Library/Application Support/devnet-dvpn"; do
  if [ "$LEGACY_LIB" != "$LIB" ] && [ -d "$LEGACY_LIB" ]; then
    rm -rf "$LEGACY_LIB" 2>/dev/null || echo "note: could not remove the legacy tools dir $LEGACY_LIB" >&2
  fi
done

# 4. LaunchDaemon (OURS, not `sentinel-dvpnd service install`). The daemon finds wg-quick /
#    wireguard-go / openvpn / v2ray / xray / hysteria2 on PATH: only our root-owned copies, never a
#    user-writable Homebrew dir (cb33 launchd-PATH finding 1). `run --instance c0` with no --home, so
#    the daemon reads the real instance dir and gives its socket the group. SIGTERM stop = the daemon
#    ends the session and releases the kill switch. A device without its grant fails preflight on
#    every start: ThrottleInterval keeps the retries (each costs RPC calls) one minute apart.
SVC_PATH="$LIB/tools"
for d in v2ray xray hysteria2; do [ -d "$LIB/$d" ] && SVC_PATH="$SVC_PATH:$LIB/$d"; done
SVC_PATH="$SVC_PATH:/usr/bin:/bin:/usr/sbin:/sbin"
install -d -m 755 "$LOG_DIR"
# AUDIT-FINAL-MACOS M9: a bootout that timed out left the OLD job loaded, and svc_start then kickstarted it (old plist).
svc_stop || die "the old VPN service did not stop within 30 s, so the new service definition was not loaded. Next: sudo launchctl bootout system/$LABEL, then devnet-dvpn daemon install --yes again"
cat > "$PLIST.new" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Written by Devnet dVPN (setup-daemon.sh). Removed by its uninstaller. -->
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$DVPND</string><string>run</string><string>--instance</string><string>$INSTANCE</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$SVC_PATH</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>ExitTimeOut</key><integer>30</integer>
  <key>ProcessType</key><string>Interactive</string>
  <!-- 077: what the daemon creates itself (its database) is root only; it sets the socket mode itself -->
  <key>Umask</key><integer>63</integer>
  <key>StandardOutPath</key><string>$LOG_DIR/dvpnd.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/dvpnd.log</string>
</dict>
</plist>
PL
plutil -lint "$PLIST.new" >/dev/null || die 'the LaunchDaemon file is not valid'
chown root:wheel "$PLIST.new"; chmod 644 "$PLIST.new"; mv -f "$PLIST.new" "$PLIST"
# cb33 upgrade: the pre-cb33 app used a different launchd label; boot out and remove its plist so the
# machine is not left with two Devnet dVPN LaunchDaemons after an install-over (ours is $LABEL).
OLD_LABEL="network.sentinel.devnet-dvpn.dvpnd"
OLD_PLIST="/Library/LaunchDaemons/$OLD_LABEL.plist"
if [ "$OLD_LABEL" != "$LABEL" ] && [ -f "$OLD_PLIST" ]; then
  launchctl bootout "system/$OLD_LABEL" 2>/dev/null || true
  rm -f "$OLD_PLIST"
fi
# cb33 upgrade: a pre-cb33 build left its pf kill-switch anchor named 'dvpnd', and an abnormally
# stopped daemon can leave 'sentinel-dvpn-<tag>' attached. The daemon refuses to attach over a
# conflicting anchor ("conflicting pf anchor attachment") and fails closed, so KS-on connects abort
# until the stale attach is gone. Empty our anchors and, only if a stale attach line is present, drop
# ONLY our line and reload the rest (the daemon re-attaches its own on connect). Matches the daemon's
# attachAnchor. Never `pfctl -f /etc/pf.conf` (discards another program's runtime rules — a second VPN,
# a Little Snitch-style tool — FWX 11-08), never `pfctl -F all`/`-d`.
if [ "$(uname)" = Darwin ]; then
  pfctl -a dvpnd -F all >/dev/null 2>&1 || true
  pfctl -a "sentinel-dvpn-$INSTANCE" -F all >/dev/null 2>&1 || true
  pf_drop_our_attach || echo 'setup-daemon: a stale pf attach line could not be dropped' >&2
fi
LOG_AT=$(stat -f %z "$LOG_DIR/dvpnd.log" 2>/dev/null || echo 0)
svc_start || die "service failed to start: $(svc_log_tail 3)"
OFFLINE=0
if ! wait_socket "$HOME_DIR/daemon.sock"; then
  # the daemon checks the RPC before it serves (unless a kill switch is held). With no network it
  # exits and launchd starts it again every minute (KeepAlive), so it comes up once the network is back.
  tail -c +$((LOG_AT + 1)) "$LOG_DIR/dvpnd.log" 2>/dev/null | grep -q 'preflight failed: rpc' || die "service started but its control socket did not appear: $(svc_log_tail 3)"
  OFFLINE=1
fi

# 5. the CLI on PATH (the .dmg has no post-install step)
if [ -n "$CLI" ] && [ -f "$CLI" ] && [ "$(basename "$CLI")" = devnet-dvpn ]; then
  install -d -m 755 /usr/local/bin && ln -sf "$CLI" /usr/local/bin/devnet-dvpn
fi
[ -n "$STAGING" ] && [ -d "$STAGING" ] && rm -rf -- "$STAGING"
if [ "$OFFLINE" = 1 ]; then write_result ok 'service installed; waiting for the network' "\"waitingForNetwork\":true,$TOOLS_FIELD"; else write_result ok 'service installed and running' "$TOOLS_FIELD"; fi
