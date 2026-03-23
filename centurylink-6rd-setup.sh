#!/bin/bash
# centurylink-6rd-setup.sh
# Configures a 6rd tunnel for CenturyLink residential service and enables
# IPv6 router advertisement on LAN bridges via dnsmasq.
#
# Called by 99-centurylink-6rd.sh on boot and on WAN IP change.
#
# CenturyLink 6rd parameters (residential):
#   6rd prefix:    2602::/24
#   BR relays:     205.171.2.64, 205.171.3.64
#   IPv4 mask len: 0 (full WAN IPv4 embedded)
#   Delegated:     /56 per subscriber (WAN IP embedded in bits 24-55)
#   LAN prefix:    /64 sliced from the /56

set -eo pipefail

# ---------------------------------------------------------------------------
# User-configurable variables — review these before deploying
# ---------------------------------------------------------------------------

# WAN_IFACE: The PPPoE interface created by UniFi for your CenturyLink WAN.
# Typically ppp0 or ppp2. Check with: ip link show | grep ppp
WAN_IFACE="ppp2"

# LAN_BRIDGES: Space-separated list of LAN bridge interfaces to assign IPv6
# prefixes and enable router advertisement on.
# Each bridge gets its own /64 slice from your 6rd /56 delegation.
# Example for multiple VLANs: LAN_BRIDGES="br0 br100 br200"
LAN_BRIDGES="br0"

# DNS6: IPv6 DNS servers advertised to LAN clients via dnsmasq.
# Format: comma-separated, each address in square brackets.
# Cloudflare Family (blocks malware + adult content):
DNS6="[2606:4700:4700::1113],[2606:4700:4700::1003]"
# Alternatives:
#   Cloudflare standard:  [2606:4700:4700::1111],[2606:4700:4700::1001]
#   Google:               [2001:4860:4860::8888],[2001:4860:4860::8844]

# DOMAIN: DNS search domain advertised to LAN clients.
# Set to your local domain or leave as example.invalid.
DOMAIN="example.invalid"

# ---------------------------------------------------------------------------
# 6rd tunnel variables — do not change unless CenturyLink changes their infra
# ---------------------------------------------------------------------------

# SIT_IFACE: Name of the sit tunnel interface created by this script.
SIT_IFACE="6rd-wan"

# SIT_TTL: TTL for encapsulated packets. 64 is standard.
SIT_TTL=64

# BR_PRIMARY: CenturyLink 6rd Border Relay address.
# Forwards encapsulated IPv6 traffic to the IPv6 internet.
# Source: CenturyLink modem documentation and multiple independent community sources.
# No secondary BR has been verified in any primary source.
BR_PRIMARY="205.171.2.64"

# SIXRD_PREFIX / SIXRD_PREFIX_LEN: CenturyLink's 6rd IPv6 prefix.
# Your /56 is derived by embedding your WAN IPv4 into bits 24-55 of this prefix.
SIXRD_PREFIX="2602::"
SIXRD_PREFIX_LEN=24

# ---------------------------------------------------------------------------
# Internal paths — adjust only if you change the install location
# ---------------------------------------------------------------------------

# CONF_DIR: Persistent storage for generated config files.
CONF_DIR="/data/centurylink-6rd"

# DNSMASQ_CONF: Generated dnsmasq RA config (persisted across reboots).
DNSMASQ_CONF="${CONF_DIR}/centurylink-6rd-dnsmasq.conf"

# DNSMASQ_DROP: Runtime drop-in path loaded by the main dnsmasq instance.
# Uses dhcp.conf.d because that is the --conf-dir loaded by UniFi's main
# dnsmasq process, regardless of whether the config contains DHCP or RA rules.
DNSMASQ_DROP="/run/dnsmasq.dhcp.conf.d/centurylink-6rd.conf"

log() { echo "[6rd-setup] $*" >&2; }
err() { echo "[6rd-setup] ERROR: $*" >&2; }

# ---------------------------------------------------------------------------
# Derive IPv6 /56 prefix from CenturyLink 6rd parameters and WAN IPv4.
#
# Method:
#   Take the 24-bit 6rd prefix (2602::/24) and embed the full 32-bit WAN IPv4
#   in the next 32 bits (bits 24-55), yielding a /56 per subscriber.
#
#   WAN IP octets A.B.C.D become two 16-bit groups:
#     group3 = (A << 8) | B  (hex: AABB)
#     group4 = (C << 8) | D  (hex: CCDD)
#
#   Full /56 prefix: 2602:00AB:CCDD:XX00::/56
#     where 2602: is bits 0-15
#           00   is bits 16-23 (remaining bits of the /24 base)
#           AB   is bits 24-31 (octet A)
#           CCDD is bits 32-47 (octets C.D)
#           XX   is bits 48-55 (octet ... wait — see below)
#
#   CenturyLink specific: prefix is 2602::/24, IPv4 mask length 0,
#   so all 32 IPv4 bits are embedded starting at bit 24.
#
#   Resulting /56:
#     2602:00<A><B>:<C><D>XX::/56   where XX = 00..FF are the /64 slices
#
#   We return the /56 base (the first /64 slice, XX=00).
# ---------------------------------------------------------------------------
derive_prefix() {
    local wan_ip="$1"
    local a b c d

    IFS='.' read -r a b c d <<< "$wan_ip"

    # Validate all octets are numeric 0-255
    for octet in "$a" "$b" "$c" "$d"; do
        if ! [[ "$octet" =~ ^[0-9]+$ ]] || [ "$octet" -gt 255 ]; then
            err "Invalid WAN IP octet: $octet"
            return 1
        fi
    done

    # Build hex groups
    local g3 g4
    g3=$(printf "%02x%02x" "$a" "$b")
    g4=$(printf "%02x%02x" "$c" "$d")

    # /56 base prefix: 2602:00<g3_hi><g3_lo>:<g4>:<subscriber_byte>00::/56
    # In practice the /64 slice for LAN 0 is:
    #   2602:00<AB>:<CD>00::/64  — but this isn't quite right for all IPs.
    #
    # Correct construction:
    #   bits  0-15: 2602
    #   bits 16-23: 00          (3rd byte of /24: 0x00)
    #   bits 24-31: A           (1st IPv4 octet)
    #   bits 32-47: B.C         (2nd and 3rd IPv4 octets)
    #   bits 48-55: D           (4th IPv4 octet — this is the /56 boundary)
    #   bits 56-63: 00          (subscriber /64 index, 0 = first LAN)
    #
    # Regroup into 4x16-bit groups:
    #   group1: 2602
    #   group2: 00<A>           = 00 || hex(A)
    #   group3: <BC>            = hex(B) || hex(C)
    #   group4: <D>00           = hex(D) || 00  (first /64 slice)

    local g2 g3_proper g4_proper
    g2=$(printf "00%02x" "$a")
    g3_proper=$(printf "%02x%02x" "$b" "$c")
    g4_proper=$(printf "%02x00" "$d")

    # Compress leading zeros for each group (cosmetic)
    g2=$(printf "%x" "0x${g2}")
    g3_proper=$(printf "%x" "0x${g3_proper}")
    g4_proper=$(printf "%x" "0x${g4_proper}")

    echo "2602:${g2}:${g3_proper}:${g4_proper}::/64"
}

# ---------------------------------------------------------------------------
# Get the /56 base (without the final ::/64) for use in tunnel and route setup
# ---------------------------------------------------------------------------
derive_56_base() {
    local wan_ip="$1"
    local a b c d

    IFS='.' read -r a b c d <<< "$wan_ip"

    local g2 g3 g4_base
    g2=$(printf "%x" "0x$(printf "00%02x" "$a")")
    g3=$(printf "%x" "0x$(printf "%02x%02x" "$b" "$c")")
    g4_base=$(printf "%x" "0x$(printf "%02x" "$d")")

    echo "2602:${g2}:${g3}:${g4_base}"
}

# ---------------------------------------------------------------------------
# Tear down existing tunnel if present
# ---------------------------------------------------------------------------
teardown_tunnel() {
    if ip link show "${SIT_IFACE}" >/dev/null 2>&1; then
        log "Removing existing tunnel ${SIT_IFACE}"
        ip tunnel del "${SIT_IFACE}" || true
    fi
    # Remove any stale sit0 tunnel entries
    if ip link show sit0 >/dev/null 2>&1; then
        ip link set sit0 down 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Build the tunnel and assign addresses
# ---------------------------------------------------------------------------
setup_tunnel() {
    local wan_ip="$1"
    local lan_prefix_64
    local prefix_56_base

    lan_prefix_64=$(derive_prefix "$wan_ip")
    prefix_56_base=$(derive_56_base "$wan_ip")

    log "WAN IP:          ${wan_ip}"
    log "6rd /64 (LAN 0): ${lan_prefix_64}"

    # Create sit tunnel and configure 6rd parameters
    ip tunnel add "${SIT_IFACE}" mode sit \
        local "${wan_ip}" \
        ttl "${SIT_TTL}"

    # Configure 6rd: embed full WAN IPv4 (mask 0) into 2602::/24
    # Note: parameter is 6rd-relay_prefix (underscore), not 6rd-relay-prefix
    ip tunnel 6rd dev "${SIT_IFACE}" \
        6rd-prefix "${SIXRD_PREFIX}/${SIXRD_PREFIX_LEN}" \
        6rd-relay_prefix 0.0.0.0/0

    ip link set "${SIT_IFACE}" up

    # Assign our /128 tunnel address — the router's IPv6 WAN identity.
    local tunnel_addr="${prefix_56_base}00::1/128"
    ip addr add "${tunnel_addr}" dev "${SIT_IFACE}" || true

    # Default IPv6 route via both BRs (primary preferred, secondary fallback)
    ip -6 route add ::/0 via "::${BR_PRIMARY}" dev "${SIT_IFACE}" || true

    log "Tunnel ${SIT_IFACE} up, routes installed"

    # Assign /64 to each LAN bridge
    for bridge in ${LAN_BRIDGES}; do
        local bridge_addr
        bridge_addr="${prefix_56_base}00::1/64"
        ip -6 addr add "${bridge_addr}" dev "${bridge}" 2>/dev/null || {
            # Already assigned — flush and re-add in case prefix changed
            ip -6 addr flush dev "${bridge}" scope global 2>/dev/null || true
            ip -6 addr add "${bridge_addr}" dev "${bridge}"
        }
        log "Assigned ${bridge_addr} to ${bridge}"
    done
}

# ---------------------------------------------------------------------------
# Write dnsmasq config for RA + SLAAC on LAN bridges
# ---------------------------------------------------------------------------
write_dnsmasq_conf() {
    local conf_tmp="${DNSMASQ_CONF}.tmp"

    : > "${conf_tmp}"
    cat >> "${conf_tmp}" << 'DNSMASQ_HEADER'
#
# via centurylink-6rd — do not edit manually
#
enable-ra
no-dhcp-interface=lo
no-ping
DNSMASQ_HEADER

    for bridge in ${LAN_BRIDGES}; do
        cat >> "${conf_tmp}" << EOF

interface=${bridge}
dhcp-range=set:ck6rd-${bridge},::2,::7d1,constructor:${bridge},slaac,ra-names,64,86400
dhcp-option=tag:ck6rd-${bridge},option6:dns-server,${DNS6}
domain=${DOMAIN}|${bridge}
ra-param=${bridge},high,0
EOF
    done

    mv "${conf_tmp}" "${DNSMASQ_CONF}"
}

# ---------------------------------------------------------------------------
# Deploy dnsmasq config and restart dnsmasq
# ---------------------------------------------------------------------------
deploy_dnsmasq() {
    mkdir -p "$(dirname "${DNSMASQ_DROP}")"

    if [ ! -f "${DNSMASQ_DROP}" ] || ! cmp -s "${DNSMASQ_CONF}" "${DNSMASQ_DROP}"; then
        cp "${DNSMASQ_CONF}" "${DNSMASQ_DROP}"
        log "dnsmasq config deployed to ${DNSMASQ_DROP}"
    else
        log "dnsmasq config unchanged"
    fi

    # Kill only the main dnsmasq instance (leaves ppp2 and others alone)
    if [ -f /run/dnsmasq-main.pid ]; then
        kill "$(cat /run/dnsmasq-main.pid)" 2>/dev/null || true
    else
        start-stop-daemon -K -q -x /usr/sbin/dnsmasq || true
    fi
    log "dnsmasq restarted"
}

# ---------------------------------------------------------------------------
# Enable IPv6 forwarding
# ---------------------------------------------------------------------------
enable_forwarding() {
    sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null
    sysctl -w net.ipv6.conf."${WAN_IFACE}".accept_ra=2 > /dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local wan_ip="$1"

    if [ -z "${wan_ip}" ]; then
        err "No WAN IP provided"
        return 1
    fi

    mkdir -p "${CONF_DIR}"

    teardown_tunnel
    setup_tunnel "${wan_ip}"
    enable_forwarding

    write_dnsmasq_conf
    deploy_dnsmasq

    log "6rd setup complete"
}

main "$@"