#!/bin/bash

# VPN Gateway Status Script

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "======================================"
echo "VPN Gateway Status"
echo "======================================"
echo ""

if [ ! -f /etc/vpn-gateway.conf ]; then
    echo -e "${RED}Error: Gateway not configured. Run install.sh first.${NC}"
    exit 1
fi

source /etc/vpn-gateway.conf

# Determine VPN interface
if [ "$VPN_TYPE" = "openvpn" ]; then
    VPN_INTERFACE="tun0"
elif [ "$VPN_TYPE" = "wireguard" ]; then
    VPN_INTERFACE="wg0"
fi

echo -e "${GREEN}Configuration:${NC}"
echo "  VPN Type: $VPN_TYPE"
echo "  LAN Interface: $LAN_INTERFACE"
echo "  LAN Subnet: $LAN_SUBNET"
echo "  Gateway IP: $GATEWAY_IP"
echo "  VPN Interface: $VPN_INTERFACE"
echo ""

# Check VPN service
echo -e "${GREEN}VPN Service:${NC}"
if systemctl is-active --quiet "$VPN_SERVICE"; then
    echo -e "  Status: ${GREEN}Running${NC}"
    
    # Get service uptime
    UPTIME=$(systemctl show "$VPN_SERVICE" --property=ActiveEnterTimestamp --value)
    echo "  Started: $UPTIME"
else
    echo -e "  Status: ${RED}Stopped${NC}"
fi

# Check VPN interface
echo -e "${GREEN}VPN Interface:${NC}"
if ip link show "$VPN_INTERFACE" > /dev/null 2>&1; then
    echo -e "  Status: ${GREEN}UP${NC}"
    
    # Get IP address
    VPN_IP=$(ip -4 addr show "$VPN_INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    if [ -n "$VPN_IP" ]; then
        echo "  IP Address: $VPN_IP"
    fi
    
    # Get public IP through VPN
    echo -n "  Public IP: "
    PUBLIC_IP=$(timeout 5 curl -s --interface "$VPN_INTERFACE" https://ifconfig.me 2>/dev/null)
    if [ -n "$PUBLIC_IP" ]; then
        echo -e "${GREEN}$PUBLIC_IP${NC}"
    else
        echo -e "${YELLOW}Could not determine${NC}"
    fi
else
    echo -e "  Status: ${RED}DOWN${NC}"
    echo -e "  ${RED}KILL SWITCH ACTIVE - No traffic will pass!${NC}"
fi

echo ""

# Check kill switch firewall
echo -e "${GREEN}Kill Switch Firewall:${NC}"
if systemctl is-active --quiet vpn-gateway-firewall; then
    echo -e "  Status: ${GREEN}Active${NC}"
else
    echo -e "  Status: ${RED}Inactive${NC}"
fi

# Check firewall rules
FORWARD_RULES=$(iptables -L FORWARD -n | grep -c "$VPN_INTERFACE" || echo "0")
if [ "$FORWARD_RULES" -gt 0 ]; then
    echo -e "  Rules: ${GREEN}$FORWARD_RULES rules for $VPN_INTERFACE${NC}"
else
    echo -e "  Rules: ${RED}No rules found for $VPN_INTERFACE${NC}"
fi

# Check default policy
FORWARD_POLICY=$(iptables -L FORWARD | grep "Chain FORWARD" | grep -oP '\(policy \K\w+')
if [ "$FORWARD_POLICY" = "DROP" ]; then
    echo -e "  Default Policy: ${GREEN}DROP (Kill switch active)${NC}"
else
    echo -e "  Default Policy: ${YELLOW}$FORWARD_POLICY${NC}"
fi

echo ""

# Check monitor service
echo -e "${GREEN}VPN Monitor:${NC}"
if systemctl is-active --quiet vpn-monitor; then
    echo -e "  Status: ${GREEN}Running${NC}"
else
    echo -e "  Status: ${YELLOW}Not running${NC}"
fi

# Check IP forwarding
echo -e "${GREEN}IP Forwarding:${NC}"
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
    echo -e "  Status: ${GREEN}Enabled${NC}"
else
    echo -e "  Status: ${RED}Disabled${NC}"
fi

echo ""

# VPN connectivity test
echo -e "${GREEN}VPN Connectivity:${NC}"
if ip link show "$VPN_INTERFACE" > /dev/null 2>&1; then
    echo -n "  Ping test (1.1.1.1): "
    if ping -c 1 -W 2 -I "$VPN_INTERFACE" 1.1.1.1 > /dev/null 2>&1; then
        echo -e "${GREEN}Success${NC}"
    else
        echo -e "${RED}Failed${NC}"
    fi
    
    echo -n "  DNS test: "
    if nslookup google.com > /dev/null 2>&1; then
        echo -e "${GREEN}Success${NC}"
    else
        echo -e "${RED}Failed${NC}"
    fi
else
    echo -e "  ${RED}VPN interface down - cannot test${NC}"
fi

echo ""

# Show recent monitor log
if [ -f /var/log/vpn-gateway-monitor.log ]; then
    echo -e "${GREEN}Recent Monitor Log:${NC}"
    tail -n 5 /var/log/vpn-gateway-monitor.log
    echo ""
fi

echo "======================================"
if ip link show "$VPN_INTERFACE" > /dev/null 2>&1; then
    echo -e "${GREEN}VPN is connected and operational${NC}"
else
    echo -e "${RED}VPN is disconnected - kill switch is blocking all traffic${NC}"
fi
echo "======================================"
