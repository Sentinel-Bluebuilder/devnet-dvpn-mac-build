#!/usr/bin/env bash
# ─── One-time setup of the GCP host VM (ddv-mac-host-1) that runs the macOS guest ───
# Installs QEMU/KVM and OSX-KVM, downloads the macOS recovery image from Apple and makes the
# guest disk. Idempotent. Usage (on the host): bash host-setup.sh [sonoma|sequoia]
set -euo pipefail
VER="${1:-sonoma}"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-system-x86 qemu-utils \
  python3 python3-pip git make dmg2img p7zip-full socat imagemagick netcat-openbsd >/dev/null
sudo usermod -aG kvm "$USER"
[ -d ~/OSX-KVM ] || git clone -q --depth 1 --recursive https://github.com/kholia/OSX-KVM.git ~/OSX-KVM
cd ~/OSX-KVM
if [ ! -f BaseSystem.img ]; then
  python3 fetch-macOS-v2.py -s "$VER"
  dmg2img -i BaseSystem.dmg BaseSystem.img
fi
[ -f mac_hdd_ng.img ] || qemu-img create -f qcow2 mac_hdd_ng.img 160G
echo "host ready: $(ls -la BaseSystem.img mac_hdd_ng.img | awk '{print $5, $9}' | tr '\n' ' ')"
