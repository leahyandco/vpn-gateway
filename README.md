# VPN Gateway

Scripts to turn a Debian or Ubuntu box with two network adapters into a VPN gateway with a kill switch. Devices on the LAN side use it as their default gateway, and everything they send goes out through an OpenVPN or WireGuard tunnel. If the tunnel drops, their traffic is blocked instead of going out your normal connection.

## Setup

1. Set up the box with two adapters: a WAN with internet access, and a LAN with a static IP like `192.168.100.1/24`.
2. Run `sudo ./install.sh` and answer the prompts.
3. Put your provider's config at `/etc/wireguard/wg0.conf` or `/etc/openvpn/client/vpn.conf`.
4. Start the VPN, then the kill switch and monitor:

```bash
sudo systemctl enable --now wg-quick@wg0      # or openvpn-client@vpn
sudo systemctl enable --now vpn-gateway-firewall vpn-monitor
```

5. On each device, set the gateway's LAN IP as the default gateway and use a public DNS server like 1.1.1.1.

Check on it with `sudo ./status.sh`. Run `./test-client.sh` on a device to make sure its traffic is going through the VPN.

Remove it with `sudo ./uninstall.sh`.
