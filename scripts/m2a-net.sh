#!/usr/bin/env bash
# Bridge + tap for the M2a microVM.  Idempotent; safe to call multiple times.
# Requires passwordless sudo for /usr/sbin/ip and /usr/sbin/sysctl only.
#
# Network layout:
#   mkn-br0  10.88.0.1/24  (bridge / host gateway)
#   mkn0     tap, owned by $USER, enslaved to mkn-br0
#   VM eth0  10.88.0.2/24  (static, set in /boot/config.yaml)
set -euo pipefail

BR=mkn-br0
TAP="${TAP:-mkn0}"
BRIP=10.88.0.1/24
USER_="$(whoami)"

ip link show "$BR" >/dev/null 2>&1 || sudo /usr/sbin/ip link add name "$BR" type bridge
ip addr show "$BR" | grep -q 10.88.0.1 || sudo /usr/sbin/ip addr add "$BRIP" dev "$BR"
ip link show "$TAP" >/dev/null 2>&1 || sudo /usr/sbin/ip tuntap add mode tap user "$USER_" name "$TAP"
sudo /usr/sbin/ip link set "$TAP" master "$BR"
sudo /usr/sbin/ip link set "$BR" up
sudo /usr/sbin/ip link set "$TAP" up
sudo /usr/sbin/sysctl -wq net.ipv4.ip_forward=1
echo "bridge $BR + tap $TAP up (gw 10.88.0.1, VM 10.88.0.2)"
