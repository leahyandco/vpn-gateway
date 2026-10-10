#!/bin/bash
#
# Shows how the VPN gateway is doing. Installed as vpn-gateway-status.

CONF=/etc/vpn-gateway.conf
LEASES=/var/lib/misc/dnsmasq.leases

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

good() { printf "    %-16s ${GREEN}%s${NC}\n" "$1" "$2"; }
bad() { printf "    %-16s ${RED}%s${NC}\n" "$1" "$2"; PROBLEMS=$((PROBLEMS + 1)); }
note() { printf "    %-16s %s\n" "$1" "$2"; }
section() { echo; echo -e "${BOLD}$1${NC}"; }

running() { systemctl is-active --quiet "$1"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this as root: sudo vpn-gateway-status" >&2
    exit 1
fi
if [ ! -f "$CONF" ]; then
    echo "The gateway isn't installed yet, run install.sh first" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$CONF"

PROBLEMS=0

section "VPN ($VPN_TYPE)"
if running "$VPN_SERVICE"; then
    good "Service" "running ($VPN_SERVICE)"
else
    bad "Service" "not running ($VPN_SERVICE)"
fi
vpn_ip=$(ip -4 -o addr show dev "$VPN_INTERFACE" 2>/dev/null | awk '{print $4; exit}')
if [ -n "$vpn_ip" ]; then
    good "Tunnel" "$VPN_INTERFACE is up, $vpn_ip"
    public_ip=$(curl -s --max-time 8 --interface "$VPN_INTERFACE" https://ifconfig.me)
    if [ -n "$public_ip" ]; then
        good "Public IP" "$public_ip"
    else
        bad "Public IP" "can't reach the internet through the tunnel"
    fi
else
    bad "Tunnel" "$VPN_INTERFACE is down, LAN devices have no internet"
fi

section "Kill switch"
if running vpn-gateway-firewall; then
    good "Firewall" "on"
else
    bad "Firewall" "off"
fi
if iptables -S FORWARD | grep -q '^-P FORWARD DROP'; then
    good "Forwarding" "only through $VPN_INTERFACE, everything else dropped"
else
    bad "Forwarding" "default policy isn't DROP"
fi
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ]; then
    good "IP forwarding" "on"
else
    bad "IP forwarding" "off"
fi

section "LAN"
lan_ip=$(ip -4 -o addr show dev "$LAN_INTERFACE" 2>/dev/null | awk '{print $4; exit}')
if [ "$(cat "/sys/class/net/$LAN_INTERFACE/carrier" 2>/dev/null)" = 1 ]; then
    good "Adapter" "$LAN_INTERFACE ${lan_ip:-no address}, cable connected"
else
    note "Adapter" "$LAN_INTERFACE ${lan_ip:-no address}, nothing plugged in"
fi
if running dnsmasq; then
    good "DHCP and DNS" "running, handing out $DHCP_START to $DHCP_END"
else
    bad "DHCP and DNS" "dnsmasq isn't running"
fi
if [ -f "$LEASES" ]; then
    leases=$(awk -v now="$(date +%s)" '$1 == 0 || $1 > now' "$LEASES" | wc -l)
    note "Devices" "$leases with a current lease"
fi
if command -v dig >/dev/null && running dnsmasq; then
    answer=$(dig +short +time=3 +tries=1 @"$LAN_ADDRESS" example.com A 2>/dev/null | head -n1)
    if [[ $answer =~ ^[0-9.]+$ ]]; then
        good "DNS lookup" "working, via $UPSTREAM_DNS"
    else
        bad "DNS lookup" "no answer from $UPSTREAM_DNS"
    fi
fi

section "WAN"
wan_ip=$(ip -4 -o addr show dev "$WAN_INTERFACE" 2>/dev/null | awk '{print $4; exit}')
if [ -n "$wan_ip" ]; then
    good "Adapter" "$WAN_INTERFACE $wan_ip"
else
    bad "Adapter" "$WAN_INTERFACE has no address"
fi
if running ssh || running ssh.socket; then
    good "SSH" "open on both adapters, port $SSH_PORTS"
else
    bad "SSH" "not running"
fi

section "Monitor"
if running vpn-gateway-monitor; then
    good "Service" "running"
else
    bad "Service" "not running"
fi
echo "    Recent log:"
journalctl -u vpn-gateway-monitor -n 5 --no-pager -o short 2>/dev/null | sed 's/^/      /'

echo
if [ "$PROBLEMS" -eq 0 ]; then
    echo -e "${GREEN}Everything looks good.${NC}"
else
    echo -e "${RED}$PROBLEMS problem(s) found.${NC} Logs: sudo journalctl -u $VPN_SERVICE -u dnsmasq -u vpn-gateway-monitor"
fi
