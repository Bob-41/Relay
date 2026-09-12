#!/usr/bin/env bash
# install.sh (bridge side)
# Interactive on first run (asks questions, saves them to
# /etc/adb-forwarder/config.env). Re-runnable non-interactively via --auto,
# which replays the saved config - this is what the nightly updater calls.
# Never re-prompts for or re-stores the WiFi password on --auto; the WiFi
# connection profile itself is left untouched on --auto runs entirely.
#
# Run WITH sudo. If the login shell here is fish, invoke explicitly:
#   sudo bash install.sh

set -euo pipefail

# Keep the installer easy to scan in a terminal, while leaving redirected logs
# as plain text without ANSI escape sequences.
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

AUTO=0
[ "${1:-}" = "--auto" ] && AUTO=1

if [ "$EUID" -ne 0 ]; then
    warning "Run this with sudo."
    exit 1
fi
if ! command -v iw >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        important "Installing iw so Relay can show Wi-Fi adapter band support..."
        apt-get install -y iw
    else
        warning "iw is required to show Wi-Fi adapter band support. Install it, then re-run this script."
        exit 1
    fi
fi
for bin in systemctl nmcli adb ss iw; do
    command -v "$bin" >/dev/null 2>&1 || { warning "$bin not found. Aborting."; exit 1; }
done

CONFIG_DIR="/etc/adb-forwarder"
CONFIG_FILE="${CONFIG_DIR}/config.env"
mkdir -p "$CONFIG_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG_SRC="${SCRIPT_DIR}/adb-forwarder-connect.sh"
SCRIPT_PATH="/usr/local/bin/adb-forwarder-connect.sh"

# Print a useful label next to each Wi-Fi interface so users do not have to
# guess which adapter is internal versus an external USB adapter.
describe_wifi_adapter() {
    local iface="$1" recommendation="${2:-}" props device_path bus vendor model label bands
    if command -v udevadm >/dev/null 2>&1; then
        props="$(udevadm info --query=property --path="/sys/class/net/${iface}" 2>/dev/null || true)"
    else
        props=""
    fi
    bus="$(awk -F= '$1 == "ID_BUS" { print $2; exit }' <<<"$props")"
    vendor="$(awk -F= '$1 == "ID_VENDOR_FROM_DATABASE" { print $2; exit }' <<<"$props")"
    model="$(awk -F= '$1 == "ID_MODEL_FROM_DATABASE" { print $2; exit }' <<<"$props")"

    # Some built-in radios do not expose ID_BUS through udev. Their sysfs
    # device path still identifies the physical bus reliably.
    device_path="$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null || true)"
    if [ -z "$bus" ]; then
        case "$device_path" in
            */usb*) bus="usb" ;;
            */mmc*|*/platform/*|*/pci*) bus="internal" ;;
        esac
    fi

    case "$bus" in
        usb) label="USB Wi-Fi adapter" ;;
        pci|platform|mmc|sdio|internal) label="internal Wi-Fi adapter" ;;
        *) label="Wi-Fi adapter" ;;
    esac
    bands="$(wifi_band_summary "$iface")"
    printf '  %s: %s%s%s (%s)%s\n' "$iface" "${vendor:+${vendor} }" "${model:+${model} }" "$label" "$bands" "$recommendation"
}

wifi_supports_frequency_range() {
    local iface="$1" min_mhz="$2" max_mhz="$3" phy
    phy="$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/ { print "phy" $2; exit }')"
    [ -n "$phy" ] || return 1
    iw phy "$phy" info 2>/dev/null | awk -v min="$min_mhz" -v max="$max_mhz" \
        '$2 >= min && $2 < max && $3 == "MHz" { found=1 } END { exit !found }'
}

wifi_band_summary() {
    local iface="$1" has_24=0 has_5=0
    wifi_supports_frequency_range "$iface" 2400 2500 && has_24=1
    wifi_supports_frequency_range "$iface" 4900 5925 && has_5=1
    case "${has_24}:${has_5}" in
        1:1) printf '2.4 GHz and 5 GHz' ;;
        1:0) printf '2.4 GHz only' ;;
        0:1) printf '5 GHz only' ;;
        *) printf 'band support unavailable' ;;
    esac
}

if [ "$AUTO" = "1" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "--auto requires an existing $CONFIG_FILE - run without --auto first."
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    section "=== ADB Bridge auto-update (replaying saved config) ==="
else
    section "=== ADB Bridge Setup ==="
    important "Text in [brackets] is the default answer. Press Enter to use it."
    important "If you are unsure, use the default. To start over, press Ctrl+C and run: sudo bash install.sh"
    DEFAULT_USER="${SUDO_USER:-}"
    read -rp "Non-root user to run the bridge services as [${DEFAULT_USER}]: " SERVICE_USER
    SERVICE_USER="${SERVICE_USER:-$DEFAULT_USER}"
    if [ -z "$SERVICE_USER" ] || ! id "$SERVICE_USER" >/dev/null 2>&1; then
        echo "No valid non-root user given/found. Aborting."
        exit 1
    fi

    section "=== How laptops reach this bridge ==="
    important "  1) Tailscale (recommended)"
    echo "  2) Static LAN IP"
    read -rp "Choice [1]: " REACH_CHOICE
    REACH_CHOICE="${REACH_CHOICE:-1}"
    REACH_IP=""

    if [ "$REACH_CHOICE" = "1" ]; then
        if ! command -v tailscale >/dev/null 2>&1; then
            read -rp "Tailscale not installed. Install via official script now? [y/N]: " DO_INSTALL
            if [ "$DO_INSTALL" = "y" ] || [ "$DO_INSTALL" = "Y" ]; then
                read -rp "Confirm - runs 'curl -fsSL https://tailscale.com/install.sh | sh' [y/N]: " CONFIRM_INSTALL
                if [ "$CONFIRM_INSTALL" = "y" ] || [ "$CONFIRM_INSTALL" = "Y" ]; then
                    curl -fsSL https://tailscale.com/install.sh | sh
                else
                    echo "Skipped. Aborting."; exit 1
                fi
            else
                echo "Aborting."; exit 1
            fi
        fi
        systemctl enable --now tailscaled >/dev/null 2>&1 || true
        if ! tailscale status >/dev/null 2>&1; then
            echo "Not logged into Tailscale. Follow the printed URL:"
            tailscale up
        fi
        REACH_IP="$(tailscale ip -4 2>/dev/null | head -n1)"
        [ -z "$REACH_IP" ] && echo "WARNING: could not read Tailscale IPv4 - check 'tailscale status' after."
    else
        nmcli -t -f DEVICE,TYPE device | awk -F: '$2!="loopback"{print "  "$1" ("$2")"}'
        read -rp "Uplink interface: " UPLINK_IFACE
        [ -z "$UPLINK_IFACE" ] && { echo "Aborting."; exit 1; }
        read -rp "Router already has a fixed DHCP reservation for this machine? (search that up if you don't know what it means) [y/N]: " HAS_RESERVATION
        if [ "$HAS_RESERVATION" = "y" ] || [ "$HAS_RESERVATION" = "Y" ]; then
            read -rp "That reserved IP: " REACH_IP
            [ -z "$REACH_IP" ] && { echo "Aborting."; exit 1; }
        else
            echo "This changes live network config on ${UPLINK_IFACE} - can drop an active SSH session."
            read -rp "Static IP: " STATIC_IP
            read -rp "Prefix length (e.g. 24): " STATIC_PREFIX
            read -rp "Gateway: " STATIC_GW
            read -rp "DNS: " STATIC_DNS
            [ -z "$STATIC_IP" ] || [ -z "$STATIC_PREFIX" ] || [ -z "$STATIC_GW" ] && { echo "Incomplete. Aborting."; exit 1; }
            UPLINK_CONN="$(nmcli -t -f DEVICE,CONNECTION device | awk -F: -v d="$UPLINK_IFACE" '$1==d{print $2}')"
            [ -z "$UPLINK_CONN" ] || [ "$UPLINK_CONN" = "--" ] && { echo "No active profile on ${UPLINK_IFACE}. Aborting."; exit 1; }
            echo "Rollback if this breaks SSH: nmcli connection modify \"$UPLINK_CONN\" ipv4.method auto && nmcli connection up \"$UPLINK_CONN\""
            read -rp "Type 'yes' to apply: " APPLY_STATIC
            [ "$APPLY_STATIC" != "yes" ] && { echo "Aborting."; exit 1; }
            nmcli connection modify "$UPLINK_CONN" ipv4.addresses "${STATIC_IP}/${STATIC_PREFIX}" ipv4.gateway "$STATIC_GW" ipv4.dns "$STATIC_DNS" ipv4.method manual
            nmcli connection up "$UPLINK_CONN"
            REACH_IP="$STATIC_IP"
        fi
    fi

    section "=== Robot Wi-Fi and shared ADB server ==="
    important "Control Hubs use 5 GHz by default. Choose a 5 GHz-capable adapter when possible."
    echo "Choose the adapter that can see the robot's Wi-Fi:"
    WIFI_INTERFACES=()
    FIVE_GHZ_INTERFACES=()
    while IFS=: read -r iface type; do
        [ "$type" = "wifi" ] || continue
        WIFI_INTERFACES+=("$iface")
        wifi_supports_frequency_range "$iface" 4900 5925 && FIVE_GHZ_INTERFACES+=("$iface")
    done < <(nmcli -t -f DEVICE,TYPE device)
    for iface in "${WIFI_INTERFACES[@]}"; do
        recommendation=""
        if [ "${#FIVE_GHZ_INTERFACES[@]}" -eq 1 ] && [ "$iface" = "${FIVE_GHZ_INTERFACES[0]}" ]; then
            recommendation=" — recommended: only 5 GHz-capable adapter"
        fi
        describe_wifi_adapter "$iface" "$recommendation"
    done
    read -rp "WiFi interface to join the robot wifi: " WIFI_IFACE
    [ -z "$WIFI_IFACE" ] && { echo "Aborting."; exit 1; }
    read -rp "Robot wifi SSID: " TARGET_SSID
    [ -z "$TARGET_SSID" ] && { echo "Aborting."; exit 1; }
    read -rp "Robot wifi password (shown as you type; blank if open): " WIFI_PASS
    # Control Hub AP mode always assigns itself 192.168.43.1:5555 - a
    # hardware constant of AP mode, not a per-installation choice, same
    # reasoning as ROBOT_IP on the laptop side. Not prompted.
    DEVICE_IP="192.168.43.1"
    DEVICE_PORT="5555"
    read -rp "Local adb server port [5037]: " ADB_PORT; ADB_PORT="${ADB_PORT:-5037}"
    LOG_FILE="/var/log/adb-forwarder.log"
 
    echo "Configuring NetworkManager profile for $TARGET_SSID..."
    if nmcli -t -f NAME connection show | grep -Fxq "$TARGET_SSID"; then
        echo "Existing profile found, updating."
    else
        nmcli connection add type wifi con-name "$TARGET_SSID" ifname "$WIFI_IFACE" ssid "$TARGET_SSID"
    fi
    if [ -n "$WIFI_PASS" ]; then
        # Direct configuration avoids nmcli's confusing interactive editor.
        nmcli connection modify "$TARGET_SSID" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PASS"
    else
        nmcli connection modify "$TARGET_SSID" wifi-sec.key-mgmt none
    fi
    nmcli connection modify "$TARGET_SSID" connection.interface-name "$WIFI_IFACE" connection.autoconnect yes

    # Persist config for --auto replay. Deliberately excludes WIFI_PASS -
    # it already lives in NetworkManager's own 600-permission keyfile;
    # we don't need or want a second copy of a plaintext secret.
    cat > "$CONFIG_FILE" <<EOF
SERVICE_USER="${SERVICE_USER}"
WIFI_IFACE="${WIFI_IFACE}"
TARGET_SSID="${TARGET_SSID}"
DEVICE_IP="${DEVICE_IP}"
DEVICE_PORT="${DEVICE_PORT}"
ADB_PORT="${ADB_PORT}"
LOG_FILE="${LOG_FILE}"
REACH_IP="${REACH_IP}"
EOF
    # The watchdog runs as SERVICE_USER, so it must own this mode-600 config.
    # WIFI_PASS is not stored here; NetworkManager keeps that secret separately.
    chown "$SERVICE_USER":"$SERVICE_USER" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
fi

# --- From here on, runs identically whether interactive or --auto ---

# shellcheck disable=SC1090
source "$CONFIG_FILE"

POLKIT_RULE="/etc/polkit-1/rules.d/50-adb-forwarder-nm.rules"
cat > "$POLKIT_RULE" <<EOF
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager.") == 0 &&
        subject.user == "${SERVICE_USER}") {
        return polkit.Result.YES;
    }
});
EOF

touch "$LOG_FILE"
chown "$SERVICE_USER" "$LOG_FILE"

# Install the generic watchdog logic (this is what auto-update replaces).
if [ ! -f "$WATCHDOG_SRC" ]; then
    echo "FATAL: ${WATCHDOG_SRC} not found next to install.sh."
    exit 1
fi
bash -n "$WATCHDOG_SRC" || { echo "FATAL: watchdog script fails syntax check, refusing to install."; exit 1; }
install -m 755 "$WATCHDOG_SRC" "$SCRIPT_PATH"

cat > /etc/systemd/system/adb-forwarder-server.service <<EOF
[Unit]
Description=Shared adb server bound to all interfaces (LAN-visible)

[Service]
Type=simple
ExecStart=$(command -v adb) -a -P ${ADB_PORT} nodaemon server
Restart=always
RestartSec=3
User=${SERVICE_USER}

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/adb-forwarder-connect.service <<EOF
[Unit]
Description=Keep this host connected to ${TARGET_SSID} and the device over adb
Requires=adb-forwarder-server.service
After=network.target NetworkManager.service adb-forwarder-server.service

[Service]
Type=simple
ExecStart=${SCRIPT_PATH}
Restart=always
RestartSec=3
User=${SERVICE_USER}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now adb-forwarder-server.service
sleep 2
# On --auto, only the watchdog logic may have changed - restart just that,
# leave the adb server (and any live connections through it) alone.
if [ "$AUTO" = "1" ]; then
    systemctl restart adb-forwarder-connect.service
    systemctl enable adb-forwarder-connect.service >/dev/null 2>&1 || true
else
    systemctl enable --now adb-forwarder-connect.service
fi

# --- Install/refresh the nightly updater (idempotent either way) ---
UPDATER_SRC="${SCRIPT_DIR}/adb-forwarder-updater.sh"
if [ -f "$UPDATER_SRC" ]; then
    bash -n "$UPDATER_SRC" || { echo "WARNING: updater script fails syntax check, not installing it."; UPDATER_SRC=""; }
fi
if [ -n "$UPDATER_SRC" ]; then
    install -m 755 "$UPDATER_SRC" /usr/local/bin/adb-forwarder-updater.sh
    cat > /etc/systemd/system/adb-forwarder-updater.service <<EOF
[Unit]
Description=Check for and apply adb-forwarder script updates

[Service]
Type=oneshot
ExecStart=/usr/local/bin/adb-forwarder-updater.sh
EOF
    cat > /etc/systemd/system/adb-forwarder-updater.timer <<EOF
[Unit]
Description=Nightly adb-forwarder update check

[Timer]
OnCalendar=03:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now adb-forwarder-updater.timer
fi

if [ "$AUTO" != "1" ]; then
    echo ""
    echo "=== Verifying ==="
    sleep 5
    echo "adb-forwarder-server.service:  $(systemctl is-active adb-forwarder-server.service || true)"
    echo "adb-forwarder-connect.service: $(systemctl is-active adb-forwarder-connect.service || true)"
    if ss -ltn 2>/dev/null | grep -q ":${ADB_PORT} "; then
        echo "Port ${ADB_PORT} is bound and listening."
    else
        warning "Port ${ADB_PORT} not listening yet. Check: systemctl status adb-forwarder-server.service"
    fi
    LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    section "=== Setup complete ==="
    important "On laptops, point setup at:"
    important "  host: ${REACH_IP:-<not set>}   user: ${SERVICE_USER}   port: ${ADB_PORT}"
    echo "(plain LAN IP for reference: ${LAN_IP:-unknown})"
    echo ""
    echo "Logs: ${LOG_FILE}  |  journalctl -u adb-forwarder-connect.service"
    echo "Auto-update: checks nightly ~03:00, applies only if VERSION in the repo"
    echo "increased, syntax-checks before installing, restarts only the watchdog."
fi
