#!/usr/bin/env bash
# change-robot-wifi.sh (bridge side)
# Points an already-installed bridge at a different Control Hub Wi-Fi (or the
# same network with a new password). Asks only for the SSID and password;
# everything else install.sh set up - user, Wi-Fi adapter, adb port, reach
# address (Tailscale / static IP), services, updater - is left as it is.
#
# install.sh copies this to /usr/local/bin/adb-forwarder-change-wifi.sh and the
# nightly updater refreshes that copy, so an updated bridge can run:
#   sudo adb-forwarder-change-wifi.sh
# Running it from a fresh clone works too:
#   sudo bash change-robot-wifi.sh

set -euo pipefail

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    BOLD="$(tput bold)"
    CYAN="$(tput setaf 6)"
    YELLOW="$(tput setaf 3)"
    RED="$(tput setaf 1)"
    RESET="$(tput sgr0)"
else
    BOLD=""
    CYAN=""
    YELLOW=""
    RED=""
    RESET=""
fi

section() { printf '\n%s%s%s\n' "${BOLD}${CYAN}" "$1" "$RESET"; }
important() { printf '%s%s%s\n' "${BOLD}${YELLOW}" "$1" "$RESET"; }
warning() { printf '%sWARNING: %s%s\n' "${BOLD}${RED}" "$1" "$RESET"; }

if [ "$EUID" -ne 0 ]; then
    warning "Run this with sudo."
    exit 1
fi

CONFIG_FILE="/etc/adb-forwarder/config.env"
if [ ! -f "$CONFIG_FILE" ]; then
    warning "${CONFIG_FILE} not found. Run install.sh first - this script only changes an existing setup."
    exit 1
fi
if ! command -v nmcli >/dev/null 2>&1; then
    warning "nmcli not found. Is NetworkManager installed?"
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"
: "${TARGET_SSID:?config.env missing TARGET_SSID}"
: "${WIFI_IFACE:?config.env missing WIFI_IFACE}"
: "${SERVICE_USER:?config.env missing SERVICE_USER}"
LOG_FILE="${LOG_FILE:-/var/log/adb-forwarder.log}"
OLD_SSID="$TARGET_SSID"

section "=== Change robot Wi-Fi ==="
echo "Current robot Wi-Fi: ${OLD_SSID} (adapter ${WIFI_IFACE})"
read -rp "New robot wifi SSID [${OLD_SSID}]: " NEW_SSID
NEW_SSID="${NEW_SSID:-$OLD_SSID}"
read -rp "Robot wifi password (shown as you type; blank if open): " WIFI_PASS
# Same check as install.sh: nmcli rejects WPA-PSK passphrases outside 8-63
# characters with an unhelpful "property is invalid" error.
if [ -n "$WIFI_PASS" ] && { [ "${#WIFI_PASS}" -lt 8 ] || [ "${#WIFI_PASS}" -gt 63 ]; }; then
    warning "WiFi password must be 8-63 characters for WPA-PSK (got ${#WIFI_PASS}). Nothing was changed."
    exit 1
fi

active_uuid_on_iface() {
    nmcli -t -f UUID,DEVICE,STATE connection show --active 2>/dev/null \
        | awk -F: -v d="$WIFI_IFACE" '$2 == d && $3 == "activated" { print $1; exit }' || true
}

profile_uuid() {
    nmcli -g connection.uuid connection show id "$1" 2>/dev/null | head -n 1 || true
}

route_dev_for() {
    ip route get "$1" 2>/dev/null \
        | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

TARGET_UUID="$(profile_uuid "$OLD_SSID")"
ACTIVE_UUID="$(active_uuid_on_iface)"
ACTIVE_NAME=""
if [ -n "$ACTIVE_UUID" ]; then
    ACTIVE_NAME="$(nmcli -g connection.id connection show uuid "$ACTIVE_UUID" 2>/dev/null | head -n 1 || true)"
fi

# Refuse to quietly take down the network this machine is using. The robot
# adapter is normally dedicated, but the installer allows a single-radio
# override and a hand-fixed bridge may have an uplink profile bound to the same
# adapter. Disconnecting that would drop Tailscale/SSH with no way back in.
REASONS=()
DEFAULT_DEV="$(route_dev_for 1.1.1.1)"
SESSION_DEV=""
SSH_PEER="${SSH_CONNECTION:-}"
SSH_PEER="${SSH_PEER%% *}"
# sudo drops SSH_CONNECTION by default; fall back to this terminal's login
# record, which ends in "(<peer address>)" for an SSH session.
if [ -z "$SSH_PEER" ]; then
    SSH_PEER="$(who -m 2>/dev/null | sed -n 's/.*(\([^)]*\)).*/\1/p' | head -n 1 || true)"
fi
[ -n "$SSH_PEER" ] && SESSION_DEV="$(route_dev_for "$SSH_PEER")"
[ "$DEFAULT_DEV" = "$WIFI_IFACE" ] && REASONS+=("the default route runs over ${WIFI_IFACE}")
[ "$SESSION_DEV" = "$WIFI_IFACE" ] && REASONS+=("this SSH session runs over ${WIFI_IFACE}")
# Any Wi-Fi profile bound to the robot adapter is a known Control Hub (the
# watchdog falls back to them), so being on one of those is expected. Only an
# active connection that is not bound to this adapter counts as another network.
ACTIVE_IFACE_BINDING=""
if [ -n "$ACTIVE_UUID" ]; then
    ACTIVE_IFACE_BINDING="$(nmcli -g connection.interface-name connection show uuid "$ACTIVE_UUID" 2>/dev/null | head -n 1 || true)"
fi
if [ -n "$ACTIVE_UUID" ] && [ "$ACTIVE_UUID" != "$TARGET_UUID" ] && [ "$ACTIVE_IFACE_BINDING" != "$WIFI_IFACE" ]; then
    REASONS+=("${WIFI_IFACE} is currently connected to '${ACTIVE_NAME:-$ACTIVE_UUID}', not the robot Wi-Fi '${OLD_SSID}'")
fi
if [ "${#REASONS[@]}" -gt 0 ]; then
    warning "${WIFI_IFACE} is carrying another network:"
    for reason in "${REASONS[@]}"; do
        echo "  - ${reason}"
    done
    echo "Changing the robot profile will disconnect it, which can drop remote access."
    echo "Move the uplink to another adapter first, or type DEV to continue anyway."
    echo "Anything else aborts:"
    read -rp "> " NET_OVERRIDE
    if [ "$NET_OVERRIDE" != "DEV" ]; then
        echo "Aborting."
        exit 1
    fi
    important "Continuing: remote access may not survive the change."
fi

# NetworkManager profile names are global, so a profile with the new name may
# already belong to another adapter. Moving it here would silently steal that
# network's credentials/settings.
if nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq -- "$NEW_SSID"; then
    EXISTING_IFACE="$(nmcli -g connection.interface-name connection show id "$NEW_SSID" 2>/dev/null | head -n 1 || true)"
    if [ -n "$EXISTING_IFACE" ] && [ "$EXISTING_IFACE" != "$WIFI_IFACE" ]; then
        warning "A profile named '${NEW_SSID}' already exists on ${EXISTING_IFACE}."
        warning "Using it here would move that profile to ${WIFI_IFACE} and break its network."
        echo "Pick a different SSID, or type DEV to continue anyway:"
        read -rp "> " NAME_OVERRIDE
        if [ "$NAME_OVERRIDE" != "DEV" ]; then
            echo "Aborting."
            exit 1
        fi
    fi
fi

# Stop the watchdog first so it does not try to rejoin the old network while
# the profile is being rewritten. It reads config.env only at startup, so it
# has to be restarted afterwards anyway to pick up the new SSID.
# Restart it on every exit path. Without this, a failure after the
# stop below leaves the bridge with no watchdog until someone notices.
TMP_CONFIG=""
cleanup() {
    [ -n "$TMP_CONFIG" ] && rm -f "$TMP_CONFIG"
    systemctl start adb-forwarder-connect.service >/dev/null 2>&1 || true
}
trap cleanup EXIT

systemctl stop adb-forwarder-connect.service 2>/dev/null || true

echo "Configuring NetworkManager profile for ${NEW_SSID}..."
if nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq -- "$NEW_SSID"; then
    echo "Existing profile found, updating."
else
    nmcli connection add type wifi con-name "$NEW_SSID" ifname "$WIFI_IFACE" ssid "$NEW_SSID"
fi
if [ -n "$WIFI_PASS" ]; then
    nmcli connection modify id "$NEW_SSID" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PASS"
else
    nmcli connection modify id "$NEW_SSID" wifi-sec.key-mgmt none
fi
# never-default is not optional: the Control Hub's DHCP gateway would otherwise
# be able to take this host's default route and knock Tailscale/SSH offline.
# install.sh enforces this on the target profile; the change script must too.
nmcli connection modify id "$NEW_SSID" \
    connection.interface-name "$WIFI_IFACE" \
    connection.autoconnect yes \
    ipv4.never-default yes \
    ipv6.never-default yes

# Keep the other hubs' profiles: the watchdog falls back to any of them while
# the new hub is off, and switching back is just a re-run. But stop
# NetworkManager from auto-joining them itself, or it could pick a fallback
# hub even while the new one is in range. Matched by adapter rather than by
# name, so profiles from earlier install.sh runs or that NetworkManager named
# itself are covered too.
NEW_UUID="$(profile_uuid "$NEW_SSID")"
while IFS=: read -r uuid type; do
    [ "$type" = "802-11-wireless" ] || continue
    [ "$uuid" = "$NEW_UUID" ] && continue
    [ "$(nmcli -g connection.interface-name connection show uuid "$uuid")" = "$WIFI_IFACE" ] || continue
    nmcli connection modify uuid "$uuid" connection.autoconnect no
    echo "Kept $(nmcli --escape no -g 802-11-wireless.ssid connection show uuid "$uuid") as a fallback hub, auto-connect turned off."
done < <(nmcli -t -f UUID,TYPE connection show)

# Rewrite only TARGET_SSID in config.env; every other line is kept verbatim.
# The password is never written here - NetworkManager keeps it in its own
# root-only keyfile, same as install.sh. The file stays root-owned and
# group-readable: root sources it on every --auto update, so the service
# account must not be able to write shell into it.
TMP_CONFIG="$(mktemp)"
grep -v '^TARGET_SSID=' "$CONFIG_FILE" > "$TMP_CONFIG" || true
printf 'TARGET_SSID=%q\n' "$NEW_SSID" >> "$TMP_CONFIG"
CONFIG_GROUP="$(id -gn "$SERVICE_USER" 2>/dev/null || echo root)"
install -m 640 -o root -g "$CONFIG_GROUP" "$TMP_CONFIG" "$CONFIG_FILE"
rm -f "$TMP_CONFIG"
TMP_CONFIG=""

# Cosmetic: the unit's description names the SSID. The nightly update
# regenerates it from config.env too; this just keeps it right until then.
UNIT_FILE="/etc/systemd/system/adb-forwarder-connect.service"
if [ -f "$UNIT_FILE" ]; then
    awk -v ssid="$NEW_SSID" '
        /^Description=/ { print "Description=Keep this host connected to " ssid " and the device over adb"; next }
        { print }
    ' "$UNIT_FILE" > "${UNIT_FILE}.tmp" && mv "${UNIT_FILE}.tmp" "$UNIT_FILE"
    systemctl daemon-reload
fi

# Drop the robot adapter's current association so the watchdog does a fresh
# join with the new settings (this matters when only the password changed).
# Only the robot adapter is touched; the bridge's other network stays up.
nmcli device disconnect "$WIFI_IFACE" >/dev/null 2>&1 || true
systemctl start adb-forwarder-connect.service
trap - EXIT

section "=== Verifying ==="
echo "Waiting up to 60 seconds for the bridge to join ${NEW_SSID}..."
joined=0
for _ in $(seq 1 30); do
    if [ -n "$NEW_UUID" ] && [ "$(active_uuid_on_iface)" = "$NEW_UUID" ]; then
        joined=1
        break
    fi
    sleep 2
done

if [ "$joined" = "1" ]; then
    important "Joined ${NEW_SSID}. The Control Hub should reappear on laptops within a few seconds."
else
    warning "Not joined to ${NEW_SSID} yet."
    echo "If the Control Hub is off, that's expected - the bridge keeps trying and joins once it's on."
    echo "Until then it may sit on another known hub (the log says \"Now on fallback hub ...\"),"
    echo "and it stays there until that hub goes off, so it never cuts off a robot in use."
    echo "Otherwise check the SSID and password and re-run this script. Recent log:"
    tail -n 10 "$LOG_FILE" 2>/dev/null || true
fi
echo ""
echo "Logs: ${LOG_FILE}  |  journalctl -u adb-forwarder-connect.service"
echo "Laptops do not need any changes."
