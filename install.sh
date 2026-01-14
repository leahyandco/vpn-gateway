#!/bin/bash

# VPN Transparent Gateway Installation Script
# For Ubuntu/Debian systems
# Supports OpenVPN and WireGuard

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: This script must be run as root${NC}"
    exit 1
fi

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}VPN Transparent Gateway Installation${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""

# Choose VPN type
echo -e "${YELLOW}Select VPN type:${NC}"
echo "  1) OpenVPN"
echo "  2) WireGuard"
read -p "Enter choice [1-2]: " VPN_TYPE_CHOICE

case $VPN_TYPE_CHOICE in
    1)
        VPN_TYPE="openvpn"
        ;;
    2)
        VPN_TYPE="wireguard"
        ;;
    *)
        echo -e "${RED}Invalid choice${NC}"
        exit 1
        ;;
esac

echo ""
echo -e "${BLUE}Selected VPN type: $VPN_TYPE${NC}"
echo ""

# Prompt for LAN interface
echo -e "${YELLOW}Enter the LAN interface name (e.g., eth1, ens19):${NC}"
read -p "LAN Interface: " LAN_INTERFACE

if [ -z "$LAN_INTERFACE" ]; then
    echo -e "${RED}Error: LAN interface cannot be empty${NC}"
    exit 1
fi

if ! ip link show "$LAN_INTERFACE" > /dev/null 2>&1; then
    echo -e "${RED}Error: Interface $LAN_INTERFACE does not exist${NC}"
    exit 1
fi

# Prompt for LAN subnet
echo -e "${YELLOW}Enter the LAN subnet (e.g., 192.168.100.0/24):${NC}"
read -p "LAN Subnet: " LAN_SUBNET

if [ -z "$LAN_SUBNET" ]; then
    echo -e "${RED}Error: LAN subnet cannot be empty${NC}"
    exit 1
fi

# Get gateway IP
GATEWAY_IP=$(ip -4 addr show "$LAN_INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

if [ -z "$GATEWAY_IP" ]; then
    echo -e "${RED}Error: Could not determine IP address of $LAN_INTERFACE${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}Configuration Summary:${NC}"
echo "  VPN Type: $VPN_TYPE"
echo "  LAN Interface: $LAN_INTERFACE"
echo "  LAN Subnet: $LAN_SUBNET"
echo "  Gateway IP: $GATEWAY_IP"
echo ""
read -p "Continue with installation? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

# Update packages
echo -e "${GREEN}Updating package lists...${NC}"
apt-get update

# Install VPN software
if [ "$VPN_TYPE" = "openvpn" ]; then
    echo -e "${GREEN}Installing OpenVPN...${NC}"
    apt-get install -y openvpn openvpn-systemd-resolved iptables iptables-persistent
    
    # Create config directory
    mkdir -p /etc/openvpn/client
    
    echo ""
    echo -e "${YELLOW}Place your OpenVPN configuration file at:${NC}"
    echo "  /etc/openvpn/client/vpn.conf"
    echo ""
    echo "Your config should include:"
    echo "  - auth-user-pass /etc/openvpn/client/auth.txt (if needed)"
    echo "  - script-security 2"
    echo "  - up /etc/openvpn/update-resolv-conf"
    echo "  - down /etc/openvpn/update-resolv-conf"
    echo ""
    
    VPN_SERVICE="openvpn-client@vpn"
    
elif [ "$VPN_TYPE" = "wireguard" ]; then
    echo -e "${GREEN}Installing WireGuard...${NC}"
    apt-get install -y wireguard wireguard-tools iptables iptables-persistent
    
    echo ""
    echo -e "${YELLOW}Place your WireGuard configuration file at:${NC}"
    echo "  /etc/wireguard/wg0.conf"
    echo ""
    echo "Your config should include:"
    echo "  - [Interface] section with PrivateKey"
    echo "  - [Peer] section with endpoint and PublicKey"
    echo "  - Do NOT include PostUp/PostDown rules (we handle routing)"
    echo ""
    
    VPN_SERVICE="wg-quick@wg0"
fi

# Enable IP forwarding
echo -e "${GREEN}Enabling IP forwarding...${NC}"
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/30-vpn-gateway.conf
echo "net.ipv4.conf.all.rp_filter=0" >> /etc/sysctl.d/30-vpn-gateway.conf
echo "net.ipv4.conf.default.rp_filter=0" >> /etc/sysctl.d/30-vpn-gateway.conf
sysctl -p /etc/sysctl.d/30-vpn-gateway.conf

# Save gateway configuration
echo -e "${GREEN}Saving gateway configuration...${NC}"
cat > /etc/vpn-gateway.conf << CONFEOF
VPN_TYPE=$VPN_TYPE
LAN_INTERFACE=$LAN_INTERFACE
LAN_SUBNET=$LAN_SUBNET
GATEWAY_IP=$GATEWAY_IP
VPN_SERVICE=$VPN_SERVICE
CONFEOF

# Install scripts
echo -e "${GREEN}Installing gateway scripts...${NC}"
cp vpn-gateway-firewall.sh /usr/local/bin/vpn-gateway-firewall
chmod +x /usr/local/bin/vpn-gateway-firewall

cp vpn-monitor.sh /usr/local/bin/vpn-monitor
chmod +x /usr/local/bin/vpn-monitor

# Install systemd services
cp vpn-gateway-firewall.service /etc/systemd/system/
cp vpn-monitor.service /etc/systemd/system/
systemctl daemon-reload

echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo -e "${YELLOW}IMPORTANT: Next steps:${NC}"
echo ""

if [ "$VPN_TYPE" = "openvpn" ]; then
    echo "1. Place your OpenVPN config at: /etc/openvpn/client/vpn.conf"
    echo "2. If authentication required, create: /etc/openvpn/client/auth.txt"
    echo "   Format:"
    echo "     username"
    echo "     password"
    echo "   Then: chmod 600 /etc/openvpn/client/auth.txt"
    echo ""
    echo "3. Start the VPN and gateway:"
    echo "   sudo systemctl start $VPN_SERVICE"
    echo "   sudo systemctl enable $VPN_SERVICE"
else
    echo "1. Place your WireGuard config at: /etc/wireguard/wg0.conf"
    echo "   Then: chmod 600 /etc/wireguard/wg0.conf"
    echo ""
    echo "2. Start the VPN and gateway:"
    echo "   sudo systemctl start $VPN_SERVICE"
    echo "   sudo systemctl enable $VPN_SERVICE"
fi

echo ""
echo "4. Enable the kill switch firewall:"
echo "   sudo systemctl enable vpn-gateway-firewall"
echo "   sudo systemctl start vpn-gateway-firewall"
echo ""
echo "5. Enable VPN monitoring (auto-reconnect):"
echo "   sudo systemctl enable vpn-monitor"
echo "   sudo systemctl start vpn-monitor"
echo ""
echo "6. Check status:"
echo "   sudo ./status.sh"
echo ""
echo -e "${RED}KILL SWITCH ACTIVE: No traffic will pass until VPN is connected!${NC}"
