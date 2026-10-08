#!/usr/bin/env bash
# diagnose.sh (laptop side)
# READ-ONLY. Collects the evidence needed to explain a Relay tunnel that is not
# working, and prints it in one place.
#
# Why this exists: the fastest way to make a broken tunnel "work" is to re-run
# the installer, which tears down the old tunnel, kills its ssh processes, and
# overwrites the logs - destroying the evidence at the same time. Run this
# first, keep the output, then re-run the installer if you still need to.
#
# Nothing here starts, stops, kills, or edits anything. No sudo required.
#
#   bash laptop/diagnose.sh

set -uo pipefail

section() { printf '\n=== %s ===\n' "$1"; }
note() { printf '%s\n' "$*"; }

# run_with_timeout <seconds> <command...>
# A diagnosis tool must never hang - `adb shell` against a device that is not
# there waits forever, and a script that appears frozen is worse than no
# script. No `timeout(1)` dependency (macOS does not ship one); kill the child
# and report 124 like timeout(1) does.
run_with_timeout() {
    local secs="$1"; shift
    "$@" &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$secs" ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        return 124
    fi
    wait "$pid"
}

case "$(uname -s)" in
    Darwin) PLATFORM="mac" ;;
    Linux)
        if grep -qi microsoft /proc/version 2>/dev/null; then PLATFORM="wsl"; else PLATFORM="linux"; fi
        ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
    *) PLATFORM="unknown" ;;
esac

section "Relay laptop diagnosis ($(date '+%Y-%m-%d %H:%M:%S'), ${PLATFORM})"

# --- Where Relay keeps things ---
case "$PLATFORM" in
    mac)
        CONFIG_ROOT="${HOME}/.config/adb-tunnel"
        STATE_FILE="${HOME}/.config/installed-version"
        GUARD="${CONFIG_ROOT}/adb-tunnel-guard.sh"
        TUNNEL_LOG_GLOB="/tmp/adbtunnel-*.log"
        TUNNEL_ERR_GLOB="/tmp/adbtunnel-*.err"
        UPDATER_LOG="/tmp/adbtunnel-updater.log"
        ;;
    windows)
        [ -n "${APPDATA:-}" ] || { note "APPDATA is not set - run this from Git Bash."; exit 1; }
        CONFIG_ROOT="$(cygpath -u "$APPDATA")/adb-tunnel/config"
        STATE_FILE="$(cygpath -u "$APPDATA")/adb-tunnel/installed-version"
        GUARD="$(cygpath -u "$APPDATA")/adb-tunnel/adb-tunnel-guard.ps1"
        TUNNEL_LOG_GLOB="$(cygpath -u "$APPDATA")/adb-tunnel/adb-tunnel-*.log"
        TUNNEL_ERR_GLOB=""
        UPDATER_LOG="$(cygpath -u "$APPDATA")/adb-tunnel/updater.log"
        ;;
    *)
        CONFIG_ROOT="${HOME}/.config/adb-tunnel"
        STATE_FILE="${HOME}/.config/installed-version"
        GUARD=""
        TUNNEL_LOG_GLOB="${CONFIG_ROOT}/adb-tunnel-*.log"
        TUNNEL_ERR_GLOB=""
        UPDATER_LOG="/tmp/adbtunnel-updater.log"
        ;;
esac

section "Installed state"
note "config dir        : ${CONFIG_ROOT}"
if [ -d "$CONFIG_ROOT" ]; then
    ls -l "$CONFIG_ROOT" 2>/dev/null
    for cfg in "${CONFIG_ROOT}"/*.env; do
        [ -e "$cfg" ] || continue
        note ""
        note "--- ${cfg} (passwords/tokens not printed) ---"
        sed -E 's/^(PASSFILE|KEY)=.*/\1=<set>/' "$cfg"
    done
else
    note "(no config dir - laptop/install.sh has probably never completed here)"
fi
note ""
if [ -f "$STATE_FILE" ]; then
    note "installed VERSION : $(cat "$STATE_FILE" 2>/dev/null)   (${STATE_FILE})"
else
    note "installed VERSION : (none recorded - no nightly update has completed)"
fi

# --- Who owns the adb port ---
section "Port 5037 (the adb port Relay takes over)"
LOCAL_PORT=""
for cfg in "${CONFIG_ROOT}"/*.env; do
    [ -e "$cfg" ] || continue
    LOCAL_PORT="$(sed -n 's/^LOCAL_PORT="\([0-9]*\)".*/\1/p' "$cfg" 2>/dev/null | head -n1)"
    [ -n "$LOCAL_PORT" ] && break
done
LOCAL_PORT="${LOCAL_PORT:-5037}"
note "local port from config: ${LOCAL_PORT}"
case "$PLATFORM" in
    mac)
        lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN 2>/dev/null || note "(nothing listening on ${LOCAL_PORT})"
        ;;
    windows)
        netstat -ano 2>/dev/null | tr -d '\r' | grep ":${LOCAL_PORT} .*LISTENING" || note "(nothing listening on ${LOCAL_PORT})"
        for pid in $(netstat -ano 2>/dev/null | tr -d '\r' | awk -v p=":${LOCAL_PORT}" '$0 ~ p && $0 ~ /LISTENING/ { print $NF }' | sort -u); do
            tasklist //FI "PID eq ${pid}" //FO CSV //NH 2>/dev/null | tr -d '\r'
        done
        ;;
    *)
        if command -v ss >/dev/null 2>&1; then
            ss -ltnp 2>/dev/null | grep -E ":${LOCAL_PORT}\b" || note "(nothing listening on ${LOCAL_PORT})"
        else
            lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN 2>/dev/null || note "(nothing listening on ${LOCAL_PORT})"
        fi
        ;;
esac
note ""
note "A rogue LOCAL adb server here is the classic cause of a half-bound tunnel:"
note "adb clients then talk to a server that has never seen the Control Hub."

# --- Is the tunnel process registered and running? ---
section "Tunnel registration"
case "$PLATFORM" in
    mac)
        note "--- launchd agents ---"
        launchctl list 2>/dev/null | grep -i adbtunnel || note "(no com.adbtunnel agents loaded)"
        for plist in "$HOME"/Library/LaunchAgents/com.adbtunnel.*.plist; do
            [ -f "$plist" ] || continue
            note ""
            note "--- $(basename "$plist") ---"
            # Show whether the agent goes through the guard. An agent that starts
            # ssh directly is a pre-guard install: that is the version where a
            # laptop that worked at first can start failing overnight.
            if grep -q 'adb-tunnel-guard.sh' "$plist"; then
                note "runs through adb-tunnel-guard.sh  (guard wiring: present)"
            else
                note "runs ssh DIRECTLY - no adb-tunnel-guard.sh in ProgramArguments"
                note "  ^ this install predates the rogue-adb guard; re-run laptop/install.sh"
            fi
            sed -n '1,80p' "$plist" | grep -A30 'ProgramArguments' | head -40
        done
        note ""
        note "--- guard script ---"
        if [ -f "$GUARD" ]; then
            ls -l "$GUARD"
        else
            note "MISSING: ${GUARD}"
            note "  If the LaunchAgent above does not name it either, this laptop is on"
            note "  a pre-guard install - re-run laptop/install.sh."
        fi
        ;;
    windows)
        powershell -NoProfile -Command "Get-ScheduledTask -TaskName 'ADBTunnel*' -ErrorAction SilentlyContinue | Select-Object TaskName,State | Format-Table -AutoSize" 2>/dev/null || note "(could not query scheduled tasks)"
        if [ -f "$GUARD" ]; then ls -l "$GUARD"; else note "MISSING: ${GUARD}"; fi
        ;;
    *)
        systemctl --user list-units 'adb-tunnel*' --no-pager 2>/dev/null || note "(no systemd --user units)"
        pgrep -af 'ssh .* -L ' 2>/dev/null || note "(no Relay-looking ssh process)"
        ;;
esac

# --- What does adb itself see? ---
section "adb's view"
if command -v adb >/dev/null 2>&1; then
    note "adb version: $(run_with_timeout 10 adb version 2>/dev/null | head -n1)"
    note ""
    note "--- adb -P ${LOCAL_PORT} devices -l ---"
    run_with_timeout 20 adb -P "$LOCAL_PORT" devices -l 2>&1 | sed 's/^/  /'
    note ""
    note "Note: the device list can be stale. Force real traffic to be sure:"
    note "  adb -P ${LOCAL_PORT} -s 192.168.43.1:5555 shell echo test"
    if run_with_timeout 20 adb -P "$LOCAL_PORT" -s 192.168.43.1:5555 shell echo test >/dev/null 2>&1; then
        note "  -> Control Hub answered through the tunnel."
    else
        note "  -> Control Hub did NOT answer through the tunnel (or the probe timed out)."
    fi
else
    note "adb is not on PATH here (Android Studio's own adb may still be installed)."
fi

# --- Logs ---
section "Logs (last 40 lines each)"
for f in $TUNNEL_LOG_GLOB $TUNNEL_ERR_GLOB "$UPDATER_LOG"; do
    [ -f "$f" ] || continue
    # Skip the updater log when the glob already picked it up.
    note ""
    note "--- ${f} ---"
    tail -n 40 "$f" 2>/dev/null
done

section "Done"
note "Keep this output before re-running laptop/install.sh - reinstalling"
note "replaces exactly the state that explains the failure."