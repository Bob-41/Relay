#!/usr/bin/env bash
# install.sh (bridge side)
# Interactive on first run (asks questions, saves them to
# /etc/adb-forwarder/config.env). Re-runnable non-interactively via --auto,
# which replays the saved config - this is what the nightly updater calls.
# Never re-prompts for or re-stores the WiFi password on --auto; the WiFi
# connection profile itself is left untouched on --auto runs entirely.
#
# Supported bridge distros: Debian family (apt, e.g. Raspberry Pi OS) and Arch
# family (pacman, e.g. Arch, CachyOS, EndeavourOS, Manjaro, Arch Linux ARM).
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

# --- Package manager abstraction ----------------------------------------------
# apt is checked first so existing Debian / Raspberry Pi OS behaviour is
# unchanged. On any other distro the prerequisites must be installed by hand.
detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo apt
    elif command -v pacman >/dev/null 2>&1; then
        echo pacman
    else
        echo none
    fi
}
PKG_MGR="$(detect_pkg_manager)"

# pkg_for <role> - the distro's package name for a generic role.
pkg_for() {
    case "${PKG_MGR}:$1" in
        apt:adb)               echo adb ;;
        pacman:adb)            echo android-tools ;;
        apt:networkmanager)    echo network-manager ;;
        pacman:networkmanager) echo networkmanager ;;
        apt:openssh)           echo openssh-server ;;
        pacman:openssh)        echo openssh ;;
        *:iproute)             echo iproute2 ;;
        *)                     echo "$1" ;;
    esac
}

# pkg_install <package>... - non-interactive install; returns non-zero on failure.
pkg_install() {
    case "$PKG_MGR" in
        apt)
            apt-get install -y "$@"
            ;;
        pacman)
            # Deliberately never `pacman -Sy`: on Arch, refreshing the sync
            # database without a full upgrade (-Syu) is an unsupported partial
            # upgrade that can break the system.
            if ! pacman -S --needed --noconfirm "$@"; then
                warning "pacman could not install: $*"
                important "If it reports 404 / 'failed retrieving file', your package database is stale."
                important "Run 'sudo pacman -Syu' (a full upgrade), then re-run this script."
                return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

# pkg_install_hint <role> - the command a human should run for that role.
pkg_install_hint() {
    case "$PKG_MGR" in
        apt)    echo "sudo apt-get install -y $(pkg_for "$1")" ;;
        pacman) echo "sudo pacman -S --needed $(pkg_for "$1")" ;;
        *)      echo "install '$1' with your package manager" ;;
    esac
}

# Laptops reach the bridge over SSH. The unit is ssh.service on Debian and
# sshd.service on Arch; also accept socket-activated setups.
ssh_server_active() {
    local unit
    for unit in sshd.service ssh.service sshd.socket ssh.socket; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

ssh_unit_name() {
    if [ "$PKG_MGR" = "pacman" ]; then echo sshd; else echo ssh; fi
}

# `hostname -I` is a Debian-ism (Arch's inetutils hostname has no -I). With
# `set -o pipefail` a failing hostname would abort the script before the final
# "Setup complete" summary prints, so every step here tolerates failure.
primary_lan_ip() {
    local out=""
    out="$(hostname -I 2>/dev/null | awk '{ print $1 }')" || true
    if [ -z "$out" ]; then
        out="$(ip -4 route get 1.1.1.1 2>/dev/null \
            | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }')" || true
    fi
    printf '%s' "$out"
}

# Google only ships Linux platform-tools as x86_64. On aarch64 (Raspberry Pi)
# the distro `adb` package is capped (e.g. Debian 35.0.2) and cannot speak a
# newer Control Hub / laptop-client protocol. Fix: run Google's binary under
# box64, leaving apt's /usr/bin/adb untouched as a rollback path.
GOOGLE_ADB_DIR="/opt/adb-google"
GOOGLE_ADB_BIN="${GOOGLE_ADB_DIR}/platform-tools/adb"
BOX64_LIBS_DIR="/opt/box64-libs"
ADB_WRAPPER="/usr/local/bin/adb"
PLATFORM_TOOLS_URL="https://dl.google.com/android/repository/platform-tools-latest-linux.zip"
# Below this, treat distro adb on aarch64 as a protocol-mismatch risk.
MIN_ADB_VERSION="36.0.0"

adb_version_number() {
    local bin="${1:-adb}"
    "$bin" version 2>/dev/null | awk '/^Version / { sub(/-.*/, "", $2); print $2; exit }'
}

version_lt() {
    local a="$1" b="$2"
    [ -n "$a" ] && [ -n "$b" ] || return 0
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)" = "$a" ] && [ "$a" != "$b" ]
}

# On pacman distros there is no automatic newer-adb fallback, so at least say so.
warn_if_adb_old() {
    local ver
    [ "$PKG_MGR" = "pacman" ] || return 0
    ver="$(adb_version_number "$1")"
    if [ -n "$ver" ] && version_lt "$ver" "$MIN_ADB_VERSION"; then
        warning "Distro adb ${ver} is older than ${MIN_ADB_VERSION}. If laptops report an adb server version mismatch, update it: sudo pacman -Syu"
        important "(The automatic box64 + Google platform-tools fallback is apt-only.)"
    fi
    return 0
}

google_adb_wrapper_healthy() {
    command -v box64 >/dev/null 2>&1 \
        && [ -x "$GOOGLE_ADB_BIN" ] \
        && [ -x "$ADB_WRAPPER" ] \
        && grep -q 'box64' "$ADB_WRAPPER" 2>/dev/null \
        && "$ADB_WRAPPER" version >/dev/null 2>&1
}

# True when this host needs the box64 + Google platform-tools path.
needs_box64_google_adb() {
    case "$(uname -m)" in
        aarch64|arm64) ;;
        *) return 1 ;;
    esac
    # The box64 fallback below is built on apt/dpkg (amd64 libc extraction,
    # Debian box64 repos). On pacman distros Arch builds android-tools from
    # source for each architecture, so the distro package is used as-is.
    [ "$PKG_MGR" = "apt" ] || return 1
    google_adb_wrapper_healthy && return 1

    local apt_ver
    apt_ver="$(adb_version_number /usr/bin/adb)"
    if [ -z "$apt_ver" ]; then
        # aarch64 without a readable apt adb version still cannot run Google's
        # x86_64 binary natively - install the wrapper path.
        return 0
    fi
    version_lt "$apt_ver" "$MIN_ADB_VERSION"
}

ensure_box64_installed() {
    if command -v box64 >/dev/null 2>&1; then
        return 0
    fi
    important "Installing box64 (needed to run Google's x86_64 adb on this CPU)..."
    if apt-get install -y box64 && command -v box64 >/dev/null 2>&1; then
        return 0
    fi
    if apt-get install -y box64-generic-arm && command -v box64 >/dev/null 2>&1; then
        return 0
    fi
    # Raspberry Pi OS / Debian often need the Pi-Apps box64 builds.
    important "Adding Pi-Apps-Coders box64 apt repo..."
    command -v curl >/dev/null 2>&1 || apt-get install -y curl
    command -v gpg >/dev/null 2>&1 || apt-get install -y gnupg
    mkdir -p /usr/share/keyrings
    curl -fsSL "https://pi-apps-coders.github.io/box64-debs/KEY.gpg" \
        | gpg --dearmor -o /usr/share/keyrings/box64-archive-keyring.gpg
    cat > /etc/apt/sources.list.d/box64.sources <<'EOF'
Types: deb
URIs: https://Pi-Apps-Coders.github.io/box64-debs/debian
Suites: ./
Signed-By: /usr/share/keyrings/box64-archive-keyring.gpg
EOF
    apt-get update
    apt-get install -y box64-generic-arm
    command -v box64 >/dev/null 2>&1 || {
        warning "box64 install failed. Cannot install Google adb on aarch64."
        return 1
    }
}

ensure_box64_amd64_libs() {
    # Extract only - never `apt-get install` amd64 libc onto the host (that
    # fights Raspberry Pi OS's patched arm64 libc). Matches the 2026-09-14
    # decision: apt-get download + dpkg -x into /opt/box64-libs.
    #
    # Everything this function does to apt's global state (a foreign
    # architecture, a temporary mirror line) is undone before it returns, on the
    # failure path too. Neither may outlive the call: a leftover
    # `dpkg --add-architecture amd64` contradicts this project's own rule about
    # not registering amd64 on a Pi, and a leftover mirror line pointing at an
    # archive that does not exist makes every later `apt update` on that host
    # fail with "Release file not found" - a broken bridge from a step that was
    # only ever trying to help.
    local tmp codename list_file arch_added=0 download_ok=0
    local os_id apt_amd64_url
    if [ -e "${BOX64_LIBS_DIR}/lib/x86_64-linux-gnu/libc.so.6" ] \
        || [ -e "${BOX64_LIBS_DIR}/usr/lib/x86_64-linux-gnu/libc.so.6" ]; then
        return 0
    fi
    if [ -e "${BOX64_LIBS_DIR}/lib/x86_64-linux-gnu/libgcc_s.so.1" ] \
        || [ -e "${BOX64_LIBS_DIR}/usr/lib/x86_64-linux-gnu/libgcc_s.so.1" ]; then
        return 0
    fi
    important "Extracting amd64 glibc/libgcc into ${BOX64_LIBS_DIR} for box64..."
    tmp="$(mktemp -d)"
    # Modern apt (Debian trixie+) drops privileges to the _apt user for
    # `apt-get download`'s actual fetch, even when apt-get itself runs as
    # root. mktemp -d makes a 0700 dir owned by root, which _apt can't write
    # into, so the download silently lands nowhere and extraction ends up
    # empty. Match /tmp's own permissions (mode 1777) so _apt can write here
    # regardless of who apt decides to run as; the dir is root-owned scratch
    # space removed immediately after, so this doesn't widen anything real.
    chmod 1777 "$tmp"
    list_file="/etc/apt/sources.list.d/relay-amd64-download.list"
    os_id="$(. /etc/os-release 2>/dev/null; echo "${ID:-unknown}")"
    codename="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-bookworm}")"

    if ! dpkg --print-foreign-architectures 2>/dev/null | grep -qx amd64; then
        arch_added=1
    fi
    # Ensure amd64 packages are fetchable even when the OS mirror is arm-only.
    # The archive must match the distro: deb.debian.org has no `noble`/`jammy`
    # suite at all, so a hardcoded Debian line on Ubuntu fails every apt call on
    # the host until it is removed by hand.
    if ! grep -Rqs 'arch=amd64' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
        case "$os_id" in
            debian|raspbian|rpi)  apt_amd64_url="http://deb.debian.org/debian" ;;
            ubuntu)               apt_amd64_url="http://ports.ubuntu.com/ubuntu-ports" ;;
            *)                    apt_amd64_url="" ;;
        esac
        if [ -z "$apt_amd64_url" ]; then
            rm -rf "$tmp"
            warning "No known amd64 package archive for distro '${os_id}' (${codename})."
            important "Fetch libc6/libgcc-s1 for amd64 by hand into ${BOX64_LIBS_DIR} (dpkg -x), or install adb manually."
            return 1
        fi
        printf 'deb [arch=amd64] %s %s main\n' "$apt_amd64_url" "$codename" > "$list_file"
    fi
    # Registered last, so every early return above happens while apt is still
    # untouched. The matching --remove-architecture below covers every other
    # exit path.
    if [ "$arch_added" = "1" ]; then
        dpkg --add-architecture amd64
    fi

    if apt-get update >/dev/null 2>&1 \
        && ( cd "$tmp" && apt-get download libc6:amd64 libgcc-s1:amd64 ) 2>/dev/null; then
        download_ok=1
    elif ( cd "$tmp" && apt-get download libc6:amd64 libgcc1:amd64 ) 2>/dev/null; then
        # Older suites used libgcc1 instead of libgcc-s1.
        download_ok=1
    fi

    if [ "$download_ok" != "1" ]; then
        warning "Failed to download amd64 libc/libgcc debs."
    elif ! compgen -G "$tmp"/*.deb >/dev/null; then
        warning "apt-get download reported success but no .deb files were found in ${tmp}."
    else
        mkdir -p "$BOX64_LIBS_DIR"
        local deb
        for deb in "$tmp"/*.deb; do
            [ -e "$deb" ] || continue
            dpkg -x "$deb" "$BOX64_LIBS_DIR"
        done
    fi

    # Undo every global apt change before branching, including on failure.
    rm -rf "$tmp"
    rm -f "$list_file"
    if [ "$arch_added" = "1" ]; then
        dpkg --remove-architecture amd64 >/dev/null 2>&1 \
            || warning "Could not remove the temporary amd64 foreign architecture - check: dpkg --print-foreign-architectures"
    fi
    apt-get update >/dev/null 2>&1 || true

    [ "$download_ok" = "1" ] || return 1
    # dpkg -x into an empty tree with no merged-/usr symlink puts everything
    # under usr/lib/x86_64-linux-gnu, not lib/x86_64-linux-gnu - check both,
    # matching the libgcc check above and BOX64_LD_LIBRARY_PATH below.
    if [ ! -e "${BOX64_LIBS_DIR}/lib/x86_64-linux-gnu/libc.so.6" ] \
        && [ ! -e "${BOX64_LIBS_DIR}/usr/lib/x86_64-linux-gnu/libc.so.6" ]; then
        warning "amd64 libc extraction looked empty under ${BOX64_LIBS_DIR}."
        return 1
    fi
}

install_google_platform_tools() {
    local tmp zip
    important "Fetching Google platform-tools (x86_64) into ${GOOGLE_ADB_DIR}..."
    command -v unzip >/dev/null 2>&1 || apt-get install -y unzip
    tmp="$(mktemp -d)"
    zip="${tmp}/platform-tools-latest-linux.zip"
    if ! curl -fsSL --retry 3 -o "$zip" "$PLATFORM_TOOLS_URL"; then
        rm -rf "$tmp"
        warning "Failed to download ${PLATFORM_TOOLS_URL}"
        return 1
    fi
    rm -rf "$GOOGLE_ADB_DIR"
    mkdir -p "$GOOGLE_ADB_DIR"
    if ! unzip -q "$zip" -d "$GOOGLE_ADB_DIR"; then
        rm -rf "$tmp" "$GOOGLE_ADB_DIR"
        warning "Failed to unzip platform-tools."
        return 1
    fi
    rm -rf "$tmp"
    chmod 755 "$GOOGLE_ADB_BIN"
    [ -x "$GOOGLE_ADB_BIN" ] || {
        warning "Expected ${GOOGLE_ADB_BIN} missing after extract."
        return 1
    }
}

write_adb_box64_wrapper() {
    # /usr/local/bin beats /usr/bin on systemd's default PATH and on interactive
    # logins, so bare `adb` picks this up. Apt's /usr/bin/adb is not modified.
    cat > "$ADB_WRAPPER" <<EOF
#!/bin/bash
# Relay: Google platform-tools adb via box64. Rollback: /usr/bin/adb
export BOX64_LD_LIBRARY_PATH="${BOX64_LIBS_DIR}/lib/x86_64-linux-gnu:${BOX64_LIBS_DIR}/usr/lib/x86_64-linux-gnu:${BOX64_LIBS_DIR}/lib64:\${BOX64_LD_LIBRARY_PATH:-}"
exec box64 ${GOOGLE_ADB_BIN} "\$@"
EOF
    chmod 755 "$ADB_WRAPPER"
}

# Installs or repairs the box64 Google adb path when needed.
# Sets ADB_BIN to the binary adb-forwarder-server.service should ExecStart.
# Sets ADB_BIN_CHANGED=1 when the server binary/path was (re)provisioned.
ensure_adb_for_bridge() {
    ADB_BIN="$(command -v adb)"
    ADB_BIN_CHANGED=0

    if ! needs_box64_google_adb; then
        if google_adb_wrapper_healthy; then
            ADB_BIN="$ADB_WRAPPER"
            important "Using existing Google adb under box64: ${ADB_BIN} ($(adb_version_number "$ADB_BIN"))"
        else
            important "Using system adb: ${ADB_BIN} ($(adb_version_number "$ADB_BIN"))"
            warn_if_adb_old "$ADB_BIN"
        fi
        return 0
    fi

    section "=== ADB version mismatch on aarch64 ==="
    important "Distro adb $(adb_version_number /usr/bin/adb) is below ${MIN_ADB_VERSION} (or unreadable)."
    important "Installing Google platform-tools under box64. Leaving /usr/bin/adb alone."

    ensure_box64_installed || return 1
    ensure_box64_amd64_libs || return 1
    install_google_platform_tools || return 1
    write_adb_box64_wrapper || return 1

    if ! google_adb_wrapper_healthy; then
        warning "Google adb wrapper installed but failed \`adb version\`. Check box64 libs."
        return 1
    fi
    ADB_BIN="$ADB_WRAPPER"
    ADB_BIN_CHANGED=1
    important "Google adb ready: ${ADB_BIN} ($(adb_version_number "$ADB_BIN"))"
}

AUTO=0
[ "${1:-}" = "--auto" ] && AUTO=1

if [ "$EUID" -ne 0 ]; then
    warning "Run this with sudo."
    exit 1
fi
if ! command -v iw >/dev/null 2>&1; then
    if [ "$PKG_MGR" != "none" ]; then
        important "Installing iw so Relay can show Wi-Fi adapter band support..."
        pkg_install "$(pkg_for iw)" || { warning "Could not install iw. Aborting."; exit 1; }
    else
        warning "iw is required to show Wi-Fi adapter band support. Install it, then re-run this script."
        exit 1
    fi
fi
if ! command -v adb >/dev/null 2>&1 && [ "$PKG_MGR" != "none" ]; then
    important "Installing adb ($(pkg_for adb))..."
    pkg_install "$(pkg_for adb)" || { warning "Could not install adb. Aborting."; exit 1; }
fi
for bin in systemctl nmcli adb ss iw; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        warning "$bin not found. Aborting."
        case "$bin" in
            nmcli)
                important "Install NetworkManager and start it:"
                important "  $(pkg_install_hint networkmanager) && sudo systemctl enable --now NetworkManager"
                ;;
            ss)  important "  $(pkg_install_hint iproute)" ;;
            adb) important "  $(pkg_install_hint adb)" ;;
        esac
        exit 1
    fi
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
    if ! systemctl is-active --quiet NetworkManager.service; then
        warning "NetworkManager is installed but not running. Relay manages Wi-Fi through it."
        important "Start it with: sudo systemctl enable --now NetworkManager"
        important "(If this machine uses systemd-networkd, netctl or iwd to manage networking, switch deliberately - NetworkManager takes over Wi-Fi.)"
        exit 1
    fi
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
        if ! command -v tailscale >/dev/null 2>&1 && [ "$PKG_MGR" = "pacman" ]; then
            read -rp "Tailscale not installed. Install the 'tailscale' package with pacman now? [y/N]: " DO_INSTALL
            if [ "$DO_INSTALL" = "y" ] || [ "$DO_INSTALL" = "Y" ]; then
                pkg_install tailscale || { echo "Aborting."; exit 1; }
            else
                echo "Aborting."; exit 1
            fi
        fi
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
    [ -z "$WIFI_IFACE" ] || printf '%s' "$WIFI_IFACE" | grep -qE '^[A-Za-z0-9._-]+$' \
        || { echo "Not a valid interface name: ${WIFI_IFACE}. Aborting."; exit 1; }

    # An unmanaged interface can never join anything. NetworkManager leaves a
    # device unmanaged when another renderer (typically netplan) claims the
    # host without listing it, and `nmcli connection add` will happily create a
    # profile for it that can never activate. That is the single most common
    # "Relay installed fine and then did nothing" failure, and it used to be
    # discovered hours later from the watchdog log. Catch it here.
    wifi_iface_state() {
        nmcli -t -f DEVICE,STATE device status 2>/dev/null \
            | awk -F: -v d="$WIFI_IFACE" '$1 == d { print $2; exit }'
    }
    WIFI_STATE="$(wifi_iface_state)"
    if [ -z "$WIFI_STATE" ] || [ "$WIFI_STATE" = "unmanaged" ]; then
        echo "FATAL: NetworkManager does not manage ${WIFI_IFACE} (state: ${WIFI_STATE:-not listed})."
        echo "A connection profile for it can be created but will never activate, so"
        echo "the bridge would sit there 'installed' and never see the Control Hub."
        echo ""
        echo "On a netplan host, add a drop-in from a LOCAL console - not over SSH on"
        echo "this interface, which drops the lease:"
        echo "  sudo sh -c 'printf \"network:\\n  version: 2\\n  wifis:\\n    ${WIFI_IFACE}:\\n      renderer: NetworkManager\\n\" > /etc/netplan/99-relay.yaml'"
        echo "  sudo netplan apply"
        echo ""
        echo "Type NM to continue anyway (Relay will not be able to join the robot"
        echo "WiFi), anything else aborts:"
        read -rp "> " UNMANAGED_OVERRIDE
        [ "$UNMANAGED_OVERRIDE" = "NM" ] || { echo "Aborting."; exit 1; }
    fi

    # Dedicating this machine's only *working* network path to the robot AP means
    # it loses everything else the instant it joins - including whatever is
    # carrying this very SSH session. A single-radio laptop cannot stay remotely
    # reachable the way the reference Pi bridge does (two WiFi radios: one for
    # the robot AP, one for admin/Tailscale). Refuse rather than let that surprise
    # someone after the fact.
    #
    # "Other interface" means other *usable* interface: connected or connecting,
    # not merely enumerated. nmcli reports `unavailable` for a wired port with no
    # cable and `disconnected` for an idle radio; counting either of those passes
    # this check today and then the bridge loses its uplink anyway the moment it
    # joins - the false success this replaces.
    OTHER_IFACES=()
    while IFS=: read -r iface type state; do
        [ "$iface" = "$WIFI_IFACE" ] && continue
        [ -n "$iface" ] || continue
        case "$state" in
            connected*|connecting*) ;;
            *) continue ;;
        esac
        case "$type" in
            wifi|ethernet) OTHER_IFACES+=("$iface") ;;
        esac
    done < <(nmcli -t -f DEVICE,TYPE,STATE device status)
    if [ "${#OTHER_IFACES[@]}" -eq 0 ]; then
        echo "FATAL: ${WIFI_IFACE} is the only connected network interface on this machine."
        echo "Joining the robot's WiFi on it will disconnect this machine from"
        echo "everything else, including whatever is carrying this SSH session,"
        echo "with no fallback path to reach it again remotely."
        echo "Plug in a second adapter (wired, or a second WiFi radio) and"
        echo "re-run this installer - that's the right fix for a real bridge."
        echo ""
        echo "Only bypass this if you know you don't need remote access - e.g."
        echo "a dev/bench setup with a monitor and keyboard on this machine the"
        echo "whole time. Type DEV to continue anyway, anything else aborts:"
        read -rp "> " SINGLE_IFACE_OVERRIDE
        if [ "$SINGLE_IFACE_OVERRIDE" != "DEV" ]; then
            echo "Aborting."
            exit 1
        fi
        echo "Continuing on a single interface - remote access will NOT survive joining the robot's WiFi."
    fi

    # The interface count is necessary but not sufficient: a second adapter that
    # is merely *present* does not stop the chosen one from carrying this very
    # session, and it is the chosen interface whose profile we are about to
    # change. Ask the routing table directly - if the default route or the live
    # SSH connection runs over WIFI_IFACE, joining the robot AP on it is the
    # exact failure described above, whatever else is plugged in.
    route_dev_for() {
        ip route get "$1" 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
    }
    DEFAULT_DEV="$(route_dev_for 1.1.1.1)"
    SESSION_DEV=""
    SSH_PEER="${SSH_CONNECTION%% *}"
    [ -n "$SSH_PEER" ] && SESSION_DEV="$(route_dev_for "$SSH_PEER")"
    if [ "$DEFAULT_DEV" = "$WIFI_IFACE" ] || [ "$SESSION_DEV" = "$WIFI_IFACE" ]; then
        REASON=""
        [ "$SESSION_DEV" = "$WIFI_IFACE" ] && REASON="your current SSH session runs over ${WIFI_IFACE}"
        [ "$DEFAULT_DEV" = "$WIFI_IFACE" ] && REASON="${REASON:+$REASON and }the default route runs over ${WIFI_IFACE}"
        echo "FATAL: ${REASON}."
        echo "This is the interface you asked Relay to join to the robot's WiFi, so"
        echo "the bridge will drop off every other network - including Tailscale and"
        echo "the session you would use to recover it."
        echo "Use the other adapter as the robot interface, or move the uplink"
        echo "(Tailscale/home Wi-Fi/Ethernet) onto it first, then re-run this installer."
        echo ""
        echo "Type DEV to continue anyway, anything else aborts:"
        read -rp "> " ROUTE_OVERRIDE
        if [ "$ROUTE_OVERRIDE" != "DEV" ]; then
            echo "Aborting."
            exit 1
        fi
        important "Continuing: ${WIFI_IFACE} is carrying your uplink. Remote access will NOT survive joining the robot's WiFi."
    fi
    read -rp "Robot wifi SSID: " TARGET_SSID
    [ -z "$TARGET_SSID" ] && { echo "Aborting."; exit 1; }
    read -rp "Robot wifi password (shown as you type; blank if open): " WIFI_PASS
    # WPA-PSK passphrases must be 8-63 chars; nmcli rejects anything outside
    # that range with a cryptic "property is invalid" error and no guidance.
    # Catch it here with a message that actually says what's wrong.
    if [ -n "$WIFI_PASS" ] && { [ "${#WIFI_PASS}" -lt 8 ] || [ "${#WIFI_PASS}" -gt 63 ]; }; then
        echo "FATAL: WiFi password must be 8-63 characters for WPA-PSK (got ${#WIFI_PASS}). Aborting."
        exit 1
    fi
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
    # Never let the robot AP own this host's default route. A Control Hub in AP
    # mode hands out DHCP on 192.168.43.0/24 and most AP firmware supplies a
    # gateway address, so joining it can install `default via 192.168.43.1` with
    # NetworkManager's wifi metric - which beats the home/Ethernet uplink that
    # is carrying Tailscale and this SSH session. The result is a bridge that
    # looks connected to the robot and has lost every path off the robot
    # network, including the way you'd use to fix it. The robot network needs
    # no gateway at all: the hub is reached at a fixed address on-link.
    nmcli connection modify "$TARGET_SSID" ipv4.never-default yes ipv6.never-default yes

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
    # Ownership and mode are set once, in the common section below
    # (root:service-group 0640). Root `source`s this file on --auto, so it must
    # never be writable by the unprivileged service account. WIFI_PASS is not
    # stored here; NetworkManager keeps that secret separately.
fi

# --- From here on, runs identically whether interactive or --auto ---

# shellcheck disable=SC1090
source "$CONFIG_FILE"

POLKIT_RULE="/etc/polkit-1/rules.d/50-adb-forwarder-nm.rules"
mkdir -p "$(dirname "$POLKIT_RULE")"
# Grant exactly one action, not the whole org.freedesktop.NetworkManager.*
# namespace. The prefix match this replaces handed the service account
# passwordless power control of every interface on the host (networking.disable,
# wifi.disable, settings.modify.system, shared - i.e. a trivial route to root on
# any machine where that account is *not* already a sudoer). The watchdog only
# ever activates one profile: nmcli connection up/down is network-control.
cat > "$POLKIT_RULE" <<EOF
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.NetworkManager.network-control" &&
        subject.user == "${SERVICE_USER}") {
        return polkit.Result.YES;
    }
});
EOF

# config.env is sourced by root on --auto (this script) and read by the watchdog
# as SERVICE_USER. It must therefore be writable by neither: a service account
# that can rewrite it can hand root arbitrary shell through `source`. Root owns
# the file; the service user gets read access through its own group. It holds no
# Wi-Fi password (NetworkManager keeps that), but root-sourcing it is still
# arbitrary code execution, which is the whole point of writing it root-owned.
CONFIG_GROUP="$(id -gn "$SERVICE_USER" 2>/dev/null || echo root)"
chown root:"$CONFIG_GROUP" "$CONFIG_FILE"
chmod 640 "$CONFIG_FILE"

# Enforce never-default on the robot profile on EVERY run, including --auto,
# rather than only when it is first created. Deliberate exception to "the Wi-Fi
# connection profile is left untouched on --auto": this property is the
# difference between a bridge that keeps Tailscale and one that goes dark the
# moment the Control Hub is powered on, and an unattended --auto run is exactly
# when nobody is watching to notice. Idempotent, and touches no credential.
if nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq "$TARGET_SSID"; then
    NEVER_DEFAULT_WAS="$(nmcli -g ipv4.never-default connection show "$TARGET_SSID" 2>/dev/null | head -n1)"
    if [ "$NEVER_DEFAULT_WAS" != "yes" ]; then
        if nmcli connection modify "$TARGET_SSID" ipv4.never-default yes ipv6.never-default yes; then
            important "Robot profile '${TARGET_SSID}': set ipv4/ipv6.never-default=yes (was '${NEVER_DEFAULT_WAS:-unknown}')."
            important "  Without this, the Control Hub's DHCP gateway can become this host's default route"
            important "  and drop Tailscale/SSH. Confirm with: ip route"
        else
            warning "Could not set never-default on '${TARGET_SSID}'. Check 'ip route' after joining the robot Wi-Fi -"
            warning "  a default route via ${DEVICE_IP} will break every path off the robot network."
        fi
    fi
else
    warning "NetworkManager profile '${TARGET_SSID}' not found - skipping the never-default check."
fi

touch "$LOG_FILE"
chown "$SERVICE_USER" "$LOG_FILE"
chmod 640 "$LOG_FILE"   # owner rw, group read; never world-readable

# --- Bound the watchdog log ---
# The watchdog appends on every state change and every retry. On a bridge that
# is repeatedly failing (robot off, or a join that will never succeed) that is
# thousands of lines a day, and /var/log/adb-forwarder.log would grow forever
# until the filesystem fills. Cap it at install time by installing a logrotate
# policy. copytruncate is required: the watchdog holds the file open by path,
# so a rotation that renames it would leave the service writing to the old
# inode. logrotate is optional - absence must not fail the install.
if command -v logrotate >/dev/null 2>&1; then
    cat > /etc/logrotate.d/adb-forwarder <<LOGROTATE_EOF
# Managed by bridge/install.sh. copytruncate: adb-forwarder-connect.sh appends
# to this path and holds it open, so it must not be renamed out from under it.
${LOG_FILE} {
    weekly
    rotate 4
    size 5M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    # `su user group` - logrotate needs both, and SERVICE_USER's own group is
    # not guaranteed to exist or to be the right one.
    su ${SERVICE_USER} $(id -gn "$SERVICE_USER" 2>/dev/null || echo root)
}
LOGROTATE_EOF
else
    important "logrotate not found - ${LOG_FILE} will grow unbounded."
    important "Install it (sudo apt-get install logrotate / sudo pacman -S logrotate) to cap it."
fi

# Install the generic watchdog logic (this is what auto-update replaces).
if [ ! -f "$WATCHDOG_SRC" ]; then
    echo "FATAL: ${WATCHDOG_SRC} not found next to install.sh."
    exit 1
fi
bash -n "$WATCHDOG_SRC" || { echo "FATAL: watchdog script fails syntax check, refusing to install."; exit 1; }
install -m 755 "$WATCHDOG_SRC" "$SCRIPT_PATH"

# Prefer Google+box64 on aarch64 when distro adb is too old for current hubs.
# Failure here is non-fatal on interactive? No - without a working adb the
# bridge is useless on mismatch. Abort so --auto retries next night.
ensure_adb_for_bridge || {
    warning "Could not provision a usable adb. Aborting."
    exit 1
}

# Remember previous ExecStart so --auto can avoid bouncing a live shared server
# unless the binary path actually changed (e.g. first-time box64 repair).
PREV_SERVER_EXEC=""
if [ -f /etc/systemd/system/adb-forwarder-server.service ]; then
    PREV_SERVER_EXEC="$(awk -F= '/^ExecStart=/ { sub(/^ExecStart=/, ""); print; exit }' \
        /etc/systemd/system/adb-forwarder-server.service)"
fi

cat > /etc/systemd/system/adb-forwarder-server.service <<EOF
[Unit]
Description=Shared adb server (reachable only over SSH-forwarded localhost)

[Service]
Type=simple
# Absolute path: do not rely on PATH when the unit is started by systemd.
# When using the box64 wrapper this is /usr/local/bin/adb; apt's
# /usr/bin/adb remains installed as a manual rollback.
#
# Deliberately NOT \`-a\`. An adb server started with -a listens on every
# interface with no authentication whatsoever: anyone on the LAN can run
# \`adb -H <bridge-ip> -P ${ADB_PORT} shell\` against the robot, and Relay's
# Control Hub web interface has no auth either. Nothing in the design needs it -
# laptops reach this server through an SSH tunnel to the bridge's *localhost*,
# and the watchdog below talks to it over 127.0.0.1 as well. Without -a adb binds
# loopback only, which is the same exposure SSH already provides and nothing
# more. Verify after any change with: ss -ltn | grep ${ADB_PORT}
ExecStart=${ADB_BIN} -P ${ADB_PORT} nodaemon server
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
# Ensure bare \`adb\` in the watchdog resolves to the wrapper when present.
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=${SCRIPT_PATH}
Restart=always
RestartSec=3
User=${SERVICE_USER}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
NEW_SERVER_EXEC="${ADB_BIN} -P ${ADB_PORT} nodaemon server"
SERVER_NEEDS_RESTART=0
if [ "$AUTO" != "1" ] || [ "$ADB_BIN_CHANGED" = "1" ] || [ "$PREV_SERVER_EXEC" != "$NEW_SERVER_EXEC" ]; then
    SERVER_NEEDS_RESTART=1
fi
systemctl enable adb-forwarder-server.service >/dev/null 2>&1 || true
if [ "$SERVER_NEEDS_RESTART" = "1" ]; then
    systemctl restart adb-forwarder-server.service
else
    # --auto with unchanged server binary: leave live connections alone.
    systemctl start adb-forwarder-server.service >/dev/null 2>&1 || true
fi
sleep 2
# On --auto, only the watchdog logic may have changed - restart just that,
# leave the adb server alone unless we just reprovisioned it above.
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
    echo "adb binary: ${ADB_BIN} ($(adb_version_number "$ADB_BIN"))"
    if [ "$ADB_BIN" = "$ADB_WRAPPER" ]; then
        echo "apt adb left in place for rollback: /usr/bin/adb ($(adb_version_number /usr/bin/adb))"
    fi
    # Print the actual bind address, not just "something is listening". This is
    # the check that proves the shared adb server is loopback-only: a `*:PORT`
    # or `0.0.0.0:PORT` line here means the server is LAN-reachable again.
    if ss -ltn 2>/dev/null | grep -q ":${ADB_PORT} "; then
        ADB_LISTEN="$(ss -ltn 2>/dev/null | awk -v p=":${ADB_PORT}$" '$4 ~ p { print $4; exit }')"
        echo "Port ${ADB_PORT} is bound and listening (${ADB_LISTEN:-address unknown})."
        case "$ADB_LISTEN" in
            127.0.0.1:*|\[::1\]:*) ;;
            *) warning "Bound to ${ADB_LISTEN:-an unknown address} instead of loopback - the shared adb server is reachable by anyone on this network. Check ExecStart in adb-forwarder-server.service (no -a)." ;;
        esac
    else
        warning "Port ${ADB_PORT} not listening yet. Check: systemctl status adb-forwarder-server.service"
    fi
    LAN_IP="$(primary_lan_ip)"
    if ! ssh_server_active; then
        warning "No active SSH server found. Laptops connect to this bridge over SSH."
        important "  $(pkg_install_hint openssh) && sudo systemctl enable --now $(ssh_unit_name)"
    fi
    section "=== Setup complete ==="
    important "On laptops, point setup at:"
    important "  host: ${REACH_IP:-<not set>}   user: ${SERVICE_USER}   port: ${ADB_PORT}"
    echo "(plain LAN IP for reference: ${LAN_IP:-unknown})"
    echo ""
    echo "Logs: ${LOG_FILE}  |  journalctl -u adb-forwarder-connect.service"
    echo "Auto-update: checks nightly ~03:00, applies only when VERSION in the repo has"
    echo "increased, syntax-checks first, then rolls itself back if the bridge is not"
    echo "healthy afterwards. Report-only mode: echo manual > /etc/adb-forwarder/update-policy"
fi
