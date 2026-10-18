#!/bin/bash
# adb-forwarder-connect.sh
# GENERIC LOGIC ONLY - no site-specific values live in this file. This is
# what auto-update replaces. All site-specific values (SSID, device IP,
# etc.) live in /etc/adb-forwarder/config.env, which auto-update never
# touches.
#
# Waits for TARGET_SSID (or, while it is off, any other Control Hub this
# bridge has a profile for) to appear, joins it, connects adb to
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

# Every NetworkManager Wi-Fi profile bound to the robot adapter is a known
# Control Hub: the configured one (TARGET_SSID) plus any hub set up earlier by
# install.sh or change-robot-wifi.sh. When the configured hub is off, the
# watchdog falls back to whichever known hub is in range - every Control Hub
# serves adb at the same DEVICE_IP, so laptops do not notice the switch.
# Profiles are handled by UUID throughout, which never needs escaping.

target_hub_uuid() {
    nmcli -g connection.uuid connection show id "$TARGET_SSID" 2>/dev/null | head -n 1
}

# Known hub UUIDs, configured hub first so it is preferred when several are
# in range.
known_hub_uuids() {
    local target uuid type
    target="$(target_hub_uuid)"
    [ -n "$target" ] && echo "$target"
    while IFS=: read -r uuid type; do
        [ "$type" = "802-11-wireless" ] || continue
        [ "$uuid" = "$target" ] && continue
        if [ "$(nmcli -g connection.interface-name connection show uuid "$uuid" 2>/dev/null)" = "$WIFI_IFACE" ]; then
            echo "$uuid"
        fi
    done < <(nmcli -t -f UUID,TYPE connection show 2>/dev/null)
}

hub_ssid() {
    nmcli --escape no -g 802-11-wireless.ssid connection show uuid "$1" 2>/dev/null
}

# "configured hub X" or "fallback hub Y", for log lines.
describe_hub() {
    local ssid
    ssid="$(hub_ssid "$1")"
    if [ "$1" = "$(target_hub_uuid)" ]; then
        echo "configured hub $ssid"
    else
        echo "fallback hub $ssid"
    fi
}

# UUID of the known hub the robot adapter is fully connected to, or nothing.
# A connection to anything else on the adapter does not count.
current_hub_uuid() {
    local uuid
    uuid="$(nmcli -t -f UUID,DEVICE,STATE connection show --active 2>/dev/null \
        | awk -F: -v d="$WIFI_IFACE" '$2 == d && $3 == "activated" { print $1; exit }')"
    [ -n "$uuid" ] || return 1
    known_hub_uuids | grep -Fxq "$uuid" || return 1
    echo "$uuid"
}

# Scan until a known hub is broadcasting, then set PICKED_HUB to its UUID: the
# configured hub if it is visible, otherwise the first visible fallback. Uses a
# global instead of stdout because log() also writes to stdout.
PICKED_HUB=""
wait_for_known_hub() {
    log "Scanning on ${WIFI_IFACE} for $TARGET_SSID or another known Control Hub..."
    local waited=0 relog=0 visible uuid ssid
    while true; do
        PICKED_HUB=""
        # Exact line match against SSIDs, so one hub's name being a prefix of
        # another's (e.g. "6165-RC" and "6165-RC-B") cannot cause a false hit.
        visible="$(nmcli --escape no -g SSID dev wifi list ifname "$WIFI_IFACE" 2>/dev/null)"
        if [ -n "$visible" ]; then
            while read -r uuid; do
                ssid="$(hub_ssid "$uuid")"
                if [ -n "$ssid" ] && printf '%s\n' "$visible" | grep -Fxq -- "$ssid"; then
                    PICKED_HUB="$uuid"
                    break
                fi
            done < <(known_hub_uuids)
        fi
        [ -n "$PICKED_HUB" ] && break

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
            log "Still scanning for $TARGET_SSID or another known Control Hub (${waited}s). Control Hub powered on?"
        fi

        if [ "$waited" -ge "$SCAN_TIMEOUT" ]; then
            log "ERROR: no known Control Hub visible after ${waited}s."
            if ! iface_is_managed; then
                log "ERROR: root cause is that ${WIFI_IFACE} is unmanaged by NetworkManager."
            elif [ -z "$(known_hub_uuids)" ]; then
                log "ERROR: there is no Wi-Fi profile for ${WIFI_IFACE} at all. Re-run bridge/change-robot-wifi.sh."
            else
                log "ERROR: the interface is managed, so no known Control Hub's Wi-Fi is broadcasting."
                log "ERROR: check a Control Hub is powered on and not joined to another laptop."
            fi
            log "ERROR: retrying from scratch."
            return 1
        fi
    done
    log "$(describe_hub "$PICKED_HUB") is visible after ${waited}s."
    return 0
}

join_hub() {
    local desc out
    desc="$(describe_hub "$1")"
    log "Joining ${desc}..."
    # Capture the result so a failure is reported as a failure. Previously this
    # was tee'd straight to the log with no status check, so a rejected join
    # looked identical to a successful one followed by silence.
    if out="$(nmcli connection up uuid "$1" ifname "$WIFI_IFACE" 2>&1)"; then
        printf '%s\n' "$out" | tee -a "$LOG_FILE"
        log "Joined ${desc}."
        return 0
    fi
    printf '%s\n' "$out" | tee -a "$LOG_FILE"
    log "ERROR: nmcli could not activate ${desc} on ${WIFI_IFACE}."
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

wait_for_adb_server

log "Watchdog running: will keep ${WIFI_IFACE} on $TARGET_SSID (or another known Control Hub while it is off) and adb attached to $DEVICE_IP:$DEVICE_PORT."

last_hub=""
while true; do
    hub="$(current_hub_uuid)"
    if [ -z "$hub" ]; then
        log "Not currently joined to any known Control Hub."
        # wait_for_known_hub returns non-zero on timeout, but we deliberately
        # keep looping rather than exiting: the Control Hubs may simply be off
        # right now and should be picked up whenever one powers back on. The
        # point is that the failure is now visible in the log instead of silent.
        if wait_for_known_hub; then
            join_hub "$PICKED_HUB" || true
        fi
        sleep 3
        hub="$(current_hub_uuid)"
        [ -z "$hub" ] && last_hub=""
    fi
    # Being on a fallback hub counts as healthy: the watchdog does not pull
    # the adapter back to the configured hub when it reappears, since that
    # would cut off whoever is using the fallback robot. It returns to the
    # configured hub the next time the fallback drops.
    if [ -n "$hub" ] && [ "$hub" != "$last_hub" ]; then
        log "Now on $(describe_hub "$hub")."
        last_hub="$hub"
    fi
    if ! is_adb_alive; then
        connect_adb || true
    else
        # Only log a healthy tick occasionally, not every 5 seconds, or the log
        # becomes unreadable and grows without bound.
        tick=$((tick + 1))
        if [ "$tick" -ge "$HEALTHY_LOG_EVERY" ]; then
            tick=0
            log "Healthy: on $(describe_hub "$last_hub"), adb attached to $DEVICE_IP:$DEVICE_PORT."
        fi
    fi
    sleep "$CHECK_INTERVAL"
done
