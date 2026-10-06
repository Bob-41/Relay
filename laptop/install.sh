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

# Keep the installer easy to scan in a terminal, while leaving redirected logs
# as plain text without ANSI escape sequences. Same helpers as bridge/install.sh -
# keep both in sync if this changes. tput can be flaky in some MSYS/Git Bash
# setups on Windows, which is exactly why this is gated behind -t 1 and
# command -v tput rather than assumed to work.
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
    warning "WSL detected - separate network namespace from Windows. Run this from Git Bash on native Windows instead if Android Studio runs there."
    exit 1
fi

if [ "$PLATFORM" = "windows" ]; then
    MISSING=""
    for bin in ssh ssh-keygen cygpath; do
        command -v "$bin" >/dev/null 2>&1 || MISSING="$MISSING $bin"
    done
    if [ -n "$MISSING" ]; then
        warning "Missing:$MISSING - install Git for Windows (with OpenSSH option) and re-run from Git Bash."
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
    # Configs written before the web-interface forward existed won't have
    # these - default them so auto-update doesn't break existing installs.
    WEB_LOCAL_PORT="${WEB_LOCAL_PORT:-8091}"
    WEB_REMOTE_PORT="${WEB_REMOTE_PORT:-8080}"
    ROBOT_IP="${ROBOT_IP:-192.168.43.1}"
    PANELS_LOCAL_PORT="${PANELS_LOCAL_PORT:-8001}"
    PANELS_REMOTE_PORT="${PANELS_REMOTE_PORT:-8001}"
    # Panels' live-data WebSocket runs on a separate fixed port from its HTTP
    # port (8001) - without this forward the page shell loads but the
    # dashboard itself never initializes. Defaulted for configs saved before
    # this forward existed, same pattern as WEB_LOCAL_PORT above.
    PANELS_WS_LOCAL_PORT="${PANELS_WS_LOCAL_PORT:-8002}"
    PANELS_WS_REMOTE_PORT="${PANELS_WS_REMOTE_PORT:-8002}"
    section "=== ADB Tunnel auto-update (${REMOTE_HOST}), replaying saved config ==="
    if [ "$AUTH_CHOICE" != "1" ]; then
        warning "Password-auth config found under --auto - this should never happen (password configs aren't supposed to get an updater registered)."
        exit 1
    fi
    if ! ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 "${REMOTE_USER}@${REMOTE_HOST}" 'echo ok' >/dev/null 2>&1; then
        warning "Key auth check failed for ${REMOTE_HOST} - not touching the existing tunnel. (Key may be revoked, host may be down. Fix manually, don't blind-retry.)"
        exit 1
    fi
else
    section "=== ADB Bridge Tunnel Setup ==="
    read -rp "Remote host (IP, Tailscale address, or hostname): " REMOTE_HOST
    [ -z "$REMOTE_HOST" ] && { echo "Aborting."; exit 1; }
    read -rp 'Remote username (username that you use to log into the remote host ex: "bob" if you log in as bob): ' REMOTE_USER
    [ -z "$REMOTE_USER" ] && { echo "Aborting."; exit 1; }
    REMOTE_PORT="5037"
    LOCAL_PORT="5037"

    # Control Hub AP mode always assigns itself this address - it's a
    # hardware constant of AP mode, not a per-install variable, same as
    # WEB_REMOTE_PORT below. Not prompted.
    ROBOT_IP="192.168.43.1"

    # Local (laptop-side) forward ports - hardcoded, not prompted, per
    # explicit request. Trade-off: if a laptop already has something
    # bound to 8091 or 8001, ExitOnForwardFailure=yes means the WHOLE
    # tunnel (including the ADB forward) fails to start, and the fix is
    # editing these values in the script rather than answering a prompt.
    WEB_LOCAL_PORT="8091"
    WEB_REMOTE_PORT="8080"
    PANELS_LOCAL_PORT="8001"
    PANELS_REMOTE_PORT="8001"
    PANELS_WS_LOCAL_PORT="8002"
    PANELS_WS_REMOTE_PORT="8002"

    echo ""
    important "Auth method:"
    important "  1) SSH key (recommended - required for auto-update)"
    important "  2) Password (auto-update will NOT be set up for this tunnel)"
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
            warning "Key auth failed. Aborting."; exit 1
        fi
        echo "Key auth confirmed."
    else
        if ! command -v sshpass >/dev/null 2>&1; then
            warning "sshpass not found (macOS: brew install hudochenkov/sshpass/sshpass). Aborting."
            exit 1
        fi
        read -rsp "Remote password (stored plaintext at ~/.adb-tunnel-pass_${SAFE_HOST}, chmod 600): " REMOTE_PASS
        echo ""
        PASSFILE="$HOME/.adb-tunnel-pass_${SAFE_HOST}"
        printf '%s' "$REMOTE_PASS" > "$PASSFILE"
        chmod 600 "$PASSFILE"
        unset REMOTE_PASS
        if ! sshpass -f "$PASSFILE" ssh -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_HOST}" 'echo ok' >/dev/null 2>&1; then
            warning "Password auth failed. Aborting."; rm -f "$PASSFILE"; exit 1
        fi
        echo "Password auth confirmed. Auto-update will be skipped for this tunnel."
    fi

    AUTO_CONFIG="${CONFIG_ROOT}/${SAFE_HOST}.env"
    cat > "$AUTO_CONFIG" <<EOF
REMOTE_HOST="${REMOTE_HOST}"
REMOTE_USER="${REMOTE_USER}"
REMOTE_PORT="${REMOTE_PORT}"
LOCAL_PORT="${LOCAL_PORT}"
ROBOT_IP="${ROBOT_IP}"
WEB_LOCAL_PORT="${WEB_LOCAL_PORT}"
WEB_REMOTE_PORT="${WEB_REMOTE_PORT}"
PANELS_LOCAL_PORT="${PANELS_LOCAL_PORT}"
PANELS_REMOTE_PORT="${PANELS_REMOTE_PORT}"
PANELS_WS_LOCAL_PORT="${PANELS_WS_LOCAL_PORT}"
PANELS_WS_REMOTE_PORT="${PANELS_WS_REMOTE_PORT}"
AUTH_CHOICE="${AUTH_CHOICE}"
KEY="${KEY}"
PASSFILE="${PASSFILE}"
PLATFORM="${PLATFORM}"
EOF
    chmod 600 "$AUTO_CONFIG"
fi

SAFE_HOST="${REMOTE_HOST//[^a-zA-Z0-9]/_}"

# --- Reinstall support: tear down a previous install of THIS tunnel ---------
# Re-running this installer on a laptop that already has a tunnel to this
# bridge is a reinstall, and has to behave like one. Two things have to go, or
# the new tunnel cannot come up cleanly:
#
#   1. The old persistence registration. Two LaunchAgents / Scheduled Tasks for
#      the same host both respawning ssh is a fight, and the old one can win.
#   2. The old tunnel's ssh itself. It keeps holding its forwarded ports after
#      its registration is gone, and ExitOnForwardFailure=yes means ONE held
#      forward kills the WHOLE new tunnel - including the adb forward. This is
#      the same class of bug as the rogue-adb block below: the port is not
#      "busy with our tunnel", it's "busy with a previous one of ours".
#
# Deliberately NOT run under --auto. That path replays a saved config onto a
# live tunnel that laptops are using right now; tearing that down unattended
# would turn a routine nightly update into an outage. The guard script handles
# the respawn gap in normal operation - this only handles an explicit rerun.
teardown_previous_install() {
    local removed=0 pid name check_port cmdline killed=0
    # The four forwarded ports are hardcoded constants, never prompted, so a
    # laptop can only ever hold ONE Relay tunnel - a second registration for
    # the same ports is always a leftover, never a legitimate second bridge.
    # Match on the artifact pattern, never on SAFE_HOST: SAFE_HOST is derived
    # from REMOTE_HOST, so the same machine named two ways (`raspi` vs
    # `100.105.201.65`) yields two different names, and a name-scoped teardown
    # silently misses the old one. That is not hypothetical - the README tells
    # Windows users to switch to the Tailscale IP, so hostname -> IP is a
    # documented migration. Worse, the nightly updater globs every *.env, so
    # the missed config gets replayed every night and re-registers the stale
    # agent. Sweep the whole pattern instead.
    case "$PLATFORM" in
        mac)
            # `com.adbtunnel.updater.plist` is the updater agent, not a tunnel -
            # never unload it here or nightly updates would stop registering.
            for prev_plist in "$HOME"/Library/LaunchAgents/com.adbtunnel.*.plist; do
                case "$(basename "$prev_plist")" in
                    com.adbtunnel.updater.plist) continue ;;
                esac
                [ -f "$prev_plist" ] || continue
                important "Previous Relay tunnel found ($(basename "$prev_plist" .plist | sed 's/^com.adbtunnel.//')) - uninstalling it first."
                # Unload BEFORE killing anything below. While the plist is
                # still loaded, launchd respawns ssh the instant it dies, so a
                # kill here would just race the agent recreating the tunnel.
                launchctl unload "$prev_plist" 2>/dev/null || true
                rm -f "$prev_plist"
                removed=1
            done
            # Reap by PORT, not by name. An ssh holding one of the four forwarded
            # ports IS a Relay tunnel for this laptop - the ports are
            # hardcoded, so there is no legitimate second tunnel. Name-scoped
            # matching would miss a tunnel registered under a different host
            # string, which is exactly the hostname -> Tailscale IP case.
            #
            # Check ALL four ports, not just LOCAL_PORT: with
            # ExitOnForwardFailure=yes a stale tunnel ssh holding only 8091
            # still takes the whole new tunnel down, adb forward included.
            # Only `ssh` is ever killed, and only when it actually looks like one of
            # our forwards - never a stranger's ssh tunnel that happens to sit
            # on 8091. A non-ssh listener is somebody's dev server: reported,
            # not touched, same policy as the rogue-adb block below.
            #
            # LOCAL_PORT is exempt from the command-line test: 5037 is Relay's
            # by definition (it is the adb port every Android Studio uses), so
            # any ssh holding it is one of ours. The web ports are only
            # reaped when the command line shows a Relay forward - the robot
            # IP, or a localhost forward onto LOCAL_PORT.
            #
            # lsof here is macOS-only; the Windows equivalent is the PowerShell
            # block further down, which stops ssh.exe for this host before it
            # re-registers.
            for check_port in "$LOCAL_PORT" "$WEB_LOCAL_PORT" "$PANELS_LOCAL_PORT" "$PANELS_WS_LOCAL_PORT"; do
                for pid in $(lsof -nP -tiTCP:"$check_port" -sTCP:LISTEN 2>/dev/null | sort -u); do
                    name="$(basename "$(ps -p "$pid" -o comm= 2>/dev/null)")"
                    if [ "$name" != "ssh" ]; then
                        important "  NOTE: port $check_port is held by ${name:-unknown} (pid $pid), not ssh - leaving it alone."
                        continue
                    fi
                    # Distinguish our own forward from an unrelated ssh tunnel
                    # on the same port. Under --auto this never runs, so the
                    # only ssh we can be looking at is one Relay left behind -
                    # but an interactive rerun must not kill a stranger's
                    # tunnel just because they picked 8091.
                    cmdline="$(ps -p "$pid" -o args= 2>/dev/null || true)"
                    if [ "$check_port" != "$LOCAL_PORT" ] \
                        && ! printf '%s' "$cmdline" | grep -q -- "$ROBOT_IP" \
                        && ! printf '%s' "$cmdline" | grep -q "localhost:${REMOTE_PORT}"; then
                        important "  NOTE: port $check_port is held by an ssh that is not a Relay forward (pid $pid) - leaving it alone."
                        important "        If the new tunnel fails to bind, stop that ssh and re-run this installer."
                        continue
                    fi
                    echo "  stopping stale tunnel ssh (pid $pid) still holding port $check_port"
                    kill "$pid" 2>/dev/null && killed=1
                done
            done
            ;;
        windows)
            local startup_dir
            startup_dir="$(cygpath -u "$APPDATA")/Microsoft/Windows/Start Menu/Programs/Startup"
            # Same sweep as macOS: match the task/Startup patterns, never
            # SAFE_HOST. ADBTunnelUpdater is the updater task, not a tunnel -
            # never unregister it here.
            local prev_task
            for prev_task in $(powershell -NoProfile -ExecutionPolicy Bypass -Command \
                "Get-ScheduledTask -TaskName 'ADBTunnel*' -ErrorAction SilentlyContinue | ForEach-Object { \$_.TaskName }" 2>/dev/null); do
                case "$prev_task" in
                    ADBTunnelUpdater) continue ;;
                esac
                important "Previous Relay tunnel task '${prev_task}' found - uninstalling it first."
                powershell -NoProfile -ExecutionPolicy Bypass -Command \
                    "Unregister-ScheduledTask -TaskName '${prev_task}' -Confirm:\$false -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
                removed=1
            done
            # Unregister up front rather than relying on the registration step
            # below, so a run that ends up denied elevation does not silently
            # leave the old task running alongside the new Startup-folder copy.
            for prev_entry in "$startup_dir"/adb-tunnel-*.vbs "$startup_dir"/adb-tunnel-*.bat; do
                [ -f "$prev_entry" ] || continue
                [ "$removed" = "1" ] || important "Previous Relay Startup-folder entry found - uninstalling it first."
                rm -f "$prev_entry"
                removed=1
            done
            ;;
        linux)
            # Plain Linux installs no persistence at all - the installer only
            # prints a command for the user to wire up themselves. Nothing
            # registered here to tear down.
            ;;
    esac
    # Stale saved configs for the same ports. The nightly updater globs
    # ${CONFIG_ROOT}/*.env and replays each one, so a config left behind by a
    # differently-named host would re-register its agent every night and undo
    # the teardown above - the tunnel would come back on its own. Keep only the
    # config this run is writing.
    local stale_cfg current_cfg
    current_cfg="${CONFIG_ROOT}/${SAFE_HOST}.env"
    for stale_cfg in "$CONFIG_ROOT"/*.env; do
        [ -e "$stale_cfg" ] || continue
        [ "$stale_cfg" = "$current_cfg" ] && continue
        echo "  removing stale config $(basename "$stale_cfg") (would be replayed by the nightly updater)"
        rm -f "$stale_cfg"
        removed=1
    done

    [ "$removed" = "1" ] && echo "Previous install removed. Continuing with a fresh install."
    [ "$killed" = "1" ] && sleep 1   # let the kernel release the listening socket
    return 0
}

if [ "$AUTO" != "1" ]; then
    teardown_previous_install
fi

# windows_listener_image <port> - print the lowercased image name of whatever
# is listening on <port> (adb.exe, ssh.exe, ...), or nothing if the port is
# free. Used both to clear a rogue adb before installing and to prove the
# tunnel's own ssh owns the port afterwards - the same question asked at two
# points, so it lives in one place and cannot drift.
#
# netstat/tasklist emit CRLF - a trailing \r survives into the last awk field
# (PID, then image name) and silently breaks string comparisons below even
# though the printed value looks correct. Strip it before it's used anywhere,
# not just where it happens to bite.
windows_listener_image() {
    local port="$1" listener_pid
    listener_pid="$(netstat -ano 2>/dev/null | tr -d '\r' \
        | awk -v p=":${port}" '$0 ~ p && $0 ~ /LISTENING/ { print $NF; exit }')"
    [ -n "$listener_pid" ] || return 0
    tasklist //FI "PID eq ${listener_pid}" //FO CSV //NH 2>/dev/null | tr -d '\r' \
        | awk -F'","' 'NR == 1 { gsub(/"/, "", $1); print tolower($1); exit }'
}

# --- Clear a rogue local adb server off LOCAL_PORT before it can block the tunnel ---
# LOCAL_PORT (default 5037) is ALWAYS supposed to be an adb server - unlike
# WEB_LOCAL_PORT/PANELS_LOCAL_PORT below, which might legitimately be someone's
# dev server and must NOT be touched automatically. A local adb server here is
# most often auto-spawned by Android Studio itself (or left over from a manual
# `adb` invocation) and is always safe to ask to shut down via `adb kill-server`.
if [ "$PLATFORM" = "windows" ]; then
    if command -v netstat >/dev/null 2>&1 && netstat -ano 2>/dev/null | grep -q ":${LOCAL_PORT} .*LISTENING"; then
        LOCAL_PID="$(netstat -ano 2>/dev/null | tr -d '\r' | awk -v p=":${LOCAL_PORT}" '$0 ~ p && $0 ~ /LISTENING/ {print $NF; exit}')"
        LOCAL_IMAGE="$(windows_listener_image "$LOCAL_PORT")"
        if [ "$LOCAL_IMAGE" = "adb.exe" ] && command -v adb >/dev/null 2>&1; then
            important "Local adb server already on port ${LOCAL_PORT} (PID ${LOCAL_PID}) - shutting it down before starting the tunnel."
            adb -P "${LOCAL_PORT}" kill-server >/dev/null 2>&1 || true
            sleep 1
            netstat -ano 2>/dev/null | grep -q ":${LOCAL_PORT} .*LISTENING" && \
                warning "port ${LOCAL_PORT} still held after kill-server - tunnel setup may fail."
        else
            important "NOTE: something non-adb is on local port ${LOCAL_PORT} (PID ${LOCAL_PID}, image ${LOCAL_IMAGE:-unknown}) - not touching it automatically."
        fi
    fi
elif command -v lsof >/dev/null 2>&1; then
    # `|| true`: lsof exits 1 when nothing is listening, and under
    # `set -eo pipefail` that would abort the whole installer right here.
    LOCAL_PID="$(lsof -tiTCP:"${LOCAL_PORT}" -sTCP:LISTEN -P 2>/dev/null | head -n1 || true)"
    if [ -n "$LOCAL_PID" ]; then
        LOCAL_CMD="$(ps -p "$LOCAL_PID" -o comm= 2>/dev/null | xargs -n1 basename 2>/dev/null || true)"
        if [ "$LOCAL_CMD" = "adb" ] && command -v adb >/dev/null 2>&1; then
            important "Local adb server already on port ${LOCAL_PORT} (PID ${LOCAL_PID}) - shutting it down before starting the tunnel."
            adb -P "${LOCAL_PORT}" kill-server >/dev/null 2>&1 || true
            sleep 1
            lsof -iTCP:"${LOCAL_PORT}" -sTCP:LISTEN -P >/dev/null 2>&1 && \
                warning "port ${LOCAL_PORT} still held after kill-server - tunnel setup may fail."
        else
            important "NOTE: something non-adb is on local port ${LOCAL_PORT} (PID ${LOCAL_PID}, command ${LOCAL_CMD:-unknown}) - not touching it automatically."
        fi
    fi
fi

# --- Port conflict check for the web-interface forwards (warn-only, never auto-killed) ---
for CHECK_PORT in "$WEB_LOCAL_PORT" "$PANELS_LOCAL_PORT" "$PANELS_WS_LOCAL_PORT"; do
    if [ "$PLATFORM" = "windows" ]; then
        if command -v netstat >/dev/null 2>&1 && netstat -ano 2>/dev/null | grep -q ":${CHECK_PORT} .*LISTENING"; then
            important "NOTE: something is on local port $CHECK_PORT already - expected if the old tunnel is still up; it'll be replaced below. If this is the web-interface port and it's a leftover dev server (Tomcat/webpack/etc. commonly squat 8080), pick a different WEB_LOCAL_PORT instead of assuming it's safe to kill."
        fi
    elif command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$CHECK_PORT" -sTCP:LISTEN -P >/dev/null 2>&1; then
        important "NOTE: something is on local port $CHECK_PORT already - expected if the old tunnel is still up; it'll be replaced below. If this is the web-interface port and it's a leftover dev server (Tomcat/webpack/etc. commonly squat 8080), pick a different WEB_LOCAL_PORT instead of assuming it's safe to kill."
    fi
done

# --- Persist/refresh the tunnel (idempotent - safe on --auto too) ---
case "$PLATFORM" in
mac)
    PLIST="$HOME/Library/LaunchAgents/com.adbtunnel.${SAFE_HOST}.plist"
    LABEL="com.adbtunnel.${SAFE_HOST}"

    # Guard that runs before EVERY (re)start of the tunnel's ssh (launchd
    # respawns it after sleep/wake, network changes, etc.). Rewritten on every
    # install/auto-update so it can't drift from this script.
    GUARD="${CONFIG_ROOT}/adb-tunnel-guard.sh"
    cat > "$GUARD" <<'GUARD_EOF'
#!/bin/bash
# adb-tunnel-guard.sh - written by laptop/install.sh, run by the LaunchAgent
# before every (re)start of the tunnel's ssh:
#     adb-tunnel-guard.sh LOCAL_PORT command [args...]
#
# Why: when the tunnel drops (sleep/wake, network change), nothing owns
# 127.0.0.1:LOCAL_PORT until launchd respawns ssh. If Android Studio or a
# stray `adb` call runs in that gap it auto-spawns a LOCAL adb server on that
# port, and the respawned ssh can then no longer bind it - so adb clients end
# up talking to a local server that has never seen the robot. Shut a local adb
# server down before starting ssh. Anything on the port that is NOT adb is
# left alone (ssh then fails loudly on its bind instead of being killed here).
PATH=/usr/bin:/bin:/usr/sbin:/sbin
PORT="${1:?usage: adb-tunnel-guard.sh LOCAL_PORT command [args...]}"
shift
[ "$#" -gt 0 ] || { echo "adb-tunnel-guard: no command given" >&2; exit 2; }

log() { printf '%s adb-tunnel-guard: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2; }

for PID in $(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | sort -u); do
    NAME="$(basename "$(ps -p "$PID" -o comm= 2>/dev/null)")"
    if [ "$NAME" = "adb" ]; then
        log "local adb server (pid $PID) is holding port $PORT - shutting it down."
        # Same request `adb kill-server` sends. Speaking it directly means we
        # don't depend on finding an adb binary on launchd's minimal PATH.
        ( exec 3<>"/dev/tcp/localhost/$PORT" && printf '0009host:kill' >&3 ) 2>/dev/null || true
        sleep 1
        if lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | grep -qx "$PID"; then
            log "WARNING: pid $PID still holds port $PORT after the kill request."
        fi
    else
        log "port $PORT is held by a non-adb process (pid $PID, ${NAME:-unknown}) - leaving it alone."
    fi
done

exec "$@"
GUARD_EOF
    chmod 755 "$GUARD"

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
        <string>127.0.0.1:${LOCAL_PORT}:localhost:${REMOTE_PORT}</string>
        <string>-L</string>
        <string>${WEB_LOCAL_PORT}:${ROBOT_IP}:${WEB_REMOTE_PORT}</string>
        <string>-L</string>
        <string>${PANELS_LOCAL_PORT}:${ROBOT_IP}:${PANELS_REMOTE_PORT}</string>
        <string>-L</string>
        <string>${PANELS_WS_LOCAL_PORT}:${ROBOT_IP}:${PANELS_WS_REMOTE_PORT}</string>
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
        <string>127.0.0.1:${LOCAL_PORT}:localhost:${REMOTE_PORT}</string>
        <string>-L</string>
        <string>${WEB_LOCAL_PORT}:${ROBOT_IP}:${WEB_REMOTE_PORT}</string>
        <string>-L</string>
        <string>${PANELS_LOCAL_PORT}:${ROBOT_IP}:${PANELS_REMOTE_PORT}</string>
        <string>-L</string>
        <string>${PANELS_WS_LOCAL_PORT}:${ROBOT_IP}:${PANELS_WS_REMOTE_PORT}</string>
        <string>${REMOTE_USER}@${REMOTE_HOST}</string>"
    fi

    # Run whichever ssh command was chosen above through the guard.
    PROGRAM_ARGS="
        <string>/bin/bash</string>
        <string>${GUARD}</string>
        <string>${LOCAL_PORT}</string>${PROGRAM_ARGS}"
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
    important "LaunchAgent installed and loaded. Log: /tmp/adbtunnel-${SAFE_HOST}.log"
    ;;

windows)
    APPDATA_WIN="$(cygpath -u "$APPDATA")"
    INSTALL_DIR="${APPDATA_WIN}/adb-tunnel"
    mkdir -p "$INSTALL_DIR"
    WRAPPER_BAT="${INSTALL_DIR}/adb-tunnel-${SAFE_HOST}.bat"
    LOG_FILE_WIN="$(cygpath -w "${INSTALL_DIR}/adb-tunnel-${SAFE_HOST}.log")"
    TASK_NAME="ADBTunnel-${SAFE_HOST}"

    # Guard script: run before EVERY (re)start of the tunnel's ssh, including
    # the .bat loop's 5-second respawn. Rewritten on every install/auto-update
    # so it can't drift from this script.
    #
    # Why this exists on Windows too, not just macOS: when the tunnel drops,
    # nothing owns 127.0.0.1:LOCAL_PORT until the loop respawns ssh. If Android
    # Studio or a stray `adb` call runs in that gap it auto-spawns a LOCAL adb
    # server on that port. ssh then binds only [::1] (with ExitOnForwardFailure
    # set, OpenSSH counts a forward as successful if either loopback address
    # binds), and adb clients on 127.0.0.1 end up talking to a local server that
    # has never seen the robot. Windows is if anything more exposed than macOS
    # here, because this loop respawns constantly rather than only on failure.
    # A non-adb listener is left alone - ssh then fails loudly on its bind.
    GUARD_PS1="${INSTALL_DIR}/adb-tunnel-guard.ps1"
    cat > "$GUARD_PS1" <<'GUARD_EOF'
param([int]$Port)
# adb-tunnel-guard.ps1 - written by laptop/install.sh, run by the tunnel's
# .bat before every (re)start of ssh. Windows counterpart of the macOS
# adb-tunnel-guard.sh.
$ErrorActionPreference = 'SilentlyContinue'
$pids = @(Get-NetTCPConnection -State Listen -LocalPort $Port |
         Select-Object -ExpandProperty OwningProcess -Unique)
foreach ($procId in $pids) {
    $proc = Get-Process -Id $procId
    if (-not $proc -or $proc.ProcessName -ne 'adb') { continue }
    Write-Output ("{0} adb-tunnel-guard: local adb server (pid {1}) is holding port {2} - shutting it down." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $procId, $Port)
    # Ask nicely first - the same request `adb kill-server` sends. Only fall
    # back to a hard stop if the daemon ignored it.
    & adb -P $Port kill-server | Out-Null
    Start-Sleep -Milliseconds 700
    if (Get-NetTCPConnection -State Listen -LocalPort $Port |
        Where-Object { $_.OwningProcess -eq $procId }) {
        Write-Output ("{0} adb-tunnel-guard: pid {1} still holds port {2} - stopping it." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $procId, $Port)
        Stop-Process -Id $procId -Force
        Start-Sleep -Milliseconds 400
        # Say so if it is STILL there. $ErrorActionPreference hides the reason
        # Stop-Process failed (usually UAC), and without this the ssh bind that
        # follows half-fails silently - the exact failure this guard exists to
        # prevent. Mirrors the macOS guard's final warning.
        if (Get-NetTCPConnection -State Listen -LocalPort $Port |
            Where-Object { $_.OwningProcess -eq $procId }) {
            Write-Output ("{0} adb-tunnel-guard: WARNING - pid {1} still holds port {2} after the stop. Run this installer from an elevated prompt, or close the program using adb." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $procId, $Port)
        }
    }
}
exit 0
GUARD_EOF
    GUARD_PS1_WIN="$(cygpath -w "$GUARD_PS1")"
    # Cheap native pre-check so the common case (nothing on the port) does not
    # pay PowerShell startup cost five times a minute.
    GUARD_LINE="netstat -ano | findstr /R \":${LOCAL_PORT} .*LISTENING\" >nul 2>&1 && powershell -NoProfile -ExecutionPolicy Bypass -File \"${GUARD_PS1_WIN}\" -Port ${LOCAL_PORT} >> \"${LOG_FILE_WIN}\" 2>&1"

    if [ "$AUTH_CHOICE" = "1" ]; then
        WIN_KEY="$(cygpath -w "$KEY")"
        cat > "$WRAPPER_BAT" <<EOF
@echo off
:loop
echo [%date% %time%] starting tunnel to ${REMOTE_HOST} >> "${LOG_FILE_WIN}"
${GUARD_LINE}
"${SSH_BIN_WIN}" -i "${WIN_KEY}" -N -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -L 127.0.0.1:${LOCAL_PORT}:localhost:${REMOTE_PORT} -L ${WEB_LOCAL_PORT}:${ROBOT_IP}:${WEB_REMOTE_PORT} -L ${PANELS_LOCAL_PORT}:${ROBOT_IP}:${PANELS_REMOTE_PORT} -L ${PANELS_WS_LOCAL_PORT}:${ROBOT_IP}:${PANELS_WS_REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} >> "${LOG_FILE_WIN}" 2>&1
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
${GUARD_LINE}
"${SSHPASS_BIN_WIN}" -f "${WIN_PASSFILE}" "${SSH_BIN_WIN}" -N -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -L 127.0.0.1:${LOCAL_PORT}:localhost:${REMOTE_PORT} -L ${WEB_LOCAL_PORT}:${ROBOT_IP}:${WEB_REMOTE_PORT} -L ${PANELS_LOCAL_PORT}:${ROBOT_IP}:${PANELS_REMOTE_PORT} -L ${PANELS_WS_LOCAL_PORT}:${ROBOT_IP}:${PANELS_WS_REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} >> "${LOG_FILE_WIN}" 2>&1
echo [%date% %time%] tunnel exited, restarting in 5s >> "${LOG_FILE_WIN}"
timeout /t 5 /nobreak >nul
goto loop
EOF
    fi
    WIN_WRAPPER_BAT="$(cygpath -w "$WRAPPER_BAT")"
    # Task Scheduler runs a .bat through a visible cmd.exe window.  Use
    # wscript.exe as the task action instead so the persistent tunnel is
    # genuinely backgrounded; closing a stray console must never be required
    # to keep the Control Hub visible in Android Studio.
    WRAPPER_VBS="${INSTALL_DIR}/adb-tunnel-${SAFE_HOST}.vbs"
    cat > "$WRAPPER_VBS" <<EOF
Set shell = CreateObject("WScript.Shell")
shell.Run "cmd.exe /c ""${WIN_WRAPPER_BAT}""", 0, True
EOF
    WIN_WRAPPER_VBS="$(cygpath -w "$WRAPPER_VBS")"

    PS1="${INSTALL_DIR}/install-task-${SAFE_HOST}.ps1"
    cat > "$PS1" <<'PSEOF'
param([string]$TaskName, [string]$Launcher, [string]$RemoteHost)
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='ssh.exe' or Name='sshpass.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($RemoteHost) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
try {
    $Action   = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\wscript.exe" -Argument "`"$Launcher`""
    $Trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $Settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -DontStopOnIdleEnd -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    exit 0
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
PSEOF
    PS1_WIN="$(cygpath -w "$PS1")"
    STARTUP_DIR="$(cygpath -u "$APPDATA")/Microsoft/Windows/Start Menu/Programs/Startup"
    STARTUP_VBS="${STARTUP_DIR}/adb-tunnel-${SAFE_HOST}.vbs"
    STARTUP_BAT="${STARTUP_DIR}/adb-tunnel-${SAFE_HOST}.bat"
    if powershell -NoProfile -ExecutionPolicy Bypass -File "$PS1_WIN" -TaskName "$TASK_NAME" -Launcher "$WIN_WRAPPER_VBS" -RemoteHost "$REMOTE_HOST"; then
        important "Tunnel task '${TASK_NAME}' registered via Scheduled Task. Log: ${LOG_FILE_WIN}"
        rm -f "$STARTUP_BAT" "$STARTUP_VBS"  # in case an earlier run fell back to Startup
    else
        important "Scheduled Task creation was denied on this machine (needs elevation here) - falling back to Startup-folder persistence."
        mkdir -p "$STARTUP_DIR"
        cp "$WRAPPER_VBS" "$STARTUP_VBS"
        rm -f "$STARTUP_BAT"
        echo "Startup entry installed: ${STARTUP_VBS}"
        # The Startup folder only runs at the next logon. Launch the same
        # hidden-window VBS wrapper right now, backgrounded - its Shell.Run
        # call waits on the reconnect loop inside WRAPPER_BAT, which never
        # exits in normal operation, so running it in the foreground here
        # would hang this installer instead of just starting the tunnel.
        # This makes the port-liveness check below verify the fallback
        # immediately, rather than guaranteedly failing on first install.
        WIN_STARTUP_VBS="$(cygpath -w "$STARTUP_VBS")"
        wscript.exe "$WIN_STARTUP_VBS" >/dev/null 2>&1 &
        disown 2>/dev/null || true
        important "Started the Startup-folder tunnel now (no visible console window); it will also restart at your next logon."
    fi

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
try {
    $Action   = New-ScheduledTaskAction -Execute $BashBin -Argument "`"$ScriptPath`""
    $Trigger  = New-ScheduledTaskTrigger -Daily -At 3am
    $Settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName "ADBTunnelUpdater" -Action $Action -Trigger $Trigger -Settings $Settings -Force -ErrorAction Stop | Out-Null
    exit 0
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
PSEOF
            if powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$UPD_PS1")" -BashBin "$BASH_BIN_WIN" -ScriptPath "$UPDATER_DEST_WIN"; then
                echo "Auto-update registered (daily 3am check)."
            else
                echo "Auto-update could not be registered (Scheduled Task creation denied on this machine)."
                echo "There's no Startup-folder equivalent for a daily check - you'll need to 'git pull' and re-run install.sh manually to pick up fixes."
            fi
        fi
    fi
    ;;

linux)
    echo "No auto-start mechanism set up for plain Linux laptops - use a"
    echo "systemd --user unit or cron @reboot to persist this command:"
    if [ "$AUTH_CHOICE" = "1" ]; then
        echo "  ssh -i $KEY -N -o BatchMode=yes -L ${LOCAL_PORT}:localhost:${REMOTE_PORT} -L ${WEB_LOCAL_PORT}:${ROBOT_IP}:${WEB_REMOTE_PORT} -L ${PANELS_LOCAL_PORT}:${ROBOT_IP}:${PANELS_REMOTE_PORT} -L ${PANELS_WS_LOCAL_PORT}:${ROBOT_IP}:${PANELS_WS_REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST}"
    else
        echo "  sshpass -f $PASSFILE ssh -N -L ${LOCAL_PORT}:localhost:${REMOTE_PORT} -L ${WEB_LOCAL_PORT}:${ROBOT_IP}:${WEB_REMOTE_PORT} -L ${PANELS_LOCAL_PORT}:${ROBOT_IP}:${PANELS_REMOTE_PORT} -L ${PANELS_WS_LOCAL_PORT}:${ROBOT_IP}:${PANELS_WS_REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST}"
    fi
    echo "Auto-update is not implemented for this path - it's a manual command, not a managed service."
    ;;
esac

# --- Verify the tunnel actually came up before declaring success ---
# launchctl load / Register-ScheduledTask can report success even when the
# underlying ssh process immediately dies (e.g. ExitOnForwardFailure killing
# ALL forwards over a single port conflict) - a loader exit code only tells
# you the service was registered, not that it's running. Check the real
# local port state directly instead of trusting that.
HEALTH_OK=1
if [ "$PLATFORM" = "mac" ]; then
    # The adb port only counts as up if the tunnel's ssh owns it on 127.0.0.1.
    # "Something is listening" is not enough: it also passes for a rogue local
    # adb server, or for a half-bound tunnel holding only [::1]. Poll instead
    # of a fixed sleep - the guard may spend a second shutting a rogue adb
    # server down before ssh even starts.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        lsof -nP -iTCP@127.0.0.1:"$LOCAL_PORT" -sTCP:LISTEN -Fc 2>/dev/null | grep -qx 'cssh' && break
        sleep 1
    done
    if ! lsof -nP -iTCP@127.0.0.1:"$LOCAL_PORT" -sTCP:LISTEN -Fc 2>/dev/null | grep -qx 'cssh'; then
        warning "127.0.0.1:${LOCAL_PORT} is not held by the tunnel's ssh - adb clients on this machine will not reach the bridge."
        HEALTH_OK=0
    fi
    # Same ownership standard as the adb port above - assert the tunnel's own
    # ssh holds it, not merely that something is listening. A bare liveness
    # check passes for a leftover listener from a previous install.
    #
    # Deliberately NOT filtered to @127.0.0.1 like the adb port is. These three
    # forwards are declared without a bind address, so ssh binds BOTH loopback
    # addresses - 127.0.0.1 and [::1] (verified locally against a
    # dual-loopback listener: the @127.0.0.1 filter matches the IPv4 one).
    # Omitting the filter costs nothing on a healthy tunnel, and it avoids
    # depending on that dual-bind detail: if a forward ever ends up bound only
    # on [::1], this check should flag it rather than pass.
    #
    # Never add an address filter here without testing it on a live tunnel
    # first. Under --auto a failed health check exits 1, which makes the nightly
    # updater refuse to bump VERSION - so a filter that false-fails on a healthy
    # tunnel would silently stop all updates.
    for CHECK_PORT in "$WEB_LOCAL_PORT" "$PANELS_LOCAL_PORT" "$PANELS_WS_LOCAL_PORT"; do
        if ! lsof -nP -iTCP:"$CHECK_PORT" -sTCP:LISTEN -Fc 2>/dev/null | grep -qx 'cssh'; then
            warning "port $CHECK_PORT is not held by the tunnel's ssh - that web tool will not reach the Control Hub."
            HEALTH_OK=0
        fi
    done
elif [ "$PLATFORM" = "windows" ]; then
    sleep 3
    for CHECK_PORT in "$LOCAL_PORT" "$WEB_LOCAL_PORT" "$PANELS_LOCAL_PORT" "$PANELS_WS_LOCAL_PORT"; do
        if ! command -v netstat >/dev/null 2>&1 || ! netstat -ano 2>/dev/null | grep -q ":${CHECK_PORT} .*LISTENING"; then
            warning "port $CHECK_PORT is not listening - tunnel did not come up cleanly."
            HEALTH_OK=0
        fi
    done
    # Listening is not enough on LOCAL_PORT: a rogue local adb server sitting
    # there reports healthy while adb clients never reach the bridge. Require
    # the tunnel's own ssh, the same assertion the macOS path makes.
    LOCAL_LISTENER="$(windows_listener_image "$LOCAL_PORT")"
    if [ "$LOCAL_LISTENER" != "ssh.exe" ]; then
        warning "port ${LOCAL_PORT} is held by ${LOCAL_LISTENER:-an unknown process}, not the tunnel's ssh.exe - adb clients will not reach the bridge."
        HEALTH_OK=0
    fi
fi
# (linux path never starts a live process itself - nothing to health-check.)

if [ "$AUTO" = "1" ]; then
    if [ "$HEALTH_OK" = "0" ]; then
        warning "Auto-update replay did NOT bring the tunnel up cleanly - see log for ${REMOTE_HOST}."
        exit 1
    fi
else
    echo ""
    if [ "$HEALTH_OK" = "1" ]; then
        section "=== Done ==="
        echo "adb server should be reachable at localhost:${LOCAL_PORT}."
        echo "Control Hub web interface (Program & Manage) should be reachable at http://localhost:${WEB_LOCAL_PORT}"
        echo "Panels dashboard (if used) should be reachable at http://localhost:${PANELS_LOCAL_PORT}"
        echo "Quit and reopen Android Studio, confirm the device shows up before deploying."
    else
        warning "Setup ran, but the tunnel is NOT confirmed healthy"
        echo "One or more forwarded ports never came up. Likely cause: something else is"
        echo "already bound to one of ${LOCAL_PORT}/${WEB_LOCAL_PORT}/${PANELS_LOCAL_PORT}/${PANELS_WS_LOCAL_PORT} -"
        echo "ExitOnForwardFailure kills the WHOLE tunnel if even one forward fails, so the"
        echo "adb forward can be down even though only the web-interface port collided."
        case "$PLATFORM" in
            mac) echo "Check: /tmp/adbtunnel-${SAFE_HOST}.log and /tmp/adbtunnel-${SAFE_HOST}.err" ;;
            windows) echo "Check: ${LOG_FILE_WIN}" ;;
        esac
        exit 1
    fi
fi
