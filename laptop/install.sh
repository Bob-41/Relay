#!/usr/bin/env bash
# install.sh (laptop side)
# Interactive on first run - sets up a persistent SSH tunnel to the bridge's
# shared adb server, and saves the config so it can be replayed
# non-interactively via `--auto <config_file>` (what the auto-updater calls).
#
# Auto-update only registers for SSH-key auth. Password-auth tunnels are
# NOT auto-updated - there's no safe way to replay a stored password
# unattended without keeping a second, more exposed copy of it; you'd have
# to re-run this interactively to pick up updates.
#
# Run ON the laptop: `bash install.sh` in Git Bash (Windows) or Terminal (Mac/Linux).

set -euo pipefail

AUTO=0
AUTO_CONFIG=""
if [ "${1:-}" = "--auto" ]; then
    AUTO=1
    AUTO_CONFIG="${2:-}"
    [ -z "$AUTO_CONFIG" ] && { echo "--auto requires a config file path."; exit 1; }
fi

case "$(uname -s)" in
    Darwin) PLATFORM="mac" ;;
    Linux)
        if grep -qi microsoft /proc/version 2>/dev/null; then PLATFORM="wsl"; else PLATFORM="linux"; fi
        ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
    *) echo "Unrecognized platform: $(uname -s). Aborting."; exit 1 ;;
esac

if [ "$PLATFORM" = "wsl" ]; then
    echo "WSL detected - separate network namespace from Windows. Run this from"
    echo "Git Bash on native Windows instead if Android Studio runs there."
    exit 1
fi

if [ "$PLATFORM" = "windows" ]; then
    MISSING=""
    for bin in ssh ssh-keygen cygpath; do
        command -v "$bin" >/dev/null 2>&1 || MISSING="$MISSING $bin"
    done
    if [ -n "$MISSING" ]; then
        echo "Missing:$MISSING - install Git for Windows (with OpenSSH option) and re-run from Git Bash."
        exit 1
    fi
    SSH_BIN_WIN="$(cygpath -w "$(command -v ssh)")"
fi

CONFIG_ROOT="${HOME}/.config/adb-tunnel"
[ "$PLATFORM" = "windows" ] && CONFIG_ROOT="$(cygpath -u "$APPDATA")/adb-tunnel/config"
mkdir -p "$CONFIG_ROOT"

if [ "$AUTO" = "1" ]; then
    [ -f "$AUTO_CONFIG" ] || { echo "Config not found: $AUTO_CONFIG"; exit 1; }
    # shellcheck disable=SC1090
    source "$AUTO_CONFIG"
    echo "=== ADB Tunnel auto-update (${REMOTE_HOST}), replaying saved config ==="
    if [ "$AUTH_CHOICE" != "1" ]; then
        echo "Password-auth config found under --auto - this should never happen"
        echo "(password configs aren't supposed to get an updater registered)."
        exit 1
    fi
    if ! ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 "${REMOTE_USER}@${REMOTE_HOST}" 'echo ok' >/dev/null 2>&1; then
        echo "Key auth check failed for ${REMOTE_HOST} - not touching the existing tunnel."
        echo "(Key may be revoked, host may be down. Fix manually, don't blind-retry.)"
        exit 1
    fi
else
    echo "=== ADB Bridge Tunnel Setup ==="
    read -rp "Remote host (IP, Tailscale address, or hostname): " REMOTE_HOST
    [ -z "$REMOTE_HOST" ] && { echo "Aborting."; exit 1; }
    read -rp "Remote username: " REMOTE_USER
    [ -z "$REMOTE_USER" ] && { echo "Aborting."; exit 1; }
    read -rp "Remote adb server port [5037]: " REMOTE_PORT; REMOTE_PORT="${REMOTE_PORT:-5037}"
    read -rp "Local port to forward to [5037]: " LOCAL_PORT; LOCAL_PORT="${LOCAL_PORT:-5037}"

    echo ""
    echo "Auth method:"
    echo "  1) SSH key (recommended - required for auto-update)"
    echo "  2) Password (auto-update will NOT be set up for this tunnel)"
    read -rp "Choice [1]: " AUTH_CHOICE
    AUTH_CHOICE="${AUTH_CHOICE:-1}"

    SAFE_HOST="${REMOTE_HOST//[^a-zA-Z0-9]/_}"
    KEY=""
    PASSFILE=""

    if [ "$AUTH_CHOICE" = "1" ]; then
        KEY="$HOME/.ssh/id_ed25519_${SAFE_HOST}"
        if [ ! -f "$KEY" ]; then
            echo "Generating SSH key..."
            ssh-keygen -t ed25519 -f "$KEY" -N ""
        else
            echo "Existing key found at $KEY, reusing it."
        fi
        echo "Copying key to the remote host. You'll be prompted for its password ONCE."
        if [ "$PLATFORM" != "windows" ] && command -v ssh-copy-id >/dev/null 2>&1; then
            ssh-copy-id -i "${KEY}.pub" -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_HOST}"
        else
            PUBKEY="$(cat "${KEY}.pub")"
            ssh -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_HOST}" \
                "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '${PUBKEY}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
        fi
        if ! ssh -i "$KEY" -o BatchMode=yes "${REMOTE_USER}@${REMOTE_HOST}" 'echo ok' >/dev/null 2>&1; then
            echo "Key auth failed. Aborting."; exit 1
        fi
        echo "Key auth confirmed."
    else
        if ! command -v sshpass >/dev/null 2>&1; then
            echo "sshpass not found (macOS: brew install hudochenkov/sshpass/sshpass). Aborting."
            exit 1
        fi
        read -rsp "Remote password (stored plaintext at ~/.adb-tunnel-pass_${SAFE_HOST}, chmod 600): " REMOTE_PASS
        echo ""
        PASSFILE="$HOME/.adb-tunnel-pass_${SAFE_HOST}"
        printf '%s' "$REMOTE_PASS" > "$PASSFILE"
        chmod 600 "$PASSFILE"
        unset REMOTE_PASS
        if ! sshpass -f "$PASSFILE" ssh -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_HOST}" 'echo ok' >/dev/null 2>&1; then
            echo "Password auth failed. Aborting."; rm -f "$PASSFILE"; exit 1
        fi
        echo "Password auth confirmed. Auto-update will be skipped for this tunnel."
    fi

    AUTO_CONFIG="${CONFIG_ROOT}/${SAFE_HOST}.env"
    cat > "$AUTO_CONFIG" <<EOF
REMOTE_HOST="${REMOTE_HOST}"
REMOTE_USER="${REMOTE_USER}"
REMOTE_PORT="${REMOTE_PORT}"
LOCAL_PORT="${LOCAL_PORT}"
AUTH_CHOICE="${AUTH_CHOICE}"
KEY="${KEY}"
PASSFILE="${PASSFILE}"
PLATFORM="${PLATFORM}"
EOF
    chmod 600 "$AUTO_CONFIG"
fi

SAFE_HOST="${REMOTE_HOST//[^a-zA-Z0-9]/_}"

# --- Port conflict check (same on --auto: catches a stale tunnel before reinstalling) ---
if [ "$PLATFORM" = "windows" ]; then
    if command -v netstat >/dev/null 2>&1 && netstat -ano 2>/dev/null | grep -q ":${LOCAL_PORT} .*LISTENING"; then
        echo "NOTE: something is on local port $LOCAL_PORT already - expected if the old tunnel is still up; it'll be replaced below."
    fi
elif command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$LOCAL_PORT" -sTCP:LISTEN -P >/dev/null 2>&1; then
    echo "NOTE: something is on local port $LOCAL_PORT already - expected if the old tunnel is still up; it'll be replaced below."
fi

# --- Persist/refresh the tunnel (idempotent - safe on --auto too) ---
case "$PLATFORM" in
mac)
    PLIST="$HOME/Library/LaunchAgents/com.adbtunnel.${SAFE_HOST}.plist"
    LABEL="com.adbtunnel.${SAFE_HOST}"
    if [ "$AUTH_CHOICE" = "1" ]; then
        PROGRAM_ARGS="
        <string>/usr/bin/ssh</string>
        <string>-i</string>
        <string>${KEY}</string>
        <string>-N</string>
        <string>-o</string>
        <string>BatchMode=yes</string>
        <string>-o</string>
        <string>ExitOnForwardFailure=yes</string>
        <string>-o</string>
        <string>ServerAliveInterval=15</string>
        <string>-o</string>
        <string>ServerAliveCountMax=3</string>
        <string>-L</string>
        <string>${LOCAL_PORT}:localhost:${REMOTE_PORT}</string>
        <string>${REMOTE_USER}@${REMOTE_HOST}</string>"
    else
        SSHPASS_BIN="$(command -v sshpass)"
        PROGRAM_ARGS="
        <string>${SSHPASS_BIN}</string>
        <string>-f</string>
        <string>${PASSFILE}</string>
        <string>ssh</string>
        <string>-N</string>
        <string>-o</string>
        <string>StrictHostKeyChecking=accept-new</string>
        <string>-o</string>
        <string>ExitOnForwardFailure=yes</string>
        <string>-o</string>
        <string>ServerAliveInterval=15</string>
        <string>-o</string>
        <string>ServerAliveCountMax=3</string>
        <string>-L</string>
        <string>${LOCAL_PORT}:localhost:${REMOTE_PORT}</string>
        <string>${REMOTE_USER}@${REMOTE_HOST}</string>"
    fi
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>${PROGRAM_ARGS}
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/adbtunnel-${SAFE_HOST}.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/adbtunnel-${SAFE_HOST}.err</string>
</dict>
</plist>
EOF
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"

    # Register the updater LaunchAgent (key-auth only), once.
    if [ "$AUTH_CHOICE" = "1" ] && [ "$AUTO" != "1" ]; then
        UPDATER_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/adb-tunnel-updater.sh"
        if [ -f "$UPDATER_SRC" ] && bash -n "$UPDATER_SRC"; then
            UPDATER_DEST="${CONFIG_ROOT}/../adb-tunnel-updater.sh"
            install -m 755 "$UPDATER_SRC" "$UPDATER_DEST" 2>/dev/null || cp "$UPDATER_SRC" "$UPDATER_DEST" && chmod 755 "$UPDATER_DEST"
            UPDATER_PLIST="$HOME/Library/LaunchAgents/com.adbtunnel.updater.plist"
            cat > "$UPDATER_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.adbtunnel.updater</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${UPDATER_DEST}</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key><integer>3</integer>
        <key>Minute</key><integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/adbtunnel-updater.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/adbtunnel-updater.log</string>
</dict>
</plist>
EOF
            launchctl unload "$UPDATER_PLIST" 2>/dev/null || true
            launchctl load "$UPDATER_PLIST"
            echo "Auto-update registered (daily 3am check): /tmp/adbtunnel-updater.log"
        fi
    fi
    echo "LaunchAgent installed and loaded. Log: /tmp/adbtunnel-${SAFE_HOST}.log"
    ;;

windows)
    APPDATA_WIN="$(cygpath -u "$APPDATA")"
    INSTALL_DIR="${APPDATA_WIN}/adb-tunnel"
    mkdir -p "$INSTALL_DIR"
    WRAPPER_BAT="${INSTALL_DIR}/adb-tunnel-${SAFE_HOST}.bat"
    LOG_FILE_WIN="$(cygpath -w "${INSTALL_DIR}/adb-tunnel-${SAFE_HOST}.log")"
    TASK_NAME="ADBTunnel-${SAFE_HOST}"

    if [ "$AUTH_CHOICE" = "1" ]; then
        WIN_KEY="$(cygpath -w "$KEY")"
        cat > "$WRAPPER_BAT" <<EOF
@echo off
:loop
echo [%date% %time%] starting tunnel to ${REMOTE_HOST} >> "${LOG_FILE_WIN}"
"${SSH_BIN_WIN}" -i "${WIN_KEY}" -N -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -L ${LOCAL_PORT}:localhost:${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} >> "${LOG_FILE_WIN}" 2>&1
echo [%date% %time%] tunnel exited, restarting in 5s >> "${LOG_FILE_WIN}"
timeout /t 5 /nobreak >nul
goto loop
EOF
    else
        WIN_PASSFILE="$(cygpath -w "$PASSFILE")"
        SSHPASS_BIN_WIN="$(cygpath -w "$(command -v sshpass)")"
        cat > "$WRAPPER_BAT" <<EOF
@echo off
:loop
echo [%date% %time%] starting tunnel to ${REMOTE_HOST} >> "${LOG_FILE_WIN}"
"${SSHPASS_BIN_WIN}" -f "${WIN_PASSFILE}" "${SSH_BIN_WIN}" -N -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -L ${LOCAL_PORT}:localhost:${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} >> "${LOG_FILE_WIN}" 2>&1
echo [%date% %time%] tunnel exited, restarting in 5s >> "${LOG_FILE_WIN}"
timeout /t 5 /nobreak >nul
goto loop
EOF
    fi
    WIN_WRAPPER_BAT="$(cygpath -w "$WRAPPER_BAT")"

    PS1="${INSTALL_DIR}/install-task-${SAFE_HOST}.ps1"
    cat > "$PS1" <<'PSEOF'
param([string]$TaskName, [string]$Wrapper, [string]$RemoteHost)
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='ssh.exe' or Name='sshpass.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($RemoteHost) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$Action   = New-ScheduledTaskAction -Execute $Wrapper
$Trigger  = New-ScheduledTaskTrigger -AtLogOn
$Settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -DontStopOnIdleEnd -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
PSEOF
    PS1_WIN="$(cygpath -w "$PS1")"
    powershell -NoProfile -ExecutionPolicy Bypass -File "$PS1_WIN" -TaskName "$TASK_NAME" -Wrapper "$WIN_WRAPPER_BAT" -RemoteHost "$REMOTE_HOST"
    echo "Tunnel task '${TASK_NAME}' registered. Log: ${LOG_FILE_WIN}"

    # Register the updater scheduled task (key-auth only), once.
    if [ "$AUTH_CHOICE" = "1" ] && [ "$AUTO" != "1" ]; then
        UPDATER_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/adb-tunnel-updater.sh"
        if [ -f "$UPDATER_SRC" ] && bash -n "$UPDATER_SRC"; then
            UPDATER_DEST="${INSTALL_DIR}/adb-tunnel-updater.sh"
            cp "$UPDATER_SRC" "$UPDATER_DEST"
            BASH_BIN_WIN="$(cygpath -w "$(command -v bash)")"
            UPDATER_DEST_WIN="$(cygpath -w "$UPDATER_DEST")"
            UPD_PS1="${INSTALL_DIR}/install-updater-task.ps1"
            cat > "$UPD_PS1" <<'PSEOF'
param([string]$BashBin, [string]$ScriptPath)
Unregister-ScheduledTask -TaskName "ADBTunnelUpdater" -Confirm:$false -ErrorAction SilentlyContinue
$Action   = New-ScheduledTaskAction -Execute $BashBin -Argument "`"$ScriptPath`""
$Trigger  = New-ScheduledTaskTrigger -Daily -At 3am
$Settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "ADBTunnelUpdater" -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null
PSEOF
            powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$UPD_PS1")" -BashBin "$BASH_BIN_WIN" -ScriptPath "$UPDATER_DEST_WIN"
            echo "Auto-update registered (daily 3am check)."
        fi
    fi
    ;;

linux)
    echo "No auto-start mechanism set up for plain Linux laptops - use a"
    echo "systemd --user unit or cron @reboot to persist this command:"
    if [ "$AUTH_CHOICE" = "1" ]; then
        echo "  ssh -i $KEY -N -o BatchMode=yes -L ${LOCAL_PORT}:localhost:${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST}"
    else
        echo "  sshpass -f $PASSFILE ssh -N -L ${LOCAL_PORT}:localhost:${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST}"
    fi
    echo "Auto-update is not implemented for this path - it's a manual command, not a managed service."
    ;;
esac

if [ "$AUTO" != "1" ]; then
    echo ""
    echo "=== Done ==="
    echo "adb server should be reachable at localhost:${LOCAL_PORT}."
    echo "Quit and reopen Android Studio, confirm the device shows up before deploying."
fi
