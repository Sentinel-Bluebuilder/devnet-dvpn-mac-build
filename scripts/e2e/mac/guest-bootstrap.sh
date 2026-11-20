#!/bin/bash
# ─── ddv-mac-1 guest provisioning (run as the test user `ddv`, who has passwordless sudo) ───
# Idempotent. Usage from the laptop: ssh ddv-mac 'bash -s' < scripts/e2e/mac/guest-bootstrap.sh
#   1. deadman LaunchDaemon: 3 failed egress checks in a row → release everything a test can
#      leave (dvpnd service, protocol processes, the dvpnd pf anchor, DNS, the system proxy)
#   2. no sleep / screensaver / automatic updates (a test run must not be interrupted)
#   3. Xcode command line tools, Homebrew, Node 22, Google Chrome (system-proxy oracle)
set -uo pipefail
log() { echo "[ddv-bootstrap] $*"; }
[ "$(id -u)" != 0 ] || { echo 'run as the test user, not root' >&2; exit 1; }
sudo -n true || { echo 'the test user needs passwordless sudo first' >&2; exit 1; }

# ─── 1. deadman ───
sudo install -d -m 755 /usr/local/sbin
sudo tee /usr/local/sbin/ddv-deadman >/dev/null <<'DM'
#!/bin/bash
# A test that blocks egress on purpose touches /var/run/ddv-deadman.hold (honoured for 4 min).
F=/var/run/ddv-deadman.fails
H=/var/run/ddv-deadman.hold
if [ -f "$H" ] && [ $(( $(date +%s) - $(stat -f %m "$H") )) -lt 240 ]; then exit 0; fi
ok=0
for u in https://www.google.com https://1.1.1.1; do /usr/bin/curl -s -m 8 -o /dev/null "$u" && ok=1 && break; done
if [ "$ok" = 1 ]; then echo 0 > "$F"; exit 0; fi
n=$(( $(cat "$F" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$F"
[ "$n" -lt 3 ] && exit 0
logger -t ddv-deadman 'network down 3x: releasing dvpnd state'
launchctl bootout system/network.sentinel.devnet-dvpn.dvpnd 2>/dev/null
pkill -TERM -x hysteria2; pkill -TERM -x v2ray; pkill -TERM -x xray; pkill -TERM -x openvpn
pkill -TERM -f wireguard-go; pkill -TERM -f amneziawg-go
rm -f /var/run/wireguard/*.name /var/run/wireguard/*.sock /var/run/amneziawg/*.name /var/run/amneziawg/*.sock 2>/dev/null
pfctl -a dvpnd -F all 2>/dev/null
for t in /var/db/dvpnd/client/client/firewall-pf.token /var/db/dvpnd/client/firewall-pf.token; do
  [ -f "$t" ] && pfctl -X "$(cat "$t")" 2>/dev/null && rm -f "$t"
done
networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*' | while IFS= read -r s; do
  networksetup -setdnsservers "$s" Empty
  networksetup -setsocksfirewallproxystate "$s" off
done
dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null
echo 0 > "$F"
DM
sudo chmod 755 /usr/local/sbin/ddv-deadman
sudo tee /Library/LaunchDaemons/network.sentinel.ddv-deadman.plist >/dev/null <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>network.sentinel.ddv-deadman</string>
  <key>ProgramArguments</key><array><string>/usr/local/sbin/ddv-deadman</string></array>
  <key>StartInterval</key><integer>40</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>/var/log/ddv-deadman.log</string>
</dict>
</plist>
PL
sudo chown root:wheel /Library/LaunchDaemons/network.sentinel.ddv-deadman.plist
sudo chmod 644 /Library/LaunchDaemons/network.sentinel.ddv-deadman.plist
sudo launchctl bootout system/network.sentinel.ddv-deadman 2>/dev/null
sudo launchctl bootstrap system /Library/LaunchDaemons/network.sentinel.ddv-deadman.plist && log 'deadman loaded'

# ─── 2. no interruptions ───
sudo pmset -a sleep 0 displaysleep 0 disksleep 0 standby 0 autorestart 1 2>/dev/null
defaults -currentHost write com.apple.screensaver idleTime 0
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false
log 'sleep, screensaver and automatic updates off'

# ─── 3. tools ───
if ! xcode-select -p >/dev/null 2>&1; then
  log 'Xcode command line tools'
  sudo touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  label=$(softwareupdate -l 2>/dev/null | grep -E '^\s*\* Label: Command Line Tools' | sed 's/^.*Label: //' | sort -V | tail -1)
  [ -n "$label" ] && sudo softwareupdate -i "$label" --verbose
  sudo rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
fi
xcode-select -p >/dev/null 2>&1 || { echo 'Xcode command line tools did not install' >&2; exit 1; }

BREW=/usr/local/bin/brew
if [ ! -x "$BREW" ]; then
  log 'Homebrew'
  if [ "$(uname -m)" = arm64 ]; then
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  else
    # Homebrew 7 dropped Intel Macs to tier 3: install.sh refuses x86_64, but brew itself still
    # runs and Intel ("sonoma") bottles are still published. Lay out /usr/local by hand.
    D='Homebrew bin etc include lib sbin share var opt Cellar Caskroom Frameworks'
    for d in $D; do sudo mkdir -p "/usr/local/$d"; sudo chown -R "$(id -un):admin" "/usr/local/$d"; done
    [ -d /usr/local/Homebrew/.git ] || git clone -q https://github.com/Homebrew/brew /usr/local/Homebrew
    ln -sf /usr/local/Homebrew/bin/brew "$BREW"
  fi
fi
[ -x "$BREW" ] || { echo 'Homebrew did not install' >&2; exit 1; }
grep -q 'brew shellenv' ~/.zprofile 2>/dev/null || echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.zprofile
grep -q 'brew shellenv' ~/.bash_profile 2>/dev/null || echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.bash_profile
eval "$("$BREW" shellenv)"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
# Node 22 from nodejs.org: Homebrew has no Intel / pre-macOS-27 bottle for node@22 any more and
# building it from source takes hours. Checked against the release's SHASUMS256.txt.
if ! node --version 2>/dev/null | grep -q '^v22\.'; then
  log 'node 22'
  NV=$(curl -fsSL https://nodejs.org/dist/index.json | tr '{' '\n' | grep -o '"version":"v22\.[0-9.]*"' | head -1 | cut -d'"' -f4)
  NA=$([ "$(uname -m)" = arm64 ] && echo arm64 || echo x64)
  T="node-$NV-darwin-$NA.tar.gz"; d=$(mktemp -d)
  curl -fsSL -o "$d/$T" "https://nodejs.org/dist/$NV/$T"
  curl -fsSL -o "$d/SHASUMS256.txt" "https://nodejs.org/dist/$NV/SHASUMS256.txt"
  (cd "$d" && grep " $T\$" SHASUMS256.txt | shasum -a 256 -c -) || { echo 'node download failed its checksum' >&2; exit 1; }
  sudo rm -rf /usr/local/lib/node22 && sudo mkdir -p /usr/local/lib/node22
  sudo tar -xzf "$d/$T" -C /usr/local/lib/node22 --strip-components=1
  for b in node npm npx; do sudo ln -sf "/usr/local/lib/node22/bin/$b" "/usr/local/bin/$b"; done
  rm -rf "$d"
fi
brew list --formula jq >/dev/null 2>&1 || brew install jq

if [ ! -d '/Applications/Google Chrome.app' ]; then
  log 'Google Chrome'
  d=$(mktemp -d)
  curl -fsSL -o "$d/chrome.dmg" https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg
  m=$(hdiutil attach -nobrowse -noverify -readonly "$d/chrome.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)
  sudo cp -R "$m/Google Chrome.app" /Applications/
  hdiutil detach "$m" -quiet
  rm -rf "$d"
fi

# Firefox: the split-by-app tests (SOCKS + remote DNS profile, its own sockets)
[ -d /Applications/Firefox.app ] || { log 'Firefox'; brew install --cask firefox; }
log "ready: macOS $(sw_vers -productVersion), node $(node --version), brew $(brew --version | head -1 | awk '{print $2}'), chrome $([ -d '/Applications/Google Chrome.app' ] && echo yes || echo no)"
