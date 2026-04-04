#!/bin/bash
# centurylink-6rd-watchdog.sh
# Monitors WAN IP changes and re-runs 6rd setup if the IP changes.
# Launched by 99-centurylink-6rd.sh via nohup on boot. Do not run directly.

WAN_IFACE="ppp0"
SETUP_SCRIPT="/data/centurylink-6rd/centurylink-6rd-setup.sh"
STATE_FILE="/run/centurylink-6rd.wan-ip"
WATCHDOG_INTERVAL=60

log()  { echo "[6rd-watchdog] $*"; }
err()  { echo "[6rd-watchdog] ERROR: $*"; }
warn() { echo "[6rd-watchdog] WARNING: $*"; }

get_wan_ip() {
    ip -4 addr show dev "${WAN_IFACE}" 2>/dev/null \
        | awk '/inet / { split($2, a, "/"); print a[1]; exit }'
}

log "Watchdog started (interval: ${WATCHDOG_INTERVAL}s)"

while true; do
    sleep "${WATCHDOG_INTERVAL}"

    current_ip=$(get_wan_ip)

    if [ -z "${current_ip}" ]; then
        warn "${WAN_IFACE} has no IP — interface may have dropped"
        continue
    fi

    last_ip=$(cat "${STATE_FILE}" 2>/dev/null || true)

    if [ "${current_ip}" != "${last_ip}" ]; then
        log "WAN IP changed: ${last_ip:-none} -> ${current_ip}"
        if "${SETUP_SCRIPT}" "${current_ip}"; then
            echo "${current_ip}" > "${STATE_FILE}"
            log "Re-setup succeeded for IP ${current_ip}"
        else
            err "Re-setup failed for IP ${current_ip} — will retry next cycle"
        fi
    fi
done
