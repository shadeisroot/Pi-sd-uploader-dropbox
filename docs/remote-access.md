# Remote access (optional)

An uploader often lives somewhere else, like a parent's house. To check on it or update it from home, the Pi needs a way back to you. Two good options:

## Tailscale (easiest)

[Tailscale](https://tailscale.com) builds a private network between your devices with no router changes:

```bash
curl -fsSL https://tailscale.com/install.sh | sh   # read it first if you prefer: it's Tailscale's official script
sudo tailscale up
```

Log in with the link it prints, then reach the Pi from any of your devices with `ssh <user>@<pi-name>`.

## WireGuard to your own router

If you already run a WireGuard server at home (OPNsense, pfSense, OpenWrt, a VPS…), the Pi can be a client that keeps the tunnel open:

```bash
sudo apt install -y wireguard-tools
sudo sh -c 'umask 077; wg genkey > /etc/wireguard/pi.key'
sudo sh -c 'wg pubkey < /etc/wireguard/pi.key'      # give this public key to your server
```

`/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.8.0.10/32                               # the Pi's tunnel address
PostUp = wg set %i private-key /etc/wireguard/pi.key # the private key never leaves the Pi

[Peer]
PublicKey = <your server's public key>
Endpoint = vpn.example.com:51820
AllowedIPs = 10.8.0.0/24                             # only the tunnel network: uploads still use the local internet
PersistentKeepalive = 25                             # keeps the path open through someone else's router
```

```bash
sudo systemctl enable --now wg-quick@wg0
```

Tips:
- Keep `AllowedIPs` to the tunnel network only, so Dropbox traffic doesn't detour through your home.
- If your home IP changes (dynamic DNS), WireGuard only looks up the name at startup. The [`reresolve-dns`](https://github.com/WireGuard/wireguard-tools/tree/master/contrib/reresolve-dns) script from wireguard-tools, run every few minutes by a systemd timer, keeps the tunnel up after a change.
- If home devices reach the Pi through the router but the Pi's replies go out the local network, add a source NAT rule on the server for traffic to the Pi's tunnel address.
