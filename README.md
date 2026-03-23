# unifi-6rd-scripts

IPv6 via CenturyLink 6rd on UniFi OS (UDM Pro / UDM SE / Dream Machine).

CenturyLink residential does not provide native IPv6. Instead they offer
[6rd (RFC 5969)](https://www.rfc-editor.org/rfc/rfc5969), which tunnels IPv6
over your existing IPv4 PPPoE connection. Your IPv6 prefix is derived
deterministically from your WAN IPv4 address, so no DHCPv6 is involved.

These scripts create and maintain the 6rd tunnel, assign a `/64` to your LAN
bridge(s), and configure dnsmasq to advertise IPv6 prefixes and DNS to LAN
clients via SLAAC/RA.

---

## How it works

CenturyLink's 6rd parameters (residential):

| Parameter | Value |
|---|---|
| 6rd prefix | `2602::/24` |
| Border Relay | `205.171.2.64` |
| IPv4 mask length | `0` (full WAN IPv4 embedded) |
| Delegation | `/56` per subscriber |

Your `/56` is derived by embedding your WAN IPv4 into bits 24–55 of `2602::/24`.
For example, WAN IP `198.51.100.1` produces `2602:c6:6464:100::/56`, and the
first LAN `/64` is `2602:c6:6464:100::/64`. This recalculates automatically
if your PPPoE session renews and your IP changes.

The tunnel is a `sit` (Simple Internet Tunnel) interface. Outbound IPv6 packets
are encapsulated in IPv4 and sent to the CenturyLink Border Relay, which
forwards them to the IPv6 internet.

---

## Requirements

- UniFi OS firmware **2.x or later** (`/data` persistent storage)
- UniFi Network app **9.3.29 or later** (uses `/run/dnsmasq.dhcp.conf.d/`)
- CenturyLink **residential PPPoE** WAN (WAN interface will be `ppp0` or `ppp2`)
- IPv6 disabled in the UniFi UI for the WAN interface (no `odhcp6c` conflict)
- Install [UniFi OS Utilities on-boot-script-2.x](https://github.com/unifi-utilities/unifios-utilities/tree/main/on-boot-script-2.x) — provides the `/data/on_boot.d/` hook that runs scripts after each boot

> **Tested on:** UDM firmware 5.0.16, UniFi Network 9.x

---

## Files

```
99-centurylink-6rd.sh        # Boot hook + WAN IP change watchdog
centurylink-6rd-setup.sh     # Tunnel creation and dnsmasq RA configuration
```

---

## Configuration

Edit the user-configurable variables at the top of `centurylink-6rd-setup.sh`
before deploying.

### Variables you must review

**`WAN_IFACE`** — The PPPoE interface for your CenturyLink WAN connection.
```bash
WAN_IFACE="ppp2"
```
To find the correct interface name on your device:
```bash
ip link show | grep ppp
```
Common values are `ppp0` or `ppp2` depending on your UniFi OS version.

**`LAN_BRIDGES`** — Space-separated list of LAN bridge interfaces to assign
IPv6 and enable router advertisement on. Each bridge gets its own `/64`
from your `/56` delegation.
```bash
LAN_BRIDGES="br0"              # single LAN
LAN_BRIDGES="br0 br100 br200"  # multiple VLANs
```

**`DNS6`** — IPv6 DNS servers advertised to LAN clients.
```bash
# Cloudflare Family (malware + adult content filtering) — default
DNS6="[2606:4700:4700::1113],[2606:4700:4700::1003]"

# Cloudflare standard
DNS6="[2606:4700:4700::1111],[2606:4700:4700::1001]"

# Google
DNS6="[2001:4860:4860::8888],[2001:4860:4860::8844]"
```

**`DOMAIN`** — DNS search domain advertised to LAN clients.
```bash
DOMAIN="example.invalid"   # replace with your local domain if desired
```

### Variables you should not need to change

| Variable | Default | Description |
|---|---|---|
| `SIT_IFACE` | `6rd-wan` | Name of the tunnel interface |
| `SIT_TTL` | `64` | TTL for encapsulated packets |
| `BR_PRIMARY` | `205.171.2.64` | CenturyLink Border Relay (only one verified) |
| `SIXRD_PREFIX` | `2602::` | CenturyLink 6rd IPv6 base prefix |
| `SIXRD_PREFIX_LEN` | `24` | 6rd prefix length |
| `CONF_DIR` | `/data/centurylink-6rd` | Persistent config storage |

---

## Installation

**1. Disable WAN IPv6 in the UniFi UI**

Go to Settings → Internet → your WAN → IPv6 and set it to disabled. If
UniFi's `odhcp6c` DHCPv6 client is running it will conflict with the tunnel.

**2. Copy files to the device**

```bash
# From your local machine
scp centurylink-6rd-setup.sh root@<udm-ip>:/data/centurylink-6rd/
scp 99-centurylink-6rd.sh root@<udm-ip>:/data/on_boot.d/
```

**3. Set permissions**

```bash
ssh root@<udm-ip>
chmod +x /data/centurylink-6rd/centurylink-6rd-setup.sh
chmod +x /data/on_boot.d/99-centurylink-6rd.sh
```

**4. Run the boot hook manually to test**

```bash
/data/on_boot.d/99-centurylink-6rd.sh
```

You should see output like:
```
[6rd-boot] Starting CenturyLink 6rd configuration
[6rd-boot] Waiting for ppp2 to come up (timeout: 120s)
[6rd-boot] ppp2 is up: 198.51.100.1
[6rd-setup] WAN IP:          198.51.100.1
[6rd-setup] 6rd /64 (LAN 0): 2602:c6:6464:100::/64
[6rd-setup] Tunnel 6rd-wan up, routes installed
[6rd-setup] Assigned 2602:c6:6464:100::1/64 to br0
[6rd-setup] dnsmasq config deployed to /run/dnsmasq.dhcp.conf.d/centurylink-6rd.conf
[6rd-setup] dnsmasq restarted
[6rd-setup] 6rd setup complete
[6rd-boot] Setup succeeded for IP 198.51.100.1
[6rd-boot] Starting watchdog (interval: 60s)
```

The script will continue running in the foreground as the watchdog. On
subsequent boots UniFi OS runs it in the background automatically via
`on_boot.d`.

---

## Verification

**Tunnel interface is up:**
```bash
ip tunnel show 6rd-wan
ip -6 addr show dev 6rd-wan
```

**Default IPv6 route installed:**
```bash
ip -6 route show | grep default
```

**br0 has its /64:**
```bash
ip -6 addr show dev br0
```

**Router can reach the IPv6 internet:**
```bash
ping6 -c3 2606:4700:4700::1113   # Cloudflare
ping6 -c3 ipv6.google.com
```

**LAN clients received a SLAAC address** (run on a LAN host):
```bash
# Linux
ip -6 addr show | grep 2602

# macOS
ifconfig | grep 2602

# Windows
ipconfig | findstr 2602
```

---

## How the watchdog works

The boot hook (`99-centurylink-6rd.sh`) stays running after initial setup and
polls the WAN IP every 60 seconds. If the IP changes — which happens when
CenturyLink renews your PPPoE session — it tears down the existing tunnel and
rebuilds it with the new IP and recalculated prefix. Without this, IPv6 would
silently break after a session renewal until the next reboot.

---

## Troubleshooting

**`odhcp6c` conflict warning**

If you see a warning about `odhcp6c` running, go to the UniFi UI and disable
IPv6 on the WAN interface. UniFi's built-in DHCPv6 client will otherwise
interfere with the tunnel.

**Tunnel up but no IPv6 on LAN clients**

Check that the dnsmasq config was deployed and the process reloaded:
```bash
cat /run/dnsmasq.dhcp.conf.d/centurylink-6rd.conf
ps aux | grep dnsmasq
```

**Router can't ping IPv6 destinations**

Check that protocol 41 (IPv6-in-IPv4) is not being blocked by the WAN
firewall. Some ISP-provided modems in passthrough/bridge mode still filter
protocol 41. If you're behind a modem in bridge mode and pings fail, try
a direct connection to verify.

**Checking the derived prefix manually**

If you want to verify the prefix calculation for a given WAN IP:
```bash
WAN_IP="198.51.100.1"
IFS='.' read -r a b c d <<< "$WAN_IP"
printf "2602:%x:%x%x:%x00::/64\n" \
    "$a" "$b" "$c" "$d"
```
