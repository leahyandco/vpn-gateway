#!/bin/bash

# VPN Gateway Kill Switch Firewall
# Blocks all traffic except through VPN tunnel

set -e

if [ ! -f /etc/vpn-gateway.conf ]; then
    echo "Error: /etc/vpn-gateway.conf not found"
    exit 1
fi

source /etc/vpn-gateway.conf

# Determine VPN interface
if [ "$VPN_TYPE" = "openvpn" ]; then
    VPN_INTERFACE="tun0"
elif [ "$VPN_TYPE" = "wireguard" ]; then
    VPN_INTERFACE="wg0"
fi

# Get WAN interface (the one with default route, excluding VPN)
WAN_INTERFACE=$(ip route | grep default | grep -v "$VPN_INTERFACE" | awk '{print $5}' | head -n1)

# Flush existing rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# Set default policies - DROP everything by default (KILL SWITCH)
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow all traffic on LAN interface (for management)
iptables -A INPUT -i "$LAN_INTERFACE" -j ACCEPT
iptables -A OUTPUT -o "$LAN_INTERFACE" -j ACCEPT

# Allow VPN connection establishment on WAN interface
# This allows the VPN client to connect to VPN server
if [ "$VPN_TYPE" = "openvpn" ]; then
    # Allow OpenVPN traffic (usually UDP 1194 or TCP 443, but allow all to VPN server)
    iptables -A OUTPUT -o "$WAN_INTERFACE" -p udp -j ACCEPT
    iptables -A OUTPUT -o "$WAN_INTERFACE" -p tcp -j ACCEPT
elif [ "$VPN_TYPE" = "wireguard" ]; then
    # Allow WireGuard traffic (UDP 51820 or provider's port)
    iptables -A OUTPUT -o "$WAN_INTERFACE" -p udp -j ACCEPT
fi

# Allow DNS for VPN connection (to resolve VPN server hostname)
iptables -A OUTPUT -o "$WAN_INTERFACE" -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -o "$WAN_INTERFACE" -p tcp --dport 53 -j ACCEPT

# CRITICAL: Only allow traffic through VPN interface
# If VPN is down, this interface won't exist and traffic will be blocked
if ip link show "$VPN_INTERFACE" > /dev/null 2>&1; then
    echo "VPN interface $VPN_INTERFACE is UP - allowing traffic"
    
    # Allow all output through VPN
    iptables -A OUTPUT -o "$VPN_INTERFACE" -j ACCEPT
    
    # Allow forwarding from LAN to VPN
    iptables -A FORWARD -i "$LAN_INTERFACE" -o "$VPN_INTERFACE" -j ACCEPT
    
    # NAT traffic from LAN through VPN
    iptables -t nat -A POSTROUTING -s "$LAN_SUBNET" -o "$VPN_INTERFACE" -j MASQUERADE

    # Clamp TCP MSS to the tunnel path MTU. Without this, 1500-byte client
    # packets are too large for the tunnel (wg0 ~1420) and dropped ICMP
    # frag-needed causes PMTUD black-holing: small packets pass, large
    # transfers stall, producing slow + intermittent failures. Clamping
    # client SYNs to the tunnel path MTU keeps every segment small enough.
    iptables -t mangle -A FORWARD -i "$LAN_INTERFACE" -o "$VPN_INTERFACE" \
        -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
else
    echo "WARNING: VPN interface $VPN_INTERFACE is DOWN - traffic will be blocked (kill switch active)"
fi

# Block all other forwarding (KILL SWITCH)
# This ensures if VPN drops, no traffic leaks through WAN
iptables -A FORWARD -o "$WAN_INTERFACE" -j DROP
iptables -A OUTPUT -o "$WAN_INTERFACE" ! -p udp ! -p tcp -j DROP

# Log dropped packets (optional, for debugging)
# iptables -A FORWARD -j LOG --log-prefix "VPN-FORWARD-DROP: " --log-level 4
# iptables -A OUTPUT -j LOG --log-prefix "VPN-OUTPUT-DROP: " --log-level 4

# Save rules
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
elif command -v iptables-save &> /dev/null; then
    iptables-save > /etc/iptables/rules.v4
fi

echo "VPN Gateway kill switch firewall rules applied successfully"
echo "Kill switch: Active - Traffic only allowed through $VPN_INTERFACE"
exit 0
