#!/bin/bash

# VPN Gateway Uninstallation Script

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: This script must be run as root${NC}"
    exit 1
fi

echo -e "${YELLOW}======================================${NC}"
echo -e "${YELLOW}VPN Gateway Uninstallation${NC}"
echo -e "${YELLOW}======================================${NC}"
echo ""
echo "This will:"
echo "  - Stop VPN and firewall services"
echo "  - Remove kill switch firewall rules"
echo "  - Disable IP forwarding"
echo "  - Remove configuration files"
echo "  - Optionally remove VPN software"
echo ""
read -p "Continue with uninstallation? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Uninstallation cancelled."
    exit 0
fi

# Load config if exists
if [ -f /etc/vpn-gateway.conf ]; then
    source /etc/vpn-gateway.conf
fi

# Stop services
echo -e "${GREEN}Stopping services...${NC}"
systemctl stop vpn-monitor || true
systemctl stop vpn-gateway-firewall || true

if [ -n "$VPN_SERVICE" ]; then
    systemctl stop "$VPN_SERVICE" || true
    systemctl disable "$VPN_SERVICE" || true
fi

# Disable services
echo -e "${GREEN}Disabling services...${NC}"
systemctl disable vpn-monitor || true
systemctl disable vpn-gateway-firewall || true

# Remove firewall rules
echo -e "${GREEN}Flushing firewall rules...${NC}"
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# Restore default policies
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Save empty iptables
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
fi

# Disable IP forwarding
echo -e "${GREEN}Disabling IP forwarding...${NC}"
rm -f /etc/sysctl.d/30-vpn-gateway.conf
sysctl -w net.ipv4.ip_forward=0

# Remove systemd services
echo -e "${GREEN}Removing systemd services...${NC}"
rm -f /etc/systemd/system/vpn-gateway-firewall.service
rm -f /etc/systemd/system/vpn-monitor.service
systemctl daemon-reload

# Remove scripts
rm -f /usr/local/bin/vpn-gateway-firewall
rm -f /usr/local/bin/vpn-monitor

# Remove configuration
echo -e "${GREEN}Removing configuration files...${NC}"
rm -f /etc/vpn-gateway.conf
rm -f /var/log/vpn-gateway-monitor.log

echo ""

if [ -n "$VPN_TYPE" ]; then
    read -p "Remove $VPN_TYPE software? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ "$VPN_TYPE" = "openvpn" ]; then
            echo -e "${GREEN}Removing OpenVPN...${NC}"
            apt-get remove -y openvpn openvpn-systemd-resolved
            
            read -p "Remove OpenVPN configuration files? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                rm -rf /etc/openvpn/client
            fi
        elif [ "$VPN_TYPE" = "wireguard" ]; then
            echo -e "${GREEN}Removing WireGuard...${NC}"
            apt-get remove -y wireguard wireguard-tools
            
            read -p "Remove WireGuard configuration files? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                rm -rf /etc/wireguard
            fi
        fi
        
        apt-get autoremove -y
    fi
fi

echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}Uninstallation Complete!${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo "VPN Gateway has been removed."
echo "You may need to reboot client machines to restore normal network operation."
