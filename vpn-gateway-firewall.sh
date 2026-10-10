#!/bin/bash
#
# Kill switch firewall for the VPN gateway.
#
# Everything is dropped by default. Devices on the LAN can only get out
# through the VPN tunnel. There's no rule letting them out the WAN, so if the
# tunnel goes down their traffic is dropped instead of leaking out your real
# connection.
#
# None of the rules depend on the tunnel being up, so this runs once at boot
# before the network starts. IP forwarding is only switched on after the
# rules are in place.

set -eu

CONF=/etc/vpn-gateway.conf
if [ ! -f "$CONF" ]; then
    echo "Error: $CONF not found, run install.sh first" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$CONF"

WAN=$WAN_INTERFACE
LAN=$LAN_INTERFACE
VPN=$VPN_INTERFACE

# Ports the gateway uses to reach the VPN server
vpn_server_ports() {
    case $VPN_TYPE in
        wireguard)
            awk -F= 'tolower($1) ~ /^[ \t]*endpoint[ \t]*$/ {
                gsub(/[ \t]/, "", $2); n = split($2, a, ":"); print a[n]
            }' "$VPN_CONFIG"
            ;;
        openvpn)
            awk '
                $1 == "port" || $1 == "rport" { port = $2 }
                $1 == "remote" { if ($3 ~ /^[0-9]+$/) print $3; else bare = 1 }
                END { if (bare) print (port ? port : 1194); else if (port) print port }
            ' "$VPN_CONFIG"
            ;;
    esac | grep -E '^[0-9]+$' | sort -un
}

# Rules shared by IPv4 and IPv6. $1 is iptables or ip6tables.
common_rules() {
    local ipt=$1 port

    # Policies go to DROP before the old rules are flushed so nothing gets
    # through in between. Only the chains this script owns are flushed, so
    # the rules wg-quick adds to the mangle and raw tables survive a re-run.
    $ipt -P INPUT DROP
    $ipt -P FORWARD DROP
    $ipt -P OUTPUT DROP
    $ipt -F INPUT
    $ipt -F FORWARD
    $ipt -F OUTPUT

    $ipt -A INPUT -i lo -j ACCEPT
    $ipt -A OUTPUT -o lo -j ACCEPT
    $ipt -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    $ipt -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    $ipt -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # The gateway itself is open to the LAN (DHCP, DNS, SSH, ping)
    $ipt -A INPUT -i "$LAN" -j ACCEPT
    $ipt -A OUTPUT -o "$LAN" -j ACCEPT

    # SSH on the WAN too, so it can be managed from the existing network
    for port in $SSH_PORTS; do
        $ipt -A INPUT -i "$WAN" -p tcp --dport "$port" -j ACCEPT
    done

    # dnsmasq answers DNS for the LAN. Its lookups route through the tunnel,
    # and if the tunnel is down this stops them going out the WAN instead.
    $ipt -A OUTPUT -o "$WAN" -m owner --uid-owner dnsmasq -j DROP

    # What the gateway itself needs on the WAN to get the tunnel up: DNS to
    # look up the VPN server, the time, and the VPN server.
    $ipt -A OUTPUT -o "$WAN" -p udp --dport 53 -j ACCEPT
    $ipt -A OUTPUT -o "$WAN" -p tcp --dport 53 -j ACCEPT
    $ipt -A OUTPUT -o "$WAN" -p udp --dport 123 -j ACCEPT
    if [ -n "$VPN_PORTS" ]; then
        for port in $VPN_PORTS; do
            $ipt -A OUTPUT -o "$WAN" -p udp --dport "$port" -j ACCEPT
            if [ "$VPN_TYPE" = openvpn ]; then
                $ipt -A OUTPUT -o "$WAN" -p tcp --dport "$port" -j ACCEPT
            fi
        done
    else
        $ipt -A OUTPUT -o "$WAN" -p udp -j ACCEPT
        $ipt -A OUTPUT -o "$WAN" -p tcp -j ACCEPT
    fi

    # Anything the gateway sends through the tunnel is fine
    $ipt -A OUTPUT -o "$VPN" -j ACCEPT
}

VPN_PORTS=$(vpn_server_ports | xargs)
if [ -z "$VPN_PORTS" ]; then
    echo "Warning: couldn't find the VPN server port in $VPN_CONFIG, allowing all TCP and UDP out $WAN" >&2
fi

# IPv4
common_rules iptables
iptables -A INPUT -i "$WAN" -p icmp --icmp-type echo-request -j ACCEPT
iptables -A OUTPUT -o "$WAN" -p udp --dport 67 -j ACCEPT

# LAN devices can only go out through the tunnel
iptables -A FORWARD -i "$LAN" -o "$VPN" -j ACCEPT
iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -s "$LAN_SUBNET" -o "$VPN" -j MASQUERADE

# Clamp TCP MSS to the tunnel's path MTU. Devices on the LAN send 1500 byte
# packets, which are too big for the tunnel (wg0 is around 1420). If the ICMP
# "fragmentation needed" replies get dropped along the way, path MTU discovery
# breaks: small requests work but bigger transfers stall. Clamping the MSS on
# outgoing SYNs makes every connection use segments that fit.
iptables -t mangle -F FORWARD
iptables -t mangle -A FORWARD -i "$LAN" -o "$VPN" -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --clamp-mss-to-pmtu

# Replies to connections that came in on the WAN, like SSH, have to go back
# out the WAN instead of into the tunnel. Those connections get marked with
# 51820 (0xca6c), the same mark WireGuard puts on its own packets so they skip
# the tunnel (install.sh pins it with FwMark in wg0.conf). Marked packets also
# use routing table 200, which the monitor fills with the WAN's routes. That
# covers OpenVPN, which has no rule of its own for the mark.
for chain in PREROUTING OUTPUT; do
    iptables -t mangle -N "vpngw-$chain" 2>/dev/null || iptables -t mangle -F "vpngw-$chain"
    iptables -t mangle -C "$chain" -j "vpngw-$chain" 2>/dev/null || iptables -t mangle -I "$chain" -j "vpngw-$chain"
done
iptables -t mangle -A vpngw-PREROUTING -i "$WAN" -m conntrack --ctstate NEW -j CONNMARK --set-mark 0xca6c
iptables -t mangle -A vpngw-OUTPUT -m connmark --mark 0xca6c -j MARK --set-mark 0xca6c
if ! ip -4 rule show | grep -q 'fwmark 0xca6c lookup 200'; then
    ip -4 rule add pref 100 fwmark 0xca6c lookup 200
fi

# IPv6. The LAN is IPv4 only and nothing gets forwarded, so devices can't
# sneak around the tunnel over IPv6. The gateway keeps IPv6 on the WAN for SSH.
if [ -d /proc/sys/net/ipv6 ]; then
    common_rules ip6tables
    ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
    ip6tables -A OUTPUT -p ipv6-icmp -j ACCEPT
    ip6tables -A INPUT -i "$WAN" -p udp --dport 546 -j ACCEPT
    ip6tables -A OUTPUT -o "$WAN" -p udp --dport 547 -j ACCEPT
fi

# Loose reverse path filtering. Strict mode drops replies that come back on
# a different adapter to the one the routing table would pick, which breaks
# SSH on the WAN while the tunnel holds the default route.
echo 2 > /proc/sys/net/ipv4/conf/all/rp_filter
echo 1 > /proc/sys/net/ipv4/ip_forward

echo "Kill switch on: LAN traffic can only leave through $VPN"
