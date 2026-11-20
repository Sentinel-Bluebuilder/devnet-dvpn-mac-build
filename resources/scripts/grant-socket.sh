#!/bin/bash
# ─── Give one more macOS account the VPN service socket, with no log out (port of #31 a2edc22) ───
# setup-daemon.sh already grants the account that ran setup (ACL with file_inherit on the home, so
# the socket sentinel-dvpnd re-creates on every start inherits it). This step is for an account
# that did NOT run setup: a second macOS user on the same Mac whose app is refused by the socket.
# It ADDS entries only, never `chmod -N`: clearing the ACL would lock out the account that ran setup.
# Same entries as setup-daemon.sh step 2, plus group membership (macOS applies it at once).
# Args: --DaemonHome --User [--Group] --Result
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd -P)"
source "$HERE/_lib.sh"
parse_args "$@"
HOME_DIR="${ARG_DaemonHome:-}"; USER_NAME="${ARG_User:-}"; GROUP="${ARG_Group:-sentinel-dvpn}"

under "$HOME_DIR" "$DAEMON_ROOT" || die "daemon home must be under $DAEMON_ROOT"
[ -f "$HOME_DIR/config.toml" ] || die 'the VPN service is not set up on this Mac yet'
[[ "$USER_NAME" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,31}$ ]] && [ "$USER_NAME" != root ] || die "bad user name $USER_NAME"
id -u "$USER_NAME" >/dev/null 2>&1 || die "no such user $USER_NAME"
[[ "$GROUP" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "bad group name $GROUP"

# add_ace: _lib.sh (shared with setup-daemon.sh, AUDIT M3)

dseditgroup -o read "$GROUP" >/dev/null 2>&1 || die "socket group $GROUP is missing; set the VPN service up again"
dseditgroup -o checkmember -m "$USER_NAME" "$GROUP" >/dev/null 2>&1 \
  || dseditgroup -o edit -a "$USER_NAME" -t user "$GROUP" || die "could not add $USER_NAME to $GROUP"
add_ace 'search,readattr' "$DAEMON_ROOT" || die 'could not grant the home folder ACL'
add_ace 'list,search,read,write,readattr,readextattr,file_inherit' "$HOME_DIR" || die 'could not grant the socket ACL'
while IFS= read -r -d '' d; do add_ace 'list,search,readattr' "$d"; done \
  < <(find "$HOME_DIR" -mindepth 1 -type d ! -path '*/keys' ! -path '*/keys/*' -print0 2>/dev/null)
while IFS= read -r -d '' f; do add_ace 'read,readattr' "$f"; done \
  < <(find "$HOME_DIR" -name config.toml -type f ! -path '*/keys/*' -print0 2>/dev/null)
[ -f "$HOME_DIR/device.pub" ] && add_ace 'read,readattr' "$HOME_DIR/device.pub"
# the running socket was created before this grant: give it the entry directly too
[ -S "$HOME_DIR/daemon.sock" ] && add_ace 'read,write,readattr' "$HOME_DIR/daemon.sock"

write_result ok "socket access granted to $USER_NAME"
echo "socket access granted to $USER_NAME"
exit 0
