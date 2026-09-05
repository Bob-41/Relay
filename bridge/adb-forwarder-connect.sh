#!/bin/bash
# adb-forwarder-connect.sh
# GENERIC LOGIC ONLY - no site-specific values live in this file. This is
# what auto-update replaces. All site-specific values (SSID, device IP,
# etc.) live in /etc/adb-forwarder/config.env, which auto-update never
# touches.
#
# Waits for TARGET_SSID to appear, joins it, connects adb to
# DEVICE_IP:DEVICE_PORT. Loops forever so it self-heals after device
# power-cycles or this host reboots.

CONFIG_FILE="/etc/adb-forwarder/config.env"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "FATAL: $CONFIG_FILE not found. Run install.sh (not --auto) first." >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${TARGET_SSID:?config.env missing TARGET_SSID}"
: "${DEVICE_IP:?config.env missing DEVICE_IP}"
: "${DEVICE_PORT:?config.env missing DEVICE_PORT}"
: "${WIFI_IFACE:?config.env missing WIFI_IFACE}"
: "${ADB_PORT:?config.env missing ADB_PORT}"
: "${LOG_FILE:?config.env missing LOG_FILE}"

CHECK_INTERVAL=5

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

wait_for_adb_server() {
    log "Waiting for local adb-server.service to bind port $ADB_PORT..."
    local timeout=30
    while ! ss -ltn 2>/dev/null | grep -q ":${ADB_PORT} "; do
        sleep 0.5
        timeout=$((timeout - 1))
        if [ "$timeout" -le 0 ]; then
            log "ERROR: adb-server.service never bound $ADB_PORT, exiting."
            exit 1
        fi
    done
    log "adb-server.service is up."
}

wait_for_ssid() {
    log "Scanning for $TARGET_SSID..."
    while ! nmcli -f SSID dev wifi list ifname "$WIFI_IFACE" | grep -qF "$TARGET_SSID"; do
        sleep "$CHECK_INTERVAL"
    done
    log "$TARGET_SSID is visible."
}

join_ssid() {
    log "Joining $TARGET_SSID..."
    nmcli connection up "$TARGET_SSID" ifname "$WIFI_IFACE" 2>&1 | tee -a "$LOG_FILE"
}

connect_adb() {
    log "Connecting adb to $DEVICE_IP:$DEVICE_PORT..."
    adb -H 127.0.0.1 -P "$ADB_PORT" connect "$DEVICE_IP:$DEVICE_PORT"
}

is_adb_alive() {
    adb -H 127.0.0.1 -P "$ADB_PORT" -s "$DEVICE_IP:$DEVICE_PORT" get-state >/dev/null 2>&1
}

is_wifi_connected() {
    # Compare fields exactly (awk, not grep) so TARGET_SSID is never
    # interpreted as a regex.
    nmcli -t -f active,ssid dev wifi list ifname "$WIFI_IFACE" | \
        awk -F: -v ssid="$TARGET_SSID" '$1=="yes" && $2==ssid {found=1} END {exit !found}'
}

wait_for_adb_server

while true; do
    if ! is_wifi_connected; then
        wait_for_ssid
        join_ssid
        sleep 3
    fi
    if ! is_adb_alive; then
        connect_adb
    fi
    sleep "$CHECK_INTERVAL"
done
