#!/bin/bash
#
# Keeps the VPN up. Checks the tunnel every 30 seconds and restarts the VPN
# service after a few failed checks in a row.
#
# It also keeps routing table 200 in sync with the WAN's routes. The firewall
# sends replies to connections that came in on the WAN, like SSH from your
# existing network, through that table. Without it, replies to anything
# outside the WAN's own subnet would go into the tunnel and the connection
# would hang.
#
#   vpn-gateway-monitor                 run the monitor
#   vpn-gateway-monitor --sync-routes   just update table 200

CONF=/etc/vpn-gateway.conf
if [ ! -f "$CONF" ]; then
    echo "Error: $CONF not found, run install.sh first" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$CONF"

CHECK_INTERVAL=30
RETRY_INTERVAL=10
MAX_FAILURES=3
PING_TARGETS="1.1.1.1 9.9.9.9"
WAN_TABLE=200

# Copy the WAN's routes from the main table into table 200
sync_wan_route() {
    local gw subnet
    gw=$(ip -4 route show table main default dev "$WAN_INTERFACE" 2>/dev/null | awk '{print $3; exit}')
    [ -n "$gw" ] || return 0
    for subnet in $(ip -4 route show table main dev "$WAN_INTERFACE" scope link | awk '{print $1}'); do
        ip route replace "$subnet" dev "$WAN_INTERFACE" table "$WAN_TABLE"
    done
    ip route replace default via "$gw" dev "$WAN_INTERFACE" table "$WAN_TABLE"
}

vpn_ok() {
    local target
    systemctl is-active --quiet "$VPN_SERVICE" || return 1
    ip -4 addr show dev "$VPN_INTERFACE" 2>/dev/null | grep -q 'inet ' || return 1
    for target in $PING_TARGETS; do
        ping -c 1 -W 3 -I "$VPN_INTERFACE" "$target" >/dev/null 2>&1 && return 0
    done
    return 1
}

if [ "${1:-}" = --sync-routes ]; then
    sync_wan_route
    exit 0
fi

echo "Watching $VPN_SERVICE on $VPN_INTERFACE"
failures=0

while true; do
    sync_wan_route

    if vpn_ok; then
        if [ "$failures" -gt 0 ]; then
            echo "VPN is working again"
        fi
        failures=0
        sleep "$CHECK_INTERVAL"
        continue
    fi

    failures=$((failures + 1))
    echo "VPN check failed ($failures of $MAX_FAILURES)"

    if [ "$failures" -ge "$MAX_FAILURES" ]; then
        echo "Restarting $VPN_SERVICE"
        systemctl restart "$VPN_SERVICE" || echo "Restart failed, will try again"
        failures=0
    fi

    sleep "$RETRY_INTERVAL"
done
