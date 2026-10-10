#!/bin/bash
#
# Sets up a Debian or Ubuntu box as a VPN gateway.
#
#   sudo ./install.sh /path/to/vpn-config
#
# The config can be a WireGuard .conf or an OpenVPN .ovpn file from your VPN
# provider. Re-run it any time to change settings. Leave the path off to keep
# the VPN config that's already installed.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONF=/etc/vpn-gateway.conf
DEFAULT_DNS="1.1.1.1 9.9.9.9"
WG_CONFIG=/etc/wireguard/wg0.conf
OVPN_CONFIG=/etc/openvpn/client/vpn.conf
OVPN_AUTH=/etc/openvpn/client/vpn-auth.txt
DNSMASQ_CONFIG=/etc/dnsmasq.d/vpn-gateway.conf

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}Warning:${NC} $*" >&2; }
die() { echo -e "${RED}Error:${NC} $*" >&2; exit 1; }

# ask "Question" [default]
ask() {
    local reply=
    if [ -n "${2:-}" ]; then
        read -r -p "$1 [$2]: " reply || true
    else
        read -r -p "$1: " reply || true
    fi
    echo "${reply:-${2:-}}"
}

# yes_no "Question" [y|n]
yes_no() {
    local reply
    reply=$(ask "$1 (y/n)" "${2:-y}")
    [[ $reply =~ ^[Yy] ]]
}

ip_to_int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
}

int_to_ip() {
    echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"
}

prefix_to_mask() {
    echo $(( (0xFFFFFFFF << (32 - $1)) & 0xFFFFFFFF ))
}

is_ipv4() {
    local octet
    [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    for octet in ${1//./ }; do
        [ $(( 10#$octet )) -le 255 ] || return 1
    done
}

# First global IPv4 address on an adapter, as address/prefix
iface_cidr() {
    ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4; exit}'
}

detect_vpn_type() {
    if grep -qiE '^[[:space:]]*\[Interface\]' "$1" && grep -qiE '^[[:space:]]*\[Peer\]' "$1"; then
        echo wireguard
    elif grep -qE '^[[:space:]]*(client|remote)([[:space:]]|$)' "$1"; then
        echo openvpn
    fi
}

# IPv4 DNS servers from the DNS line of a WireGuard config
wireguard_dns() {
    tr -d '\r' < "$1" \
        | awk -F= 'tolower($1) ~ /^[ \t]*dns[ \t]*$/ {print $2}' \
        | tr -s ', \t' '\n' \
        | grep -E '^[0-9]+(\.[0-9]+){3}$' \
        | tr '\n' ' ' | sed 's/ *$//'
}

install_wireguard_config() {
    local tmp
    install -d -m 700 /etc/wireguard
    tmp=$(mktemp /etc/wireguard/.wg0.XXXXXX)
    tr -d '\r' < "$1" > "$tmp"

    # dnsmasq does DNS for the LAN and the firewall does the routing, so the
    # provider's DNS line and any hook scripts get switched off. wg-quick would
    # otherwise pass the DNS servers to resolvconf, which isn't always
    # installed, and point the gateway's own lookups into the tunnel.
    sed -i -E 's/^([[:space:]]*(DNS|PostUp|PostDown|PreUp|PreDown|FwMark)[[:space:]]*=.*)$/# Disabled by vpn-gateway: \1/I' "$tmp"

    # Pin the mark WireGuard uses to keep its own packets out of the tunnel.
    # The firewall uses the same mark to send SSH replies back out the WAN.
    sed -i -E '0,/^[[:space:]]*\[Interface\]/I{s/^([[:space:]]*\[Interface\].*)$/\1\nFwMark = 51820/I}' "$tmp"

    if ! grep -qiE '^[[:space:]]*AllowedIPs[[:space:]]*=.*0\.0\.0\.0/0' "$tmp"; then
        warn "AllowedIPs in your config doesn't include 0.0.0.0/0, so LAN traffic won't route through the tunnel"
    fi

    chmod 600 "$tmp"
    mv "$tmp" "$WG_CONFIG"
}

install_openvpn_config() {
    local tmp user pass
    install -d -m 755 /etc/openvpn/client
    tmp=$(mktemp /etc/openvpn/client/.vpn.XXXXXX)
    tr -d '\r' < "$1" > "$tmp"

    if grep -qE '^[[:space:]]*dev[[:space:]]+tap' "$tmp"; then
        rm -f "$tmp"
        die "TAP (dev tap) OpenVPN configs aren't supported, only TUN"
    fi
    # Always call the tunnel tun0 so the firewall rules match it
    sed -i -E 's/^[[:space:]]*dev[[:space:]]+tun[0-9]*[[:space:]]*$/dev tun0/' "$tmp"

    # Send everything through the tunnel even if the provider doesn't push a
    # route for it. def1 leaves the WAN default route alone, which the gateway
    # still needs to reach the VPN server.
    if grep -qE '^[[:space:]]*redirect-gateway' "$tmp"; then
        sed -i -E '/^[[:space:]]*redirect-gateway/{/def1/!s/$/ def1/}' "$tmp"
    else
        echo 'redirect-gateway def1' >> "$tmp"
    fi

    # Scripts that rewrite resolv.conf aren't wanted. dnsmasq handles DNS for
    # the LAN, and the gateway needs to keep using the WAN's DNS to look up
    # the VPN server when it reconnects.
    sed -i -E 's/^([[:space:]]*(up|down)[[:space:]]+.*resolv.*)$/# Disabled by vpn-gateway: \1/' "$tmp"

    if grep -qE '^[[:space:]]*auth-user-pass' "$tmp"; then
        if [ -s "$OVPN_AUTH" ] && yes_no "Keep the saved VPN username and password?" y; then
            :
        else
            user=$(ask "VPN username")
            read -r -s -p "VPN password: " pass
            echo
            if [ -z "$user" ] || [ -z "$pass" ]; then
                rm -f "$tmp"
                die "The username and password can't be empty"
            fi
            (umask 077; printf '%s\n%s\n' "$user" "$pass" > "$OVPN_AUTH")
        fi
        sed -i -E "s|^[[:space:]]*auth-user-pass.*$|auth-user-pass $OVPN_AUTH|" "$tmp"
    fi

    chmod 600 "$tmp"
    mv "$tmp" "$OVPN_CONFIG"
}

write_dnsmasq_config() {
    local servers='' s
    for s in $UPSTREAM_DNS; do
        servers+="server=$s"$'\n'
    done
    install -d /etc/dnsmasq.d
    cat > "$DNSMASQ_CONFIG" <<EOF
# Written by vpn-gateway's install.sh. Re-run the installer to change it.

# Only serve the LAN
interface=$LAN_INTERFACE
except-interface=lo
bind-dynamic

# DNS. Lookups go out through the VPN tunnel, and the firewall drops them if
# the tunnel is down rather than letting them out the WAN.
no-resolv
domain-needed
bogus-priv
cache-size=1000
$servers
# Local names, so devices can find each other as name.lan
domain=lan
local=/lan/
expand-hosts

# DHCP
dhcp-authoritative
dhcp-range=$DHCP_START,$DHCP_END,$LAN_NETMASK,12h
dhcp-option=option:router,$LAN_ADDRESS
dhcp-option=option:dns-server,$LAN_ADDRESS
EOF
}

install_files() {
    local unit
    install -m 755 "$SCRIPT_DIR/vpn-gateway-firewall.sh" /usr/local/bin/vpn-gateway-firewall
    install -m 755 "$SCRIPT_DIR/vpn-gateway-monitor.sh" /usr/local/bin/vpn-gateway-monitor
    install -m 755 "$SCRIPT_DIR/status.sh" /usr/local/bin/vpn-gateway-status
    install -m 644 "$SCRIPT_DIR/vpn-gateway-firewall.service" /etc/systemd/system/
    install -m 644 "$SCRIPT_DIR/vpn-gateway-monitor.service" /etc/systemd/system/

    # The VPN and dnsmasq never run without the kill switch in place
    for unit in "$VPN_SERVICE" dnsmasq; do
        install -d "/etc/systemd/system/$unit.service.d"
        cat > "/etc/systemd/system/$unit.service.d/vpn-gateway.conf" <<EOF
[Unit]
Requires=vpn-gateway-firewall.service
After=vpn-gateway-firewall.service
EOF
    done

    # Stop dnsmasq registering itself as this box's own resolver if resolvconf
    # is installed. The gateway has to resolve the VPN server over the WAN.
    cat >> /etc/systemd/system/dnsmasq.service.d/vpn-gateway.conf <<EOF

[Service]
Environment=DNSMASQ_EXCEPT=lo
EOF

    systemctl daemon-reload
}

# Clean up after the older version of this project
remove_old_version() {
    if [ -f /etc/systemd/system/vpn-monitor.service ]; then
        systemctl disable -q --now vpn-monitor 2>/dev/null || true
        rm -f /etc/systemd/system/vpn-monitor.service /usr/local/bin/vpn-monitor
    fi
    rm -f /etc/sysctl.d/30-vpn-gateway.conf /var/log/vpn-gateway-monitor.log
}

# ---------------------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "Run this as root, e.g. sudo ./install.sh your-vpn.conf"
command -v apt-get >/dev/null || die "This only supports Debian and Ubuntu"

echo
echo "VPN gateway installer"
echo

# Settings from a previous install become the defaults
if [ -f "$CONF" ]; then
    # shellcheck source=/dev/null
    . "$CONF"
fi
PREV_VPN_SERVICE=${VPN_SERVICE:-}

# VPN config
VPN_SOURCE=${1:-}
if [ -z "$VPN_SOURCE" ] && [ -n "${VPN_CONFIG:-}" ] && [ -f "$VPN_CONFIG" ]; then
    info "Keeping the current VPN config ($VPN_CONFIG)"
else
    [ -n "$VPN_SOURCE" ] || VPN_SOURCE=$(ask "Path to your WireGuard or OpenVPN config file")
    [ -f "$VPN_SOURCE" ] || die "Can't find $VPN_SOURCE"
    VPN_TYPE=$(detect_vpn_type "$VPN_SOURCE")
    [ -n "$VPN_TYPE" ] || die "$VPN_SOURCE doesn't look like a WireGuard or OpenVPN config"
    info "Found a $VPN_TYPE config"
fi

case $VPN_TYPE in
    wireguard)
        VPN_INTERFACE=wg0
        VPN_SERVICE=wg-quick@wg0
        VPN_CONFIG=$WG_CONFIG
        ;;
    openvpn)
        VPN_INTERFACE=tun0
        VPN_SERVICE=openvpn-client@vpn
        VPN_CONFIG=$OVPN_CONFIG
        ;;
esac

# Adapters
echo
info "Network adapters on this box:"
for path in /sys/class/net/*; do
    ifc=${path##*/}
    [ "$ifc" = lo ] && continue
    printf '    %-16s %s\n' "$ifc" "$(iface_cidr "$ifc")"
done
echo

default_wan=$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1)}' \
    | grep -vE '^(wg|tun)' | head -n1)
WAN_INTERFACE=$(ask "WAN adapter (plugged into your existing network)" "${WAN_INTERFACE:-$default_wan}")
[ -n "$WAN_INTERFACE" ] || die "No WAN adapter given"
[ -d "/sys/class/net/$WAN_INTERFACE" ] || die "There's no adapter called $WAN_INTERFACE"

default_lan=
if [ -n "${LAN_INTERFACE:-}" ] && [ -d "/sys/class/net/$LAN_INTERFACE" ]; then
    default_lan=$LAN_INTERFACE
else
    for path in /sys/class/net/*; do
        ifc=${path##*/}
        case $ifc in
            lo | "$WAN_INTERFACE" | wg* | tun* | tap* | docker* | veth* | br-* | virbr*) continue ;;
        esac
        if [ -n "$(iface_cidr "$ifc")" ]; then
            default_lan=$ifc
            break
        fi
    done
fi
LAN_INTERFACE=$(ask "LAN adapter (for the devices going through the VPN)" "$default_lan")
[ -n "$LAN_INTERFACE" ] || die "No LAN adapter given. Give your second adapter a static IP first, e.g. 192.168.99.1/24 (see the README)."
[ "$LAN_INTERFACE" != "$WAN_INTERFACE" ] || die "The WAN and LAN have to be different adapters"
[ -d "/sys/class/net/$LAN_INTERFACE" ] || die "There's no adapter called $LAN_INTERFACE"

# LAN addressing
lan_cidr=$(iface_cidr "$LAN_INTERFACE")
[ -n "$lan_cidr" ] || die "$LAN_INTERFACE doesn't have an IPv4 address. Give it a static IP first, e.g. 192.168.99.1/24 (see the README)."
if ip -4 -o addr show dev "$LAN_INTERFACE" | grep -q dynamic; then
    die "$LAN_INTERFACE got its address from DHCP. It needs a static IP, e.g. 192.168.99.1/24 (see the README)."
fi

LAN_ADDRESS=${lan_cidr%/*}
LAN_PREFIX=${lan_cidr#*/}
if [ "$LAN_PREFIX" -lt 16 ] || [ "$LAN_PREFIX" -gt 29 ]; then
    die "The LAN subnet needs to be between /16 and /29, $LAN_INTERFACE has $lan_cidr"
fi

addr=$(ip_to_int "$LAN_ADDRESS")
mask=$(prefix_to_mask "$LAN_PREFIX")
net=$(( addr & mask ))
bcast=$(( net | (~mask & 0xFFFFFFFF) ))
hosts=$(( bcast - net - 1 ))
if [ "$hosts" -ge 254 ]; then
    start=$(( net + 100 ))
    end=$(( net + 250 ))
else
    start=$(( net + hosts / 2 + 1 ))
    end=$(( bcast - 1 ))
fi
if [ "$addr" -ge "$start" ] && [ "$addr" -le "$end" ]; then
    die "$LAN_ADDRESS is inside the DHCP range ($(int_to_ip "$start") to $(int_to_ip "$end")). Give the gateway the first address in the subnet instead, $(int_to_ip $(( net + 1 )))."
fi

LAN_SUBNET="$(int_to_ip "$net")/$LAN_PREFIX"
LAN_NETMASK=$(int_to_ip "$mask")
DHCP_START=$(int_to_ip "$start")
DHCP_END=$(int_to_ip "$end")

wan_cidr=$(iface_cidr "$WAN_INTERFACE")
if [ -n "$wan_cidr" ]; then
    wmask=$(prefix_to_mask "${wan_cidr#*/}")
    wnet=$(( $(ip_to_int "${wan_cidr%/*}") & wmask ))
    if [ $(( net & wmask )) -eq "$wnet" ] || [ $(( wnet & mask )) -eq "$net" ]; then
        die "The LAN ($LAN_SUBNET) overlaps your existing network ($wan_cidr). Use a different subnet on $LAN_INTERFACE, e.g. 192.168.99.1/24 or 172.16.99.1/24."
    fi
else
    warn "$WAN_INTERFACE has no IPv4 address. The gateway needs internet on the WAN to reach the VPN server."
fi

# DNS
if [ -n "$VPN_SOURCE" ]; then
    dns_default=
    [ "$VPN_TYPE" = wireguard ] && dns_default=$(wireguard_dns "$VPN_SOURCE")
    dns_default=${dns_default:-$DEFAULT_DNS}
else
    dns_default=${UPSTREAM_DNS:-$DEFAULT_DNS}
fi
UPSTREAM_DNS=$(ask "DNS servers for the LAN, looked up through the VPN" "$dns_default")
UPSTREAM_DNS=$(echo "${UPSTREAM_DNS//,/ }" | xargs)
[ -n "$UPSTREAM_DNS" ] || die "At least one DNS server is needed"
for s in $UPSTREAM_DNS; do
    is_ipv4 "$s" || die "$s isn't an IPv4 address"
done

echo
info "Ready to set up:"
cat <<EOF
    VPN           $VPN_TYPE ($VPN_INTERFACE)
    WAN adapter   $WAN_INTERFACE ${wan_cidr:-}
    LAN adapter   $LAN_INTERFACE $lan_cidr
    DHCP range    $DHCP_START to $DHCP_END
    DNS           $UPSTREAM_DNS, through the VPN
    SSH           open on both adapters
EOF
echo
yes_no "Continue?" y || { echo "Cancelled."; exit 0; }

# Packages. dnsmasq's config goes in first so it starts up serving only the
# LAN and doesn't clash with systemd-resolved on port 53.
write_dnsmasq_config

packages=(iproute2 iptables dnsmasq openssh-server curl bind9-dnsutils)
if [ "$VPN_TYPE" = wireguard ]; then
    packages+=(wireguard-tools)
else
    packages+=(openvpn)
fi
missing=()
for p in "${packages[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
done
if [ ${#missing[@]} -gt 0 ]; then
    info "Installing ${missing[*]}"
    apt-get update || die "Couldn't reach the package mirrors. If the kill switch is already running, the VPN has to be up for this box to get online."
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
fi

# VPN config
if [ -n "$VPN_SOURCE" ]; then
    info "Installing the VPN config to $VPN_CONFIG"
    if [ "$VPN_TYPE" = wireguard ]; then
        install_wireguard_config "$VPN_SOURCE"
    else
        install_openvpn_config "$VPN_SOURCE"
    fi
fi

# SSH
info "Making sure SSH is running"
if systemctl is-enabled -q ssh.socket 2>/dev/null; then
    systemctl start ssh.socket
else
    systemctl enable -q --now ssh
fi
SSH_PORTS=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -un | xargs)
SSH_PORTS=${SSH_PORTS:-22}

info "Saving settings to $CONF"
cat > "$CONF" <<EOF
# vpn-gateway settings, written by install.sh. Re-run it to change them.
VPN_TYPE=$VPN_TYPE
VPN_INTERFACE=$VPN_INTERFACE
VPN_SERVICE=$VPN_SERVICE
VPN_CONFIG=$VPN_CONFIG
WAN_INTERFACE=$WAN_INTERFACE
LAN_INTERFACE=$LAN_INTERFACE
LAN_ADDRESS=$LAN_ADDRESS
LAN_SUBNET=$LAN_SUBNET
DHCP_START=$DHCP_START
DHCP_END=$DHCP_END
UPSTREAM_DNS="$UPSTREAM_DNS"
SSH_PORTS="$SSH_PORTS"
EOF

info "Installing scripts and services"
systemctl stop vpn-gateway-monitor 2>/dev/null || true
remove_old_version
if [ -n "$PREV_VPN_SERVICE" ] && [ "$PREV_VPN_SERVICE" != "$VPN_SERVICE" ]; then
    systemctl disable -q --now "$PREV_VPN_SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/$PREV_VPN_SERVICE.service.d/vpn-gateway.conf"
fi
install_files

info "Starting the kill switch firewall"
systemctl enable -q vpn-gateway-firewall
systemctl restart vpn-gateway-firewall

info "Starting the VPN"
/usr/local/bin/vpn-gateway-monitor --sync-routes
systemctl enable -q "$VPN_SERVICE"
systemctl restart "$VPN_SERVICE" || warn "$VPN_SERVICE failed to start, check: journalctl -u $VPN_SERVICE"

info "Starting DHCP and DNS"
systemctl enable -q dnsmasq
systemctl restart dnsmasq

info "Starting the monitor"
systemctl enable -q vpn-gateway-monitor
systemctl restart vpn-gateway-monitor

info "Waiting for the tunnel"
public_ip=
for _ in $(seq 1 30); do
    if ip -4 addr show dev "$VPN_INTERFACE" 2>/dev/null | grep -q 'inet '; then
        public_ip=$(curl -s --max-time 10 --interface "$VPN_INTERFACE" https://ifconfig.me || true)
        [ -n "$public_ip" ] && break
    fi
    sleep 2
done

echo
if [ -n "$public_ip" ]; then
    echo -e "${GREEN}All done. The VPN is up and your public IP is $public_ip${NC}"
else
    echo -e "${YELLOW}Everything is installed but the VPN isn't passing traffic yet.${NC}"
    echo "Check it with: sudo vpn-gateway-status"
    echo "VPN logs:      sudo journalctl -u $VPN_SERVICE"
fi
echo
echo "Plug a switch, Wi-Fi access point or device into $LAN_INTERFACE. Anything set"
echo "to get its address automatically will get one from $DHCP_START to $DHCP_END"
echo "and go through the VPN."
echo
ssh_user=$(logname 2>/dev/null || echo you)
echo "Manage it over SSH from either side:"
echo "    ssh $ssh_user@$LAN_ADDRESS"
[ -n "$wan_cidr" ] && echo "    ssh $ssh_user@${wan_cidr%/*}"
echo "Check on it any time with: sudo vpn-gateway-status"
