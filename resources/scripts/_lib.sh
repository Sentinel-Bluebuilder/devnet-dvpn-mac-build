# ─── shared by the dvpn-helper steps (sourced, root, macOS /bin/bash 3.2) ───
# Bash 3.2: no associative arrays, no ${x,,}, and "${a[@]}" of an empty array trips `set -u`
# (use ${a[@]+"${a[@]}"}). Named args: --Key value → $ARG_Key. Results: one JSON line in
# --Result (a file inside a folder the calling user created: /…/devnet-dvpn-XXXXXX/result.json).
# cb33 (26de5240): the client is instance c0; the daemon is sentinel-dvpnd and the home is the real
# instance dir /Library/Application Support/sentinel-dvpn/c0 (a SPACE in the path). We write our OWN
# LaunchDaemon (label below), so we still choose its args, PATH and log path. LABEL/DAEMON_ROOT are
# overridable so a caller can pass --Label; the svc_* helpers read $LABEL at call time.
LABEL="${LABEL:-co.sentinel.sentinel-dvpnd.c0}"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
# Tools install root. MUST be a fully root-owned chain: the daemon runs only binaries no non-root
# account can replace (sentinel-go-sdk service/trust.go trustedChain walks every ancestor). Homebrew-
# Intel chowns /usr/local/lib to uid 501, so the old /usr/local/lib/devnet-dvpn failed that check on
# connect (DIR 11-08). /Library is root:wheel 0755 (every parent root-owned) AND has no space:
# "Application Support" was tried first but its space breaks Homebrew's wg-quick/awg-quick, which
# re-parse the tool path internally and can't take it unquoted (TMC 11-08). /Library/devnet-dvpn dodges
# that entirely while keeping the root-only chain (FWX's armed fallback).
LIB=/Library/devnet-dvpn
LOG_DIR=/Library/Logs/DevnetDVPN
# The cb33 state root (our product folder under Application Support); the home is $DAEMON_ROOT/c0.
DAEMON_ROOT="${DAEMON_ROOT:-/Library/Application Support/sentinel-dvpn}"

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --[A-Za-z]*)
        [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 64; }
        local k="${1#--}"
        [[ "$k" =~ ^[A-Za-z]+$ ]] || { echo "bad parameter name $1" >&2; exit 64; }
        printf -v "ARG_$k" '%s' "$2"; shift 2 ;;
      *) echo "unexpected argument: $1" >&2; exit 64 ;;
    esac
  done
}
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"; s="${s//$'\t'/ }"
  printf '"%s"' "$s"
}
write_result() { # status detail [extra-json-fields]
  local r="${ARG_Result:-}"
  [ -n "$r" ] || return 0
  if ! [[ "$r" =~ /devnet-dvpn-[A-Za-z0-9]+/result\.json$ ]] || [ -L "$r" ] || [ -L "$(dirname "$r")" ]; then
    echo "refusing result path $r" >&2; return 0
  fi
  # AUDIT-FINAL-MACOS M7: root's `> "$r"` wrote through a hard link to any root file on the volume (macOS has no
  # protected_hardlinks). A new file in the same folder, renamed over the path, replaces the link instead.
  local t; t="$(mktemp "$(dirname "$r")/.result.XXXXXX")" || { echo "cannot write result next to $r" >&2; return 0; }
  printf '{"status":%s,"detail":%s,"at":"%s"%s}\n' "$(json_str "$1")" "$(json_str "$2")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${3:+,$3}" > "$t"
  chmod 644 "$t" && mv -f "$t" "$r" || { rm -f "$t"; echo "cannot write result $r" >&2; }
}
die() { write_result error "$1"; echo "$1" >&2; exit 1; }
# pf_drop_our_attach: drop ONLY our stale `anchor "dvpnd…"` / `anchor "sentinel-dvpn-…"` attach lines from the main
# filter ruleset and reload the rest, as the daemon's attachAnchor does (pfctl -sr | drop ours | pfctl -R -f -).
# A left attach makes the next kill-switch connect fail closed ("conflicting pf anchor attachment"). Never
# `pfctl -f /etc/pf.conf`, `-F all` or `-d` (another program's runtime rules stay). Returns 0 = nothing left,
# 1 = the reload failed. One copy for setup / uninstall / remove-tunnels (AUDIT-FINAL-MACOS M5 + M10).
PF_ATTACH_RE='^anchor "(dvpnd|sentinel-dvpn-)'
pf_has_our_attach() { pfctl -sr 2>/dev/null | grep -qE "$PF_ATTACH_RE"; }
pf_drop_our_attach() {
  local rules; rules="$(pfctl -sr 2>/dev/null)"
  printf '%s\n' "$rules" | grep -qE "$PF_ATTACH_RE" || return 0
  printf '%s\n' "$rules" | grep -vE "$PF_ATTACH_RE" | pfctl -R -f - >/dev/null 2>&1
  ! pf_has_our_attach
}
# add_ace <perms> <path>: add one allow ACE for $USER_NAME unless it already has one there. ADDS only, never
# `chmod -N`: clearing the ACL locks out every other account grant-socket.sh let in (AUDIT-FINAL-MACOS M3).
add_ace() {
  ls -led "$2" 2>/dev/null | grep -q "user:$USER_NAME allow" && return 0
  chmod +a "user:$USER_NAME allow $1" "$2"
}
# atomic_write <src> <dst> (Q0544, port of #32 7aaad4a3): replace dst with src's bytes so a power loss leaves the
# old file or the new one, never a cut one. `cat src > dst` truncates first (Linux hunt1, 2026-11-12: a spot
# preemption left a settings copy at 0 bytes and every later read saw no settings). The temp file sits in dst's
# folder and starts as `cp -p` of dst, which on macOS keeps owner, group, mode, flags and the ACL (the setup
# user's read ACE); its bytes are then replaced, flushed, and it is renamed over dst.
atomic_write() {
  local src="$1" dst="$2" tmp
  tmp="$(mktemp "$(dirname "$dst")/.$(basename "$dst").XXXXXX")" || return 1
  if [ -e "$dst" ]; then cp -p "$dst" "$tmp" || { rm -f "$tmp"; return 1; }; fi
  if ! cat "$src" > "$tmp"; then rm -f "$tmp"; return 1; fi
  sync
  mv -f "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
  sync
}
# ─── M33-1 (rc9-f-mac): the user's staged files are READ WITH THAT USER'S RIGHTS, never root's ───
# macOS has no protected_hardlinks: a staged file hard-linked to a root-only file read fine as root (`cp -Rp`) and
# its bytes landed in a home file the setup user can read. Now the user's own tar reads the staging folder (a link
# to a file the user may not read fails there) and root only unpacks that stream into its root-only folder.
# as_user <user> <cmd...>: the command as that account (directly when this already is that account: tests, rig).
as_user() { local u="$1"; shift; if [ "$(id -un)" = "$u" ]; then "$@"; else /usr/bin/sudo -n -u "$u" -- "$@"; fi; }
TAR_META=(); [ "$(uname)" = Darwin ] && TAR_META=(--no-mac-metadata)
# copy_as_user <user> <user's folder> <root-only folder>: 0 = copied; 1 = the user could not read every file.
copy_as_user() {
  local u="$1" s="$2" d="$3" rc
  as_user "$u" tar ${TAR_META[@]+"${TAR_META[@]}"} -C "$s" -cf - . | tar -C "$d" --no-same-owner -xf -
  rc=("${PIPESTATUS[@]}")
  # unpacked as root-owned files (--no-same-owner) in a folder that stays root-only, so the user cannot change the
  # copy between the link checks and its use
  chmod 700 "$d" || return 1
  [ "${rc[0]}" = 0 ] && [ "${rc[1]}" = 0 ]
}
# has_hardlink <folder>: true when a file in it has more than one name (refused: one staged name could alias another)
has_hardlink() { [ -n "$(find "$1" -type f -links +1 -print 2>/dev/null | head -1)" ]; }
# real_home <user>: that account's home folder, every link resolved; empty when there is none
real_home() {
  local h; h="$(dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  [ -n "$h" ] && (cd -P -- "$h" 2>/dev/null && pwd -P)
}
# ─── rc9-f-mac (AC-LINUX rc9-f-linux twin): --User must be the account that ASKED for this root step ───
# Otherwise a caller names `--User root` (or another account) and the staged files are read with those rights.
# asker_uid: SUDO_UID under sudo; else the first non-root process up the parent chain (the osascript admin prompt
# runs us under security_authtrampoline, whose parent is the user's osascript); empty = a root shell asked.
asker_uid() {
  if [ -n "${SUDO_UID:-}" ] && [ "$SUDO_UID" != 0 ]; then echo "$SUDO_UID"; return 0; fi
  local p="$PPID" u i
  for i in 1 2 3 4 5 6 7 8; do
    [ "${p:-0}" -gt 1 ] 2>/dev/null || return 0
    u="$(ps -o uid= -p "$p" 2>/dev/null | tr -d ' ')"; [ -n "$u" ] || return 0
    [ "$u" != 0 ] && { echo "$u"; return 0; }
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
}
# user_is_asker <user>: never root; when the asker is known, the user must be that account
user_is_asker() {
  local u="$1" a
  [ -n "$u" ] && [ "$u" != root ] || return 1
  a="$(asker_uid)"
  [ -z "$a" ] || [ "$(id -u "$u" 2>/dev/null)" = "$a" ]
}
# ─── M33-3 (rc9-f-mac): a proxy-backup row is restored only in the app's own shapes ───
# proxy_ours_ok <ours>: the app's SOCKS endpoint is always 127.0.0.1:<port>
proxy_ours_ok() { [[ "$1" =~ ^127\.0\.0\.1:[0-9]{1,5}$ ]]; }
# proxy_restore_ok <server> <port>: the value put back is a host name / address and a port (or none)
proxy_restore_ok() { [[ "$1" =~ ^[A-Za-z0-9.:-]{0,253}$ ]] && [[ "$2" =~ ^[0-9]{1,5}$ ]]; }
# canonical path without requiring it to exist (macOS has no `realpath -m`; /var → /private/var)
canon() {
  local p="$1" tail=""
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  case "/$p/" in */../*|*/./*) echo "//invalid"; return ;; esac
  while [ ! -d "$p" ]; do tail="/$(basename "$p")$tail"; p="$(dirname "$p")"; done
  printf '%s%s\n' "$(cd -P "$p" && pwd -P)" "$tail"
}
under() { # path prefix → true when path is inside prefix (after resolving)
  local p q; p="$(canon "$1")"; q="$(canon "$2")"
  [[ "$p" == "$q"/* || "$p" == "$q" ]]
}
here_dir() { cd -P "$(dirname "$1")" && pwd -P; }
svc_loaded() { launchctl print "system/$LABEL" >/dev/null 2>&1; }
svc_running() { launchctl print "system/$LABEL" 2>/dev/null | grep -q 'state = running'; }
svc_log_tail() { tail -n "${1:-3}" "$LOG_DIR/dvpnd.log" 2>/dev/null | tr '\n' ' '; }
svc_start() {
  [ -f "$PLIST" ] || return 1
  if svc_loaded; then launchctl kickstart "system/$LABEL"; else launchctl bootstrap system "$PLIST"; fi
}
svc_stop() { svc_loaded || return 0; launchctl bootout "system/$LABEL" 2>/dev/null; local i; for i in $(seq 1 60); do svc_loaded || return 0; sleep 0.5; done; return 1; }
wait_socket() { local i; for i in $(seq 1 150); do [ -S "$1" ] && return 0; sleep 0.2; done; return 1; }
# ─── E-ST owner (#38 rc.9): set_config_owner <config.toml> <owner> ───
# A kept service home (the same device key: E-ST adopted it in a fresh data dir, or a re-install) still names the
# owner it was set up for; dvpnd then checks the grant from THAT owner and the wallet the app loaded is ignored.
# Rewrites the top-level `owner = "..."` (never one inside a [section]) when it differs. Writes a temp file in the
# same root-owned folder and renames it over (no cut file); refuses a link. Prints `same` or `changed`.
set_config_owner() {
  local f="$1" o="$2" cur t
  [[ "$o" =~ ^[1-9A-HJ-NP-Za-km-z]{32,44}$ ]] || { echo "not an owner address: $o" >&2; return 2; }
  { [ -f "$f" ] && [ ! -L "$f" ]; } || { echo "no service config at $f" >&2; return 2; }
  cur=$(awk '/^[[:space:]]*\[/ { exit } /^[[:space:]]*owner[[:space:]]*=/ { v = $0; sub(/^[^=]*=[[:space:]]*"?/, "", v); sub(/"?[[:space:]]*(#.*)?$/, "", v); print v; exit }' "$f")
  [ -n "$cur" ] || { echo "the service config names no owner: $f" >&2; return 2; }
  [ "$cur" = "$o" ] && { echo same; return 0; }
  t="$(mktemp "$(dirname "$f")/.owner.XXXXXX")" || return 1
  if ! awk -v o="$o" 'BEGIN { d = 0 } !d && /^[[:space:]]*\[/ { d = 1 } !d && /^[[:space:]]*owner[[:space:]]*=/ { print "owner = \"" o "\""; d = 1; next } { print }' "$f" > "$t"; then
    rm -f -- "$t"; return 1
  fi
  chmod 600 "$t" && mv -f -- "$t" "$f" || { rm -f -- "$t"; return 1; }
  echo changed
}
