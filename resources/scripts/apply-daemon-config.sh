#!/bin/bash
# ─── Apply staged dvpnd config files and restart the service (decision D4, macOS) ───
# Run as root by the app. Takes only paths: the app wrote and validated the files in its own
# folder; this step never sees config text on its command line. It accepts only the expected
# file names (config.toml, client.config.toml, and optionally v2ray/xray.config.toml for
# whole-device mode), keeps a backup, restarts the service, and rolls back if it fails.
# Args: --Staged --DaemonHome --User [--Service] --Result
set -uo pipefail
source "$(cd -P "$(dirname "$0")" && pwd -P)/_lib.sh"
parse_args "$@"
STAGED="${ARG_Staged:-}"; HOME_DIR="${ARG_DaemonHome:-}"; USER_NAME="${ARG_User:-}"
under "$HOME_DIR" "$DAEMON_ROOT" || die "daemon home must be under $DAEMON_ROOT"
# M33-1 (rc9-f-mac): the staged folder must be the setup user's own, under that user's real home, and its files are
# read with THAT user's rights (a hard link to a root-only file cannot be read through it).
[[ "$USER_NAME" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,31}$ ]] && [ "$USER_NAME" != root ] || die "apply needs --User (the account whose app staged the settings): $USER_NAME"
id -u "$USER_NAME" >/dev/null 2>&1 || die "no such user $USER_NAME"
user_is_asker "$USER_NAME" || die "--User $USER_NAME is not the account that asked for this step"
user_home_real="$(real_home "$USER_NAME")" || die "no home folder for $USER_NAME"
staged_real="$(cd -P -- "$STAGED" 2>/dev/null && pwd -P)" || die "staged folder not found: $STAGED"
case "$staged_real" in "$user_home_real"/?*) ;; *) die "staged folder $STAGED is not under $USER_NAME's home $user_home_real" ;; esac
STAGED="$staged_real"
# cb33: ONE config.toml for the instance (no client/config.toml).
SRC=("$STAGED/config.toml")
DST=("$HOME_DIR/config.toml")
# Whole-device (tun) lives in each V2Ray/Xray service config at <instance dir>/<svc>/config.toml;
# only ones that already exist are replaced.
for s in v2ray xray; do
  if [ -e "$STAGED/$s.config.toml" ] && [ -f "$HOME_DIR/$s/config.toml" ]; then
    SRC+=("$STAGED/$s.config.toml"); DST+=("$HOME_DIR/$s/config.toml")
  fi
done
N=${#SRC[@]}
# AC-MAC-1 P2-2: the staged folder is the user's, so a file checked here could be swapped for a link before it
# is read (the service stop below takes up to 30 s). Snapshot each one ONCE into a root-owned folder and read only
# the snapshot from here on. M33-1: the snapshot is read by the USER (as_user head), so a link of either kind can
# only reach what that user may read anyway; a link or a file with more than one name is still refused.
snap="$(mktemp -d "$HOME_DIR/.staged.XXXXXX")" || die 'could not make a folder for the staged settings'
trap 'rm -rf -- "$snap"' EXIT
for ((i = 0; i < N; i++)); do
  [ -f "${DST[$i]}" ] || die "daemon home has no ${DST[$i]}"
  if [ -L "${SRC[$i]}" ] || [ ! -f "${SRC[$i]}" ]; then die "staged file is not a plain file: ${SRC[$i]}"; fi
  [ "$(stat -f %l -- "${SRC[$i]}")" = 1 ] || die "staged file has more than one name (a hard link): ${SRC[$i]}"
  as_user "$USER_NAME" head -c 65537 -- "${SRC[$i]}" > "$snap/$i" 2>/dev/null || die "could not read the staged file as $USER_NAME: ${SRC[$i]}"
  [ "$(stat -f %z "$snap/$i")" -le 65536 ] || die "staged file too large: ${SRC[$i]}"
done
for ((i = 0; i < N; i++)); do cp -p "${DST[$i]}" "${DST[$i]}.bak"; done
has_svc=0; [ -f "$PLIST" ] && has_svc=1
[ $has_svc = 1 ] && svc_stop
# atomic_write (Q0544) keeps owner, mode and ACL (root:sentinel-dvpn + the user's read ACE) and never leaves a cut file
for ((i = 0; i < N; i++)); do atomic_write "$snap/$i" "${DST[$i]}" || die "could not write ${DST[$i]}"; done
if [ $has_svc = 1 ]; then
  ok=0
  if svc_start; then
    for _ in $(seq 1 150); do if [ -S "$HOME_DIR/daemon.sock" ] && svc_running; then ok=1; break; fi; sleep 0.2; done
  fi
  if [ $ok = 0 ]; then
    why="$(svc_log_tail 2)"
    for ((i = 0; i < N; i++)); do atomic_write "${DST[$i]}.bak" "${DST[$i]}"; done
    # AUDIT-FINAL-MACOS M2: the rollback start was never checked; say which state the service is in now.
    back=0
    svc_stop; if svc_start; then
      for _ in $(seq 1 150); do if [ -S "$HOME_DIR/daemon.sock" ] && svc_running; then back=1; break; fi; sleep 0.2; done
    fi
    if [ $back = 1 ]; then die "service failed to start with the new settings; previous settings restored and the service is running again: $why"; fi
    die "service failed to start with the new settings; previous settings restored but the service is NOT running ($(svc_log_tail 2)). Next: devnet-dvpn daemon doctor, then sudo launchctl kickstart -k system/$LABEL: $why"
  fi
  write_result ok 'applied and restarted'
else
  write_result ok 'applied (no service installed)'
fi
