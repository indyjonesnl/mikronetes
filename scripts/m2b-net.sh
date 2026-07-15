#!/usr/bin/env bash
# M2b host bridge + four tap devices.
set -euo pipefail

BR="${BR:-mkn-br0}"
TAPS="${TAPS:-mkn0 mkn1 mkn2 mkn3}"

sudo /usr/sbin/ip link show "$BR" >/dev/null 2>&1 || sudo /usr/sbin/ip link add "$BR" type bridge
sudo /usr/sbin/ip addr replace 10.88.0.1/24 dev "$BR"
sudo /usr/sbin/ip link set "$BR" up

for tap in $TAPS; do
  sudo /usr/sbin/ip link show "$tap" >/dev/null 2>&1 || \
    sudo /usr/sbin/ip tuntap add dev "$tap" mode tap user "$USER"
  sudo /usr/sbin/ip link set "$tap" master "$BR"
  sudo /usr/sbin/ip link set "$tap" up
done

sudo /usr/sbin/sysctl -wq net.ipv4.ip_forward=1
if command -v /usr/sbin/iptables >/dev/null 2>&1; then
  # Docker commonly sets FORWARD=DROP while br_netfilter sends bridge traffic
  # through iptables. Without these rules, host<->VM works but VM<->VM times out.
  sudo /usr/sbin/iptables -C FORWARD -i "$BR" -o "$BR" -j ACCEPT >/dev/null 2>&1 || \
    sudo /usr/sbin/iptables -I FORWARD 1 -i "$BR" -o "$BR" -j ACCEPT
  sudo /usr/sbin/iptables -C FORWARD -i "$BR" -j ACCEPT >/dev/null 2>&1 || \
    sudo /usr/sbin/iptables -I FORWARD 1 -i "$BR" -j ACCEPT
  sudo /usr/sbin/iptables -C FORWARD -o "$BR" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1 || \
    sudo /usr/sbin/iptables -I FORWARD 1 -o "$BR" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
fi
sudo /usr/sbin/ip route replace 10.244.0.0/24 via 10.88.0.2 dev "$BR"
sudo /usr/sbin/ip route replace 10.244.1.0/24 via 10.88.0.3 dev "$BR"
sudo /usr/sbin/ip route replace 10.244.2.0/24 via 10.88.0.4 dev "$BR"
sudo /usr/sbin/ip route replace 10.244.3.0/24 via 10.88.0.5 dev "$BR"

echo "bridge $BR + taps [$TAPS] up for M2b"
