#!/bin/bash
# 99-centurylink-6rd.sh
# UniFi OS on_boot.d hook — waits for WAN, runs initial 6rd setup, then
# launches the watchdog as a separate background process and exits.
#
# Install:
#   chmod +x /data/on_boot.d/99-centurylink-6rd.sh
#   chmod +x /data/centurylink-6rd/centurylink-6rd-setup.sh
#   chmod +x /data/centurylink-6rd/centurylink-6rd-watchdog.sh

set -eo pipefail

WAN_IFACE="ppp0"
SETUP_SCRIPT="/data/centurylink-6rd/centurylink-6rd-setup.sh"
WATCHDOG_SCRIPT="/data/centurylink-6rd/centurylink-6rd-watchdog.sh"
WATCHDOG_PIDFILE="/run/centurylink-6rd-watchdog.pid"
WATCHDOG_LOG="/var/log/centurylink-6rd-watchdog.log"
STATE_FILE="/run/centurylink-6rd.wan-ip"
BOOT_WAIT_TIMEOUT=120
BOOT_WAIT_INTERVAL=5

log()  { echo "[6rd-boot] $*" >&2; }
err()  { echo "[6rd-boot] ERROR: $*" >&2; }
warn() { echo "[6rd-boot] WARNING: $*" >&2; }

get_wan_ip() {
    ip -4 addr show dev "${WAN_IFACE}" 2>/dev/null \
        | awk '/inet / { split($2, a, "/"); print a[1]; exit }'
}

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
# Main
# ---------------------------------------------------------------------------
log "Starting CenturyLink 6rd configuration"

# If watchdog is already running, nothing to do
if [ -f "${WATCHDOG_PIDFILE}" ] && kill -0 "$(cat "${WATCHDOG_PIDFILE}")" 2>/dev/null; then
    log "Watchdog already running (pid $(cat "${WATCHDOG_PIDFILE}")), exiting"
    exit 0
fi

# Wait for WAN
wan_ip=$(wait_for_wan) || {
    err "Cannot proceed without WAN IP — exiting"
    exit 1
}

# Initial setup
if [ ! -x "${SETUP_SCRIPT}" ]; then
    err "Setup script not found or not executable: ${SETUP_SCRIPT}"
    exit 1
fi

if "${SETUP_SCRIPT}" "${wan_ip}"; then
    echo "${wan_ip}" > "${STATE_FILE}"
    log "Setup succeeded for IP ${wan_ip}"
else
    err "Setup script failed for IP ${wan_ip}"
    exit 1
fi

# Warn if UniFi's own DHCPv6 client is somehow active
if pgrep -x odhcp6c > /dev/null 2>&1; then
    warn "odhcp6c is running. Disable WAN DHCPv6 in the UniFi UI to avoid conflicts."
fi

# Launch watchdog as a completely independent process and exit
if [ ! -x "${WATCHDOG_SCRIPT}" ]; then
    err "Watchdog script not found or not executable: ${WATCHDOG_SCRIPT}"
    exit 1
fi

log "Launching watchdog"
nohup "${WATCHDOG_SCRIPT}" > "${WATCHDOG_LOG}" 2>&1 &
echo $! > "${WATCHDOG_PIDFILE}"
log "Watchdog launched (pid $(cat "${WATCHDOG_PIDFILE}")), log: ${WATCHDOG_LOG}"
