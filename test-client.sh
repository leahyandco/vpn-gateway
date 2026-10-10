#!/bin/bash
#
# Run this on a Linux device plugged into the gateway's LAN to check that its
# traffic is going through the VPN.

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

FAILED=0
pass() { echo -e "  ${GREEN}PASS${NC}  $*"; }
fail() { echo -e "  ${RED}FAIL${NC}  $*"; FAILED=1; }
note() { echo "        $*"; }

json_field() {
    sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" <<< "$2" | head -n1
}

echo "Gateway"
gw=$(ip -4 route show default | awk '{print $3; exit}')
if [ -z "$gw" ]; then
    fail "No default gateway. Is this device getting an address from the gateway?"
    exit 1
fi
if ping -c 2 -W 2 "$gw" >/dev/null 2>&1; then
    pass "Gateway $gw is reachable"
else
    fail "Can't reach the gateway at $gw"
fi

echo
echo "DNS"
dns=
if command -v resolvectl >/dev/null 2>&1; then
    dns=$(resolvectl dns 2>/dev/null | awk -F': ' 'NF > 1 {print $2}' | xargs)
fi
if [ -z "$dns" ]; then
    dns=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | xargs)
fi
note "DNS servers: ${dns:-none found}"
if [[ " $dns " == *" $gw "* ]]; then
    pass "Using the gateway for DNS"
else
    fail "Not using the gateway ($gw) for DNS, lookups may go to your ISP"
fi
if getent hosts example.com >/dev/null; then
    pass "DNS lookups work"
else
    fail "DNS lookups don't work"
fi

echo
echo "Internet"
info=$(curl -s --max-time 10 https://ipinfo.io/json)
public_ip=$(json_field ip "$info")
if [ -n "$public_ip" ]; then
    pass "Public IP is $public_ip"
    note "Location: $(json_field city "$info"), $(json_field country "$info")"
    note "Network:  $(json_field org "$info")"
    note "That should be your VPN provider, not your ISP."
else
    fail "Couldn't reach the internet"
fi
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://example.com)
if [ "$code" = 200 ]; then
    pass "HTTPS works"
else
    fail "HTTPS request failed (${code:-no response})"
fi
if curl -6 -s -o /dev/null --max-time 5 https://ifconfig.co 2>/dev/null; then
    fail "IPv6 traffic gets out, which goes around the VPN"
else
    pass "No IPv6 route out, as expected"
fi

echo
echo "Worth checking in a browser too, since browsers can leak your real IP"
echo "through WebRTC no matter what the network does:"
echo "  https://ipleak.net"
echo "  https://dnsleaktest.com"
echo

if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}All checks passed.${NC}"
else
    echo -e "${RED}Some checks failed.${NC} Run sudo vpn-gateway-status on the gateway."
    exit 1
fi
