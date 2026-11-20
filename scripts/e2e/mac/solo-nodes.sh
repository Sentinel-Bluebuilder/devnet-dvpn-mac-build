#!/usr/bin/env bash
# ─── Point a rig's matrix at the SOLO node (node-4) or back at node-3 ───
#   bash scripts/e2e/mac/solo-nodes.sh on  [guest]   writes ~/matrix/nodes.env in the guest from ~/memory/node-ips.env
#   bash scripts/e2e/mac/solo-nodes.sh off [guest]   removes it (the matrix is back on node-3)
# Run "on" only after node-4's start rewrote NODE4_IP (it is ephemeral). Prints the NODE_IP for
# matrix.sh (the laptop side aims the host faults at it): NODE_IP=<ip> bash scripts/e2e/mac/turn.sh …
set -euo pipefail
MAC=${2:-ddv-mac}
case "${1:-}" in
  on)
    # shellcheck disable=SC1090
    . ~/memory/node-ips.env
    for v in NODE4_IP NODE4_WG NODE4_AWG NODE4_OVPN NODE4_HY2 NODE4_V2RAY NODE4_XRAY; do
      [ -n "${!v:-}" ] || { echo "solo-nodes: $v is empty in ~/memory/node-ips.env" >&2; exit 1; }
    done
    printf 'NODE_IP=%s\nNODE_WIREGUARD=%s\nNODE_AMNEZIAWG=%s\nNODE_OPENVPN=%s\nNODE_HYSTERIA2=%s\nNODE_V2RAY=%s\nNODE_XRAY=%s\n' \
      "$NODE4_IP" "$NODE4_WG" "$NODE4_AWG" "$NODE4_OVPN" "$NODE4_HY2" "$NODE4_V2RAY" "$NODE4_XRAY" |
      ssh "$MAC" 'mkdir -p ~/matrix && cat > ~/matrix/nodes.env'
    echo "NODE_IP=$NODE4_IP"
    ;;
  off) ssh "$MAC" 'rm -f ~/matrix/nodes.env'; echo 'back on node-3' ;;
  *) echo 'usage: solo-nodes.sh on|off [guest]' >&2; exit 2 ;;
esac
