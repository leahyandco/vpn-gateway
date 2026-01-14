#!/bin/bash

# VPN Gateway Monitor
# Monitors VPN connection and triggers firewall updates
# Reconnects VPN if it fails

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

LOG_FILE="/var/log/vpn-gateway-monitor.log"

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

check_vpn_interface() {
    if ip link show "$VPN_INTERFACE" > /dev/null 2>&1; then
        if ip addr show "$VPN_INTERFACE" | grep -q "inet "; then
            return 0  # VPN is up and has an IP
        fi
    fi
    return 1  # VPN is down
}

check_vpn_connectivity() {
    # Try to ping through VPN interface
    if ping -c 1 -W 2 -I "$VPN_INTERFACE" 1.1.1.1 > /dev/null 2>&1; then
        return 0  # VPN has connectivity
    fi
    return 1  # VPN has no connectivity
}

check_vpn_service() {
    if systemctl is-active --quiet "$VPN_SERVICE"; then
        return 0  # Service is running
    fi
    return 1  # Service is not running
}

restart_vpn() {
    log_message "Restarting VPN service: $VPN_SERVICE"
    systemctl restart "$VPN_SERVICE"
    sleep 5
    
    # Update firewall after restart
    /usr/local/bin/vpn-gateway-firewall
}

# Main monitoring loop
log_message "VPN Gateway Monitor started"
log_message "Monitoring VPN type: $VPN_TYPE, Interface: $VPN_INTERFACE"

FAILURE_COUNT=0
MAX_FAILURES=3

while true; do
    # Check if VPN service is running
    if ! check_vpn_service; then
        log_message "WARNING: VPN service $VPN_SERVICE is not running"
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        
        if [ $FAILURE_COUNT -ge $MAX_FAILURES ]; then
            restart_vpn
            FAILURE_COUNT=0
        fi
        
        sleep 10
        continue
    fi
    
    # Check if VPN interface exists and has IP
    if ! check_vpn_interface; then
        log_message "WARNING: VPN interface $VPN_INTERFACE is down or has no IP"
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        
        if [ $FAILURE_COUNT -ge $MAX_FAILURES ]; then
            restart_vpn
            FAILURE_COUNT=0
        fi
        
        sleep 10
        continue
    fi
    
    # Check if VPN has actual connectivity
    if ! check_vpn_connectivity; then
        log_message "WARNING: VPN interface exists but has no connectivity"
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        
        if [ $FAILURE_COUNT -ge $MAX_FAILURES ]; then
            restart_vpn
            FAILURE_COUNT=0
        fi
        
        sleep 10
        continue
    fi
    
    # VPN is healthy
    if [ $FAILURE_COUNT -gt 0 ]; then
        log_message "VPN connection restored"
        FAILURE_COUNT=0
    fi
    
    # Check every 30 seconds
    sleep 30
done
