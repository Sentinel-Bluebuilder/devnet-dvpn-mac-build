#!/usr/bin/env bash
# ─── Boot the macOS guest on ddv-mac-host-1 (headless) ───
# VNC on host loopback :5901 only (tunnel it; a browser cannot show VNC). QMP at ~/qmp.sock
# (vmctl.py: screenshots, keys, clicks), HMP at ~/mon.sock. Guest SSH = host 127.0.0.1:2222.
# Usage: bash guest-boot.sh [--install]   (--install attaches the macOS recovery image)
set -euo pipefail
cd ~/OSX-KVM
pgrep -f "qemu-system-x86_64.*mac_hdd_ng" >/dev/null && { echo "guest already running"; exit 0; }
echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs >/dev/null
OPTS="+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check"
# Size the guest from the host: every vCPU, RAM minus ~2.5 GB for the host (n2-standard-4 → 4 / ~13.5 GB).
SMP="${GUEST_SMP:-$(nproc)}"
MEM="${GUEST_MEM_MB:-$(( $(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo) - 2560 ))}"
[ "$MEM" -gt 14336 ] && MEM=14336
args=(
  -name ddv-mac-1 -enable-kvm -m "$MEM"
  -cpu Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,"$OPTS"
  -machine q35 -smp "$SMP",cores="$(( SMP / 2 > 0 ? SMP / 2 : 1 ))",threads=$(( SMP > 1 ? 2 : 1 )),sockets=1
  -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0
  -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
  -drive if=pflash,format=raw,readonly=on,file=OVMF_CODE_4M.fd
  -drive if=pflash,format=raw,file=OVMF_VARS-1920x1080.fd
  -smbios type=2
  -device ich9-ahci,id=sata
  -drive id=OpenCoreBoot,if=none,snapshot=on,format=qcow2,file=OpenCore/OpenCore.qcow2
  -device ide-hd,bus=sata.2,drive=OpenCoreBoot
  -drive id=MacHDD,if=none,file=mac_hdd_ng.img,format=qcow2,cache=writeback
  -device ide-hd,bus=sata.4,drive=MacHDD
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=net0,id=net0,mac=52:54:00:c9:18:27
  -device vmware-svga -display none -vnc 127.0.0.1:1
  -qmp unix:"$HOME/qmp.sock",server,nowait -monitor unix:"$HOME/mon.sock",server,nowait
  -daemonize -pidfile "$HOME/qemu.pid" -D "$HOME/qemu.log"
)
if [ "${1:-}" = "--install" ]; then
  args+=(-drive id=InstallMedia,if=none,file=BaseSystem.img,format=raw -device ide-hd,bus=sata.3,drive=InstallMedia)
fi
qemu-system-x86_64 "${args[@]}"
echo "guest started (pid $(cat ~/qemu.pid))"
# OpenCore's picker has no timeout and its NVRAM default did not survive a host stop (10-24), so a
# host restart would wait at the picker forever. Normal boots pick MacHD (2nd entry) after 30 s.
if [ "${1:-}" != "--install" ] && [ -x ~/vmctl.py ]; then
  nohup bash -c 'sleep 30; python3 ~/vmctl.py key right; python3 ~/vmctl.py key ret' >/dev/null 2>&1 &
fi
