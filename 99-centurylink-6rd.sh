#!/bin/bash
# 99-centurylink-6rd.sh
# UniFi OS on_boot.d hook — runs at boot, waits for WAN_IFACE, sets up 6rd tunnel,
# then monitors for WAN IP changes and re-configures the tunnel if they occur.
#
# Install:
#   cp 99-centurylink-6rd.sh /data/on_boot.d/
#   cp centurylink-6rd-setup.sh /data/centurylink-6rd/
#   chmod +x /data/on_boot.d/99-centurylink-6rd.sh
#   chmod +x /data/centurylink-6rd/centurylink-6rd-setup.sh

set -eo pipefail

WAN_IFACE="ppp0"
SETUP_SCRIPT="/data/centurylink-6rd/centurylink-6rd-setup.sh"
STATE_FILE="/run/centurylink-6rd.wan-ip"
WATCHDOG_INTERVAL=60   # seconds between IP change checks
BOOT_WAIT_TIMEOUT=120  # seconds to wait for WAN_IFACE on boot
BOOT_WAIT_INTERVAL=5

log()  { echo "[6rd-boot] $*" >&2; }
err()  { echo "[6rd-boot] ERROR: $*" >&2; }
warn() { echo "[6rd-boot] WARNING: $*" >&2; }

# ---------------------------------------------------------------------------
# Get the current IPv4 address on the WAN interface, if any
# ---------------------------------------------------------------------------
get_wan_ip() {
    ip -4 addr show dev "${WAN_IFACE}" 2>/dev/null \
        | awk '/inet / { split($2, a, "/"); print a[1]; exit }'
}

# ---------------------------------------------------------------------------
# Wait for WAN interface to come up with an IPv4 address
# Returns 0 and prints IP on success, 1 on timeout
# ---------------------------------------------------------------------------
wait_for_wan() {
    local elapsed=0
    local wan_ip

    log "Waiting for ${WAN_IFACE} to come up (timeout: ${BOOT_WAIT_TIMEOUT}s)"

    while [ "${elapsed}" -lt "${BOOT_WAIT_TIMEOUT}" ]; do
        wan_ip=$(get_wan_ip)
        if [ -n "${wan_ip}" ]; then
            log "${WAN_IFACE} is up: ${wan_ip}"
            echo "${wan_ip}"
            return 0
        fi
        sleep "${BOOT_WAIT_INTERVAL}"
        elapsed=$((elapsed + BOOT_WAIT_INTERVAL))
    done

    err "Timed out waiting for ${WAN_IFACE}"
    return 1
}

# ---------------------------------------------------------------------------
# Run setup script with the given WAN IP; record it on success
# ---------------------------------------------------------------------------
run_setup() {
    local wan_ip="$1"

    if [ ! -x "${SETUP_SCRIPT}" ]; then
        err "Setup script not found or not executable: ${SETUP_SCRIPT}"
        return 1
    fi

    if "${SETUP_SCRIPT}" "${wan_ip}"; then
        echo "${wan_ip}" > "${STATE_FILE}"
        log "Setup succeeded for IP ${wan_ip}"
    else
        err "Setup script failed for IP ${wan_ip}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Watchdog loop — polls WAN IP every WATCHDOG_INTERVAL seconds
# Re-runs setup if the IP changes (PPPoE session renewal)
# ---------------------------------------------------------------------------
watchdog_loop() {
    log "Starting watchdog (interval: ${WATCHDOG_INTERVAL}s)"

    while true; do
        sleep "${WATCHDOG_INTERVAL}"

        local current_ip
        current_ip=$(get_wan_ip)

        if [ -z "${current_ip}" ]; then
            warn "${WAN_IFACE} has no IP — interface may have dropped"
            continue
        fi

        local last_ip
        last_ip=$(cat "${STATE_FILE}" 2>/dev/null || echo "")

        if [ "${current_ip}" != "${last_ip}" ]; then
            log "WAN IP changed: ${last_ip:-none} -> ${current_ip}"
            run_setup "${current_ip}" || warn "Re-setup failed; will retry next cycle"
        fi
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log "Starting CenturyLink 6rd configuration"

    # Wait for WAN_IFACE to come up with an IPv4
    local wan_ip
    wan_ip=$(wait_for_wan) || {
        err "Cannot proceed without WAN IP — exiting"
        exit 1
    }

    # Initial setup
    run_setup "${wan_ip}"

    # Warn if UniFi's own DHCPv6 client is somehow active
    if pgrep -x odhcp6c > /dev/null 2>&1; then
        warn "odhcp6c is running. Disable WAN DHCPv6 in the UniFi UI to avoid conflicts."
    fi

    # Drop into watchdog — this script runs in the background via on_boot.d
    # so staying alive is intentional
    watchdog_loop
}

main "$@"
