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

AUTO=0
[ "${1:-}" = "--auto" ] && AUTO=1

if [ "$EUID" -ne 0 ]; then
    echo "Run this with sudo."
    exit 1
fi
for bin in systemctl nmcli adb ss; do
    command -v "$bin" >/dev/null 2>&1 || { echo "$bin not found. Aborting."; exit 1; }
done

CONFIG_DIR="/etc/adb-forwarder"
CONFIG_FILE="${CONFIG_DIR}/config.env"
mkdir -p "$CONFIG_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG_SRC="${SCRIPT_DIR}/adb-forwarder-connect.sh"
SCRIPT_PATH="/usr/local/bin/adb-forwarder-connect.sh"

if [ "$AUTO" = "1" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "--auto requires an existing $CONFIG_FILE - run without --auto first."
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    echo "=== ADB Bridge auto-update (replaying saved config) ==="
else
    echo "=== ADB Bridge Setup ==="
    DEFAULT_USER="${SUDO_USER:-}"
    read -rp "Non-root user to run the bridge services as [${DEFAULT_USER}]: " SERVICE_USER
    SERVICE_USER="${SERVICE_USER:-$DEFAULT_USER}"
    if [ -z "$SERVICE_USER" ] || ! id "$SERVICE_USER" >/dev/null 2>&1; then
        echo "No valid non-root user given/found. Aborting."
        exit 1
    fi

    echo ""
    echo "=== Reachability: how will laptops reach this bridge machine? ==="
    echo "  1) Tailscale (recommended)"
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
        read -rp "Router already has a fixed DHCP reservation for this machine? [y/N]: " HAS_RESERVATION
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

    echo ""
    echo "=== Robot AP join + shared adb server ==="
    nmcli -t -f DEVICE,TYPE device | awk -F: '$2=="wifi"{print "  "$1}'
    read -rp "WiFi interface to join the target AP: " WIFI_IFACE
    [ -z "$WIFI_IFACE" ] && { echo "Aborting."; exit 1; }
    read -rp "Target AP SSID: " TARGET_SSID
    [ -z "$TARGET_SSID" ] && { echo "Aborting."; exit 1; }
    read -rsp "AP password (blank if open): " WIFI_PASS; echo ""
    read -rp "Device IP [192.168.43.1]: " DEVICE_IP; DEVICE_IP="${DEVICE_IP:-192.168.43.1}"
    read -rp "Device adb port [5555]: " DEVICE_PORT; DEVICE_PORT="${DEVICE_PORT:-5555}"
    read -rp "Local adb server port [5037]: " ADB_PORT; ADB_PORT="${ADB_PORT:-5037}"
    LOG_FILE="/var/log/adb-forwarder.log"

    echo "Configuring NetworkManager profile for $TARGET_SSID..."
    if nmcli -t -f NAME connection show | grep -Fxq "$TARGET_SSID"; then
        echo "Existing profile found, updating."
    else
        nmcli connection add type wifi con-name "$TARGET_SSID" ifname "$WIFI_IFACE" ssid "$TARGET_SSID"
    fi
    if [ -n "$WIFI_PASS" ]; then
        # Via stdin to `nmcli connection edit`, not argv - keeps it off `ps aux`.
        nmcli connection edit "$TARGET_SSID" <<NMCLI_EOF
set wifi-sec.key-mgmt wpa-psk
set wifi-sec.psk $WIFI_PASS
save
quit
NMCLI_EOF
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
        echo "WARNING: port ${ADB_PORT} not listening yet. Check: systemctl status adb-forwarder-server.service"
    fi
    LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo ""
    echo "=== Done ==="
    echo "On laptops, point setup at:"
    echo "  host: ${REACH_IP:-<not set>}   user: ${SERVICE_USER}   port: ${ADB_PORT}"
    echo "(plain LAN IP for reference: ${LAN_IP:-unknown})"
    echo ""
    echo "Logs: ${LOG_FILE}  |  journalctl -u adb-forwarder-connect.service"
    echo "Auto-update: checks nightly ~03:00, applies only if VERSION in the repo"
    echo "increased, syntax-checks before installing, restarts only the watchdog."
fi
