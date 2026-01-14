#!/bin/bash

# VPN Gateway Client Test Script
# Run this on a CLIENT machine to verify VPN connectivity and leak protection

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "======================================"
echo "VPN Gateway Client Test"
echo "======================================"
echo ""

# Check gateway connectivity
echo -e "${GREEN}1. Testing gateway connectivity...${NC}"
GATEWAY=$(ip route | grep default | awk '{print $3}')
if [ -z "$GATEWAY" ]; then
    echo -e "${RED}   Error: No default gateway configured${NC}"
    exit 1
fi

echo "   Gateway IP: $GATEWAY"

if ping -c 2 -W 2 "$GATEWAY" > /dev/null 2>&1; then
    echo -e "   ${GREEN}Gateway is reachable${NC}"
else
    echo -e "   ${RED}Cannot reach gateway${NC}"
    exit 1
fi

echo ""

# Check public IP
echo -e "${GREEN}2. Checking public IP address...${NC}"
echo "   This should be your VPN provider's IP, NOT your real IP"
echo ""

PUBLIC_IP=$(timeout 5 curl -s https://ifconfig.me 2>/dev/null)
if [ -n "$PUBLIC_IP" ]; then
    echo -e "   Your public IP: ${GREEN}$PUBLIC_IP${NC}"
    
    # Get IP info
    IP_INFO=$(timeout 5 curl -s "https://ipapi.co/$PUBLIC_IP/json" 2>/dev/null)
    if [ -n "$IP_INFO" ]; then
        echo "   Location: $(echo "$IP_INFO" | grep -oP '(?<="city":")[^"]*'), $(echo "$IP_INFO" | grep -oP '(?<="country_name":")[^"]*')"
        echo "   ISP: $(echo "$IP_INFO" | grep -oP '(?<="org":")[^"]*')"
    fi
else
    echo -e "   ${RED}Cannot determine public IP${NC}"
    echo "   This could mean:"
    echo "   - VPN is not connected"
    echo "   - Kill switch is blocking traffic"
fi

echo ""

# DNS leak test
echo -e "${GREEN}3. Testing for DNS leaks...${NC}"
echo "   DNS servers should belong to your VPN provider"
echo ""

DNS_SERVERS=$(cat /etc/resolv.conf | grep nameserver | awk '{print $2}')
echo "   Configured DNS servers:"
for DNS in $DNS_SERVERS; do
    echo "   - $DNS"
done

echo ""
echo "   Testing DNS resolution..."
if nslookup google.com > /dev/null 2>&1; then
    echo -e "   ${GREEN}DNS resolution working${NC}"
else
    echo -e "   ${RED}DNS resolution failed${NC}"
fi

echo ""

# WebRTC leak test warning
echo -e "${GREEN}4. WebRTC Leak Warning${NC}"
echo "   WebRTC can leak your real IP even with VPN!"
echo "   Test at: https://browserleaks.com/webrtc"
echo "   or:      https://ipleak.net/"
echo ""

# Connection test
echo -e "${GREEN}5. Testing internet connectivity...${NC}"

echo -n "   HTTP test (example.com): "
if timeout 5 curl -s -o /dev/null -w "%{http_code}" http://example.com | grep -q "200"; then
    echo -e "${GREEN}Success${NC}"
else
    echo -e "${RED}Failed${NC}"
fi

echo -n "   HTTPS test (google.com): "
if timeout 5 curl -s -o /dev/null https://google.com 2>&1 | grep -q "HTTP"; then
    echo -e "${GREEN}Success${NC}"
else
    echo -e "${RED}Failed${NC}"
fi

echo ""

# Kill switch test
echo -e "${GREEN}6. Kill Switch Information${NC}"
echo "   The VPN gateway has a kill switch enabled."
echo "   If the VPN disconnects:"
echo "   - All internet access will be blocked"
echo "   - No traffic will leak through your real IP"
echo "   - You'll need to reconnect the VPN"
echo ""

echo "======================================"
echo "Test Summary"
echo "======================================"
echo ""

if [ -n "$PUBLIC_IP" ]; then
    echo -e "${GREEN}VPN appears to be working${NC}"
    echo "  Your traffic is routed through: $PUBLIC_IP"
    echo ""
    echo -e "${YELLOW}VERIFY THIS IS YOUR VPN PROVIDER'S IP!${NC}"
    echo "  Compare with your provider's server list"
else
    echo -e "${RED}VPN connection issue detected${NC}"
    echo "  No public IP could be determined"
    echo "  Kill switch may be blocking traffic"
fi

echo ""
echo "Additional tests recommended:"
echo "  - https://ipleak.net/ (comprehensive leak test)"
echo "  - https://dnsleaktest.com/ (DNS leak test)"
echo "  - https://browserleaks.com/ip (browser-based test)"
