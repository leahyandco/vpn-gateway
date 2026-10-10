#!/bin/bash
#
# Removes the VPN gateway. Your network config and SSH are left alone, and it
# asks before removing the VPN config or any packages.

set -u

CONF=/etc/vpn-gateway.conf

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

info() { echo -e "${GREEN}==>${NC} $*"; }

yes_no() {
    local reply
    read -r -p "$1 (y/n) [$2]: " reply || true
    [[ ${reply:-$2} =~ ^[Yy] ]]
}

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error:${NC} run this as root, e.g. sudo ./uninstall.sh" >&2
    exit 1
fi

echo "This removes the VPN gateway: the kill switch, DHCP and DNS for the LAN,"
echo "the monitor and the VPN service. Devices on the LAN will lose internet."
echo
yes_no "Continue?" n || { echo "Cancelled."; exit 0; }

VPN_SERVICE=
if [ -f "$CONF" ]; then
    # shellcheck source=/dev/null
    . "$CONF"
fi

info "Stopping services"
for unit in vpn-gateway-monitor vpn-monitor dnsmasq $VPN_SERVICE vpn-gateway-firewall; do
    systemctl disable -q --now "$unit" 2>/dev/null || true
done

info "Removing the firewall rules"
echo 0 > /proc/sys/net/ipv4/ip_forward
for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null || continue
    $ipt -P INPUT ACCEPT
    $ipt -P FORWARD ACCEPT
    $ipt -P OUTPUT ACCEPT
    $ipt -F INPUT
    $ipt -F FORWARD
    $ipt -F OUTPUT
done
iptables -t nat -F POSTROUTING 2>/dev/null
iptables -t mangle -F FORWARD 2>/dev/null
for chain in PREROUTING OUTPUT; do
    iptables -t mangle -D "$chain" -j "vpngw-$chain" 2>/dev/null
    iptables -t mangle -F "vpngw-$chain" 2>/dev/null
    iptables -t mangle -X "vpngw-$chain" 2>/dev/null
done
while ip -4 rule del lookup 200 2>/dev/null; do :; done
ip route flush table 200 2>/dev/null
# The older version of this project saved its rules to load at boot
if command -v netfilter-persistent >/dev/null; then
    netfilter-persistent save >/dev/null 2>&1
fi

info "Removing files"
rm -f /usr/local/bin/vpn-gateway-firewall \
    /usr/local/bin/vpn-gateway-monitor \
    /usr/local/bin/vpn-gateway-status \
    /usr/local/bin/vpn-monitor \
    /etc/systemd/system/vpn-gateway-firewall.service \
    /etc/systemd/system/vpn-gateway-monitor.service \
    /etc/systemd/system/vpn-monitor.service \
    /etc/dnsmasq.d/vpn-gateway.conf \
    /etc/sysctl.d/30-vpn-gateway.conf \
    /var/log/vpn-gateway-monitor.log \
    "$CONF"
for unit in dnsmasq wg-quick@wg0 openvpn-client@vpn; do
    rm -f "/etc/systemd/system/$unit.service.d/vpn-gateway.conf"
    rmdir "/etc/systemd/system/$unit.service.d" 2>/dev/null
done
systemctl daemon-reload

echo
if yes_no "Delete the VPN config files? They contain your VPN keys or password." n; then
    rm -f /etc/wireguard/wg0.conf /etc/openvpn/client/vpn.conf /etc/openvpn/client/vpn-auth.txt
fi
if yes_no "Remove the dnsmasq, WireGuard and OpenVPN packages?" n; then
    apt-get remove -y dnsmasq wireguard-tools openvpn
fi

echo
info "Done. The LAN adapter keeps its static IP, change your network config if you want it back."
