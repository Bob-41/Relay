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
# How long to keep scanning for the SSID before saying so out loud. The old
# behaviour was an infinite silent loop: one "Scanning for..." line at boot and
# nothing since, forever. That is what made the unmanaged-interface failure on
# a netplan host invisible - systemd showed the service active while nothing
# could ever succeed. A stuck scan is now loud and explains itself.
SCAN_TIMEOUT=120
# Re-log the scan at this interval so a long wait is visibly progressing
# rather than looking identical to a hang.
SCAN_RELOG_EVERY=30
# Log a healthy heartbeat every N ticks (N * CHECK_INTERVAL seconds). Without
# this the log is silent while healthy, which is fine until you need to prove
# it was NOT silent - e.g. distinguishing "working" from "stuck".
HEALTHY_LOG_EVERY=720   # ~1 hour at CHECK_INTERVAL=5
tick=0

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Explain the most common reason a scan can never succeed, instead of letting
# the loop retry a setup that will never work. NetworkManager leaves a device
# unmanaged when another renderer (e.g. netplan) claims it without listing it;
# nmcli will still happily create a connection profile for it, but that profile
# can never activate. Detected here so the log names the actual cause.
iface_is_managed() {
    # nmcli general status prints "GENERAL.STATE" per device; a managed device
    # reports "connected"/"connecting"/"disconnected"/"unavailable". An
    # unmanaged device is simply absent from that list.
    nmcli -t -f DEVICE,STATE device status 2>/dev/null \
        | awk -F: -v d="$WIFI_IFACE" '$1 == d { found = 1 } END { exit !found }'
}

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
    log "Scanning for $TARGET_SSID on ${WIFI_IFACE}..."
    local waited=0 relog=0
    while ! nmcli -f SSID dev wifi list ifname "$WIFI_IFACE" 2>/dev/null | grep -qF "$TARGET_SSID"; do
        sleep "$CHECK_INTERVAL"
        waited=$((waited + CHECK_INTERVAL))
        relog=$((relog + CHECK_INTERVAL))

        if [ "$relog" -ge "$SCAN_RELOG_EVERY" ]; then
            relog=0
            # Name the likely cause while we still can. Doing this on the first
            # failure rather than at timeout means the operator reading the log
            # at 2am gets the diagnosis, not just a countdown.
            if ! iface_is_managed; then
                log "WARNING: ${WIFI_IFACE} is NOT managed by NetworkManager, so no scan can ever succeed."
                log "WARNING: a connection profile can be created for it but can never activate."
                log "WARNING: fix with a netplan drop-in, then re-run bridge/install.sh:"
                log "WARNING:   wifis: ${WIFI_IFACE}: {renderer: NetworkManager}   &&   sudo netplan apply"
                log "WARNING: do that from a local console, not over SSH on this interface - it drops the lease."
            fi
            log "Still scanning for $TARGET_SSID (${waited}s). Control Hub powered on?"
        fi

        if [ "$waited" -ge "$SCAN_TIMEOUT" ]; then
            log "ERROR: $TARGET_SSID not visible after ${waited}s."
            if ! iface_is_managed; then
                log "ERROR: root cause is that ${WIFI_IFACE} is unmanaged by NetworkManager."
            else
                log "ERROR: the interface is managed, so the Control Hub's Wi-Fi is genuinely not broadcasting."
                log "ERROR: check the Control Hub is powered on and not joined to another laptop."
            fi
            log "ERROR: retrying from scratch."
            return 1
        fi
    done
    log "$TARGET_SSID is visible after ${waited}s."
    return 0
}

join_ssid() {
    log "Joining $TARGET_SSID..."
    # Capture the result so a failure is reported as a failure. Previously this
    # was tee'd straight to the log with no status check, so a rejected join
    # looked identical to a successful one followed by silence.
    local out
    if out="$(nmcli connection up "$TARGET_SSID" ifname "$WIFI_IFACE" 2>&1)"; then
        printf '%s\n' "$out" | tee -a "$LOG_FILE"
        log "Joined $TARGET_SSID."
        return 0
    fi
    printf '%s\n' "$out" | tee -a "$LOG_FILE"
    log "ERROR: nmcli could not activate $TARGET_SSID on ${WIFI_IFACE}."
    if ! iface_is_managed; then
        log "ERROR: ${WIFI_IFACE} is unmanaged by NetworkManager - the profile can never activate."
    else
        log "ERROR: interface is managed. Common causes: wrong Wi-Fi password saved in the profile,"
        log "ERROR: or the adapter does not support the Control Hub's band (5 GHz needs a 5 GHz radio)."
    fi
    return 1
}

connect_adb() {
    log "Connecting adb to $DEVICE_IP:$DEVICE_PORT..."
    # Report the actual result. adb prints "connected to..." or a failure to
    # stdout; without checking, a refused connection was previously invisible.
    local out
    if out="$(adb -H 127.0.0.1 -P "$ADB_PORT" connect "$DEVICE_IP:$DEVICE_PORT" 2>&1)"; then
        printf '%s\n' "$out" | tee -a "$LOG_FILE"
        if printf '%s' "$out" | grep -qi 'connected'; then
            log "adb connected to $DEVICE_IP:$DEVICE_PORT."
            return 0
        fi
        log "WARNING: adb connect returned without an error but not 'connected': $out"
        return 1
    fi
    printf '%s\n' "$out" | tee -a "$LOG_FILE"
    # Almost always means the join above did not actually take, so this is
    # usually a Wi-Fi symptom wearing an adb costume.
    log "ERROR: adb could not reach $DEVICE_IP:$DEVICE_PORT. Check the Wi-Fi join above."
    return 1
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

log "Watchdog running: will keep ${WIFI_IFACE} joined to $TARGET_SSID and adb attached to $DEVICE_IP:$DEVICE_PORT."

while true; do
    if ! is_wifi_connected; then
        log "Not currently joined to $TARGET_SSID."
        # wait_for_ssid returns non-zero on timeout, but we deliberately keep
        # looping rather than exiting: the Control Hub may simply be off right
        # now and should be picked up whenever it powers back on. The point is
        # that the failure is now visible in the log instead of silent.
        wait_for_ssid || true
        join_ssid || true
        sleep 3
    fi
    if ! is_adb_alive; then
        connect_adb || true
    else
        # Only log a healthy tick occasionally, not every 5 seconds, or the log
        # becomes unreadable and grows without bound.
        tick=$((tick + 1))
        if [ "$tick" -ge "$HEALTHY_LOG_EVERY" ]; then
            tick=0
            log "Healthy: joined to $TARGET_SSID, adb attached to $DEVICE_IP:$DEVICE_PORT."
        fi
    fi
    sleep "$CHECK_INTERVAL"
done
