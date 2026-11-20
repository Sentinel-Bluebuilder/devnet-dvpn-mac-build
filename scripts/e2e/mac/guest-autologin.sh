#!/usr/bin/env bash
# ─── Turn on GUI auto-login for the rig user (a real WindowServer session after boot) ───
# Usage (laptop): awk -F': ' 'NR==2{print $2}' ~/memory/ddv-vm-wallets/ddv-mac-1-guest-login.txt \
#                   | bash scripts/e2e/mac/guest-autologin.sh <guest ssh host>
# The password arrives on stdin only: never on a command line, never in a log. It is written as
# /etc/kcpassword (the loginwindow XOR format, root 0600), then loginwindow's autoLoginUser is set.
# Takes effect at the next boot. Undo: sudo rm /etc/kcpassword; sudo defaults delete
# /Library/Preferences/com.apple.loginwindow autoLoginUser
set -euo pipefail
H="${1:?guest ssh host}"
U="${GUEST_USER:-ddv}"
ssh "$H" "sudo python3 -c '
import os, sys
pw = sys.stdin.readline().rstrip(\"\\n\").encode()
if not pw:
    sys.exit(\"no password on stdin\")
key = [0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F]
data = pw + b\"\\0\"
data += b\"\\0\" * (-len(data) % 12)
enc = bytes(b ^ key[i % len(key)] for i, b in enumerate(data))
fd = os.open(\"/etc/kcpassword\", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, enc); os.close(fd)
' && sudo chown root:wheel /etc/kcpassword && sudo chmod 600 /etc/kcpassword \
  && sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser '$U' \
  && echo \"auto-login set for $U (next boot)\""
