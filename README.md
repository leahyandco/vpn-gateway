# VPN Gateway

Turns a spare Debian or Ubuntu box into a VPN router. Plug anything into its second network port and it gets an IP address from the gateway, and all of its traffic goes out through your VPN. If the VPN drops, those devices just lose internet until it comes back. Nothing leaks out your real connection.

I wanted a simple way to put a handful of devices behind a VPN without setting up a VPN app on every one of them. It also covers things that can't run a VPN app at all, like TVs, consoles and IoT gear.

It works with any provider that gives you a WireGuard or OpenVPN config file.

## How it works

```
        Internet
           |
   Your existing router
           |
      [ WAN port ]      gets an address from your router like normal
      VPN gateway
      [ LAN port ]      192.168.99.1, hands out addresses and DNS
           |
 Switch, Wi-Fi access point
   or a single device
           |
     Your devices       everything goes through the VPN
```

- The WAN port plugs into your existing network. The gateway only uses it to reach the VPN server.
- The LAN port is a new private network. The gateway is its DHCP server, router and DNS server.
- Traffic from the LAN can only leave through the VPN tunnel. There's no firewall rule letting it out the WAN, so if the tunnel is down it gets dropped. That's the kill switch.
- DNS lookups from your devices go to the gateway, which sends them through the tunnel. They never go to your ISP.
- A monitor checks the tunnel every 30 seconds and restarts the VPN if it stops working.
- SSH is open on both ports so you can manage it from either network.

## What you need

- A box with two network adapters. An old PC, a mini PC, a Raspberry Pi with a USB ethernet adapter, or a VM with two NICs all work fine.
- Debian 11 or newer, or Ubuntu 20.04 or newer.
- A WireGuard (`.conf`) or OpenVPN (`.ovpn`) config file from your VPN provider. Use WireGuard if your provider has it, it's a lot faster.

## Setup

### 1. Plug it in

Connect the first adapter to your existing network, like a spare port on your router or main switch. This is the WAN. It should get an address by DHCP like any other device, and the box should be able to reach the internet.

Connect the second adapter to whatever you want behind the VPN. More on that in step 4.

### 2. Give the LAN adapter a static IP

The installer doesn't touch your network config, so set the LAN adapter's address yourself first. I recommend **192.168.99.1/24**. It's unlikely to clash with your existing network and it's what the rest of this README uses. If your network already uses 192.168.99.x, use 172.16.99.1/24 instead.

Find your adapter names with `ip -br addr`. The WAN is the one that already has an address. The examples below use `eth0` for the WAN and `eth1` for the LAN, so swap in your own names.

**Ubuntu (netplan).** Edit the file in `/etc/netplan/`:

```yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
    eth1:
      dhcp4: false
      addresses: [192.168.99.1/24]
      optional: true
```

`optional: true` stops boot hanging for two minutes when nothing is plugged into the LAN port. Then run `sudo netplan apply`.

**Debian (ifupdown).** Add this to `/etc/network/interfaces`:

```
auto eth1
iface eth1 inet static
    address 192.168.99.1/24
```

Then run `sudo ifup eth1`.

**NetworkManager** (Ubuntu Desktop and similar):

```bash
sudo nmcli con add type ethernet ifname eth1 con-name lan ipv4.method manual ipv4.addresses 192.168.99.1/24 ipv6.method disabled
```

Don't set a gateway or DNS servers on the LAN adapter, just the address. Check it with `ip -br addr show eth1`.

### 3. Run the installer

Copy your VPN config file onto the box, then:

```bash
git clone https://github.com/leahyandco/vpn-gateway.git
cd vpn-gateway
sudo ./install.sh ~/my-vpn.conf
```

It works out whether the file is WireGuard or OpenVPN, picks the WAN and LAN adapters and asks you to confirm them, then shows a summary before it changes anything. If it's an OpenVPN config that needs a username and password, it asks for those too.

Then it installs the VPN client, dnsmasq (for DHCP and DNS) and SSH, sets up the firewall and starts everything. At the end it waits for the tunnel to come up and shows your public IP through the VPN.

You can re-run it whenever you want to change something. Give it a new config file to switch VPN servers, or run it with no file to keep the current one.

### 4. Connect your devices

Plug one of these into the LAN port:

- **A switch**, for a few wired devices.
- **A Wi-Fi access point**, for wireless devices. Put it in access point or bridge mode so the gateway hands out the addresses. If it's a normal home router, turn off its DHCP server and plug the gateway into one of its LAN ports, not its WAN or internet port.
- **A single device**, plugged straight in.

Anything set to get its address automatically (which is the default on pretty much everything) will get an address from 192.168.99.100 to 192.168.99.250, with the gateway as its router and DNS server.

To check it's working, open [ipleak.net](https://ipleak.net) on one of the devices. You should see your VPN provider's IP and DNS servers, and nothing from your ISP. On a Linux device you can also run `./test-client.sh` from this repo.

## DNS

Your devices use the gateway for DNS, and the gateway sends the lookups through the tunnel to:

- your provider's DNS servers, if your WireGuard config has a `DNS =` line, or
- Cloudflare (1.1.1.1) and Quad9 (9.9.9.9) otherwise.

I'd use your provider's DNS if you can, since they already see your traffic anyway. To change it, re-run the installer and enter different servers when it asks.

Devices can also find each other by name, e.g. `ping laptop.lan`.

## Managing it

SSH in from either side:

```bash
ssh you@192.168.99.1              # from the LAN
ssh you@<the WAN address>         # from your existing network
```

Check on everything:

```bash
sudo vpn-gateway-status
```

That shows the tunnel, your public IP, the kill switch, how many devices have an address, whether DNS is working, and the monitor's recent log.

Logs:

```bash
sudo journalctl -u wg-quick@wg0          # WireGuard
sudo journalctl -u openvpn-client@vpn    # OpenVPN
sudo journalctl -u dnsmasq               # DHCP and DNS
sudo journalctl -u vpn-gateway-monitor   # reconnects
```

Devices with an address: `cat /var/lib/misc/dnsmasq.leases`

To test the kill switch, stop the VPN with `sudo systemctl stop wg-quick@wg0` (or `openvpn-client@vpn`). Devices on the LAN lose internet straight away. The monitor notices and starts the VPN again within a minute or so.

## Troubleshooting

**Devices don't get an address.** Check the cable and that the LAN adapter still has its static IP (`ip -br addr`). Then check dnsmasq is running with `sudo systemctl status dnsmasq`. If you're using a home router as the access point, make sure its own DHCP server is off.

**Devices get an address but no internet.** The VPN is probably down. Run `sudo vpn-gateway-status` and check the VPN log.

**The VPN won't connect.** Check the log for the VPN service. For OpenVPN it's usually a wrong username or password, which you can fix by re-running the installer. Remember the gateway itself can only reach the VPN server, DNS and NTP over the WAN, so things like `apt update` on the gateway only work while the tunnel is up.

**Some sites load and others hang, or big downloads stall.** That's usually an MTU problem. The gateway already clamps TCP MSS to the tunnel's MTU, which fixes most of it. If you still see it on WireGuard, add `MTU = 1380` under `[Interface]` in `/etc/wireguard/wg0.conf` and restart with `sudo systemctl restart wg-quick@wg0`.

**I can't get to my printer or NAS from the LAN.** That's on purpose. Devices behind the gateway can only reach the internet through the VPN, not your existing network.

## Things to know

- **IPv4 only.** The LAN doesn't get IPv6 and the gateway doesn't forward it, so nothing can sneak around the VPN over IPv6.
- **Your VPN provider can see your traffic.** This hides it from your ISP and the sites you visit, not from your provider.
- **Browsers can still leak.** WebRTC can expose your real IP regardless of the network. Check with [ipleak.net](https://ipleak.net) and turn it off in your browser if it shows up.
- **The firewall is the whole box.** The installer replaces the INPUT, OUTPUT and FORWARD rules, so use a box that's dedicated to this rather than one running other services.

## Uninstalling

```bash
sudo ./uninstall.sh
```

It stops and removes everything the installer added. It leaves your network config and SSH alone, and asks before deleting your VPN config files or removing packages.

## What gets installed

| Path | What it is |
|------|------------|
| `/etc/vpn-gateway.conf` | Settings from the installer |
| `/etc/wireguard/wg0.conf` | WireGuard config |
| `/etc/openvpn/client/vpn.conf` | OpenVPN config |
| `/etc/openvpn/client/vpn-auth.txt` | OpenVPN username and password |
| `/etc/dnsmasq.d/vpn-gateway.conf` | DHCP and DNS for the LAN |
| `/usr/local/bin/vpn-gateway-firewall` | Kill switch firewall rules |
| `/usr/local/bin/vpn-gateway-monitor` | Reconnects the VPN if it drops |
| `/usr/local/bin/vpn-gateway-status` | Status check |
| `/etc/systemd/system/vpn-gateway-*.service` | Services for the firewall and monitor |

## License

MIT, see [LICENSE](LICENSE).
