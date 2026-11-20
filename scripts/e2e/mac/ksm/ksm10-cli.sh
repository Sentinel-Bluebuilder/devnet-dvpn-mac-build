#!/bin/bash
# Q0508 KSM10 CLI twin (guest). $1 = protocol (v2ray|xray), $2 = whole-device (true|false), $3 = run label.
# stdin line 1 = login password. Wallet = key file ~/ksm/ksm-wallet.json, profile ~/ksm/profile.
IFS= read -r PW; security unlock-keychain -p "$PW" ~/Library/Keychains/login.keychain-db; unset PW
export DVPN_KEYFILE=$HOME/ksm/ksm-wallet.json DVPN_DATA_DIR=$HOME/ksm/profile PATH=/usr/local/bin:$PATH
P=$1; WD=$2; RUN=${3:-r1}
case $P in v2ray) NODE=Di5V9K2Vt5uptJUk7oVVnkDRXt9qWy5HhLbkEJMxEuM2 ;; xray) NODE=E9RG1iZJjsLfEuLfDYTHM4yXCjyFE21jBbJLFvGoL2FD ;; *) echo "protocol?"; exit 2 ;; esac
A=/Applications/Firefox.app/Contents/MacOS/firefox
B="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
H="/Library/Application Support/sentinel-dvpn/c0"
hashes() { echo "cfg_sha       $(sudo -n shasum -a 256 "$H/config.toml" | cut -c1-12) $P:$(sudo -n shasum -a 256 "$H/$P/config.toml" 2>/dev/null | cut -c1-12)"
  echo "cfg_split     $(sudo -n awk '/^\[split\]/{p=1;next} /^\[/{p=0} p&&/^(mode|apps)/' "$H/config.toml" | tr '\n' ' ' | cut -c1-200)"
  echo "cfg_ks        $(sudo -n awk -F"'" '/^kill_switch/{print $2}' "$H/config.toml")  tun=$(sudo -n awk '/^tun/{print $3}' "$H/$P/config.toml" 2>/dev/null)"; }
st() { echo; echo "##### KSM10 CLI $P wd=$WD $RUN :: $*"; }
snap() { ~/ksm/sample.sh "$1"; hashes; }
rc() { devnet-dvpn connect "$NODE" --basis per_gb --yes 2>&1 | tail -1; sleep 5; }
d() { echo "> daemon set $*"; devnet-dvpn daemon set "$@" --yes 2>&1 | tail -3; echo "exit=${PIPESTATUS[0]}"; }

st "0 baseline: KS off, split off, whole-device $WD"
d --kill-switch off --split-mode off --split-apps none --whole-device "$WD"
snap "KSM10 $P wd=$WD $RUN s0 baseline"
st "1 connect $P"
devnet-dvpn connect "$NODE" --basis per_gb --yes 2>&1 | tail -2; sleep 5
snap "KSM10 $P wd=$WD $RUN s1 connected"
st "2 split include app A (Firefox)"; d --split-mode include --split-apps "$A"; sleep 5
snap "KSM10 $P wd=$WD $RUN s2 A on (after set)"
echo "> reconnect"; rc
snap "KSM10 $P wd=$WD $RUN s2 A on (reconnected)"
st "3 KS persist"; d --kill-switch persist; sleep 5
snap "KSM10 $P wd=$WD $RUN s3 KS persist (after set)"
echo "> reconnect"; rc
snap "KSM10 $P wd=$WD $RUN s3 KS persist (reconnected)"
st "4 split app B on (A+B)"; d --split-apps "$A;$B"; sleep 5
snap "KSM10 $P wd=$WD $RUN s4 A+B on (after set)"
echo "> reconnect"; rc
snap "KSM10 $P wd=$WD $RUN s4 A+B on (reconnected)"
st "5 KS off"; d --kill-switch off; sleep 5
snap "KSM10 $P wd=$WD $RUN s5 KS off (after set)"
echo "> reconnect"; rc
snap "KSM10 $P wd=$WD $RUN s5 KS off (reconnected)"
st "6 app A off (B only)"; d --split-apps "$B"; sleep 5
snap "KSM10 $P wd=$WD $RUN s6 A off (after set)"
echo "> reconnect"; rc
snap "KSM10 $P wd=$WD $RUN s6 A off (reconnected)"
st "7 disconnect, split off"
devnet-dvpn disconnect 2>&1 | tail -1; d --split-mode off --split-apps none; sleep 3
snap "KSM10 $P wd=$WD $RUN s7 end"
