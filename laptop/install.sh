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

# ADB client/server version mismatch is a shared-server outage: an older client
# can decide the bridge's server is wrong, kill it, and start a private local
# server - every laptop on that bridge loses the robot. Keep this minimum in
# sync with MIN_ADB_VERSION in bridge/install.sh. Warn, never abort: the adb on
# PATH is not necessarily the copy Android Studio actually uses, and stranding
# an otherwise working laptop would be worse than a stale warning.
ADB_MIN_VERSION="36.0.0"
if command -v adb >/dev/null 2>&1; then
    ADB_CLIENT_VERSION="$(adb version 2>/dev/null | awk '/^Version / { sub(/-.*/, "", $2); print $2; exit }' || true)"
    if [ -n "$ADB_CLIENT_VERSION" ] && awk -v v="$ADB_CLIENT_VERSION" -v m="$ADB_MIN_VERSION" 'BEGIN {
            split(v, a, "."); split(m, b, ".")
            for (i = 1; i <= 3; i++) {
                if ((a[i] + 0) < (b[i] + 0)) exit 0
                if ((a[i] + 0) > (b[i] + 0)) exit 1
            }
            exit 1
        }'; then
        warning "Platform-Tools adb ${ADB_CLIENT_VERSION} on this laptop is older than ${ADB_MIN_VERSION}."
        warning "A current laptop client kills the bridge's shared adb server and starts its own, breaking every laptop on that bridge."
        important "Update Android SDK Platform-Tools in Android Studio's SDK Manager before using this tunnel."
    fi
fi

# A stale ANDROID_ADB_SERVER_ADDRESS/ANDROID_ADB_SERVER_PORT in the shell -
# exported in ~/.zshrc, inherited by Android Studio and every Gradle daemon it
# spawns - sends every adb client somewhere other than this tunnel. It looks
# exactly like a broken tunnel: `adb devices` is empty or refused while Relay's
# ssh still holds the port, and `adb -P` does NOT override the address. Gradle
# Sloth tasks then fail with "cannot connect to daemon at tcp:<old-ip>:5037".
# The tunnel is loopback-only by design, so a non-loopback address is always a
# misconfiguration. Warn, never abort: the variable may be deliberate for a
# different tool, and stranding a working laptop would be worse.
ADB_ENV_ADDRESS="${ANDROID_ADB_SERVER_ADDRESS:-}"
ADB_ENV_PORT="${ANDROID_ADB_SERVER_PORT:-}"
case "$ADB_ENV_ADDRESS" in
    ""|127.0.0.1|localhost|::1) ;;
    *)
        warning "ANDROID_ADB_SERVER_ADDRESS=${ADB_ENV_ADDRESS} is set on this laptop."
        warning "Every adb client will skip Relay's tunnel and fail with 'cannot connect to daemon at tcp:${ADB_ENV_ADDRESS}:${ADB_ENV_PORT:-5037}'."
        important "Remove that export (or set it to 127.0.0.1) in your shell profile, then restart Android Studio from Finder/Dock."
        ;;
esac
if [ -n "$ADB_ENV_PORT" ] && [ "$ADB_ENV_PORT" != "5037" ]; then
    warning "ANDROID_ADB_SERVER_PORT=${ADB_ENV_PORT} is set on this laptop - Relay's tunnel is on 5037."
    important "Remove that export or change it to 5037."
fi

CONFIG_ROOT="${HOME}/.config/adb-tunnel"
[ "$PLATFORM" = "windows" ] && CONFIG_ROOT="$(cygpath -u "$APPDATA")/adb-tunnel/config"
mkdir -p "$CONFIG_ROOT"

# Stale-checkout guard. Re-running this from an old clone (a `git clone` that
# failed because the folder already existed, a fork that stopped tracking
# main) silently rewrites the tunnel with whatever forwards that old copy knew
# about - e.g. dropping FTC Dashboard's port 8000 - and nothing reports it.
# The nightly updater already refuses to roll a laptop backwards; this gives
# the interactive path the same rule. Same block as bridge/install.sh - keep
# both in sync. Skipped on --auto: the updater runs a fresh download from a
# temp dir with no VERSION beside it, and has already checked versions itself.
relay_is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
relay_stale_checkout_guard() {
    local state_file="$1" checkout_version_file installed="" checkout="" latest=""
    checkout_version_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/VERSION"
    [ -f "$checkout_version_file" ] || return 0
    checkout="$(tr -d '[:space:]' < "$checkout_version_file")"; checkout="${checkout#[vV]}"
    relay_is_int "$checkout" || return 0
    [ -f "$state_file" ] && installed="$(tr -d '[:space:]' < "$state_file")"; installed="${installed#[vV]}"
    if relay_is_int "$installed" && [ "$checkout" -lt "$installed" ]; then
        warning "This checkout is Relay VERSION ${checkout}, but this machine already has VERSION ${installed}."
        warning "Installing from it would downgrade Relay and drop anything added since (for example FTC Dashboard's port 8000)."
        important "Update this folder first:  git -C \"$(dirname "$checkout_version_file")\" pull"
        important "Or clone a fresh copy:   git clone https://github.com/6165-MSET-Cuttlefish/Relay.git Relay-new"
        if [ "${RELAY_ALLOW_DOWNGRADE:-0}" != "1" ]; then
            echo "Aborting. To downgrade on purpose, re-run with RELAY_ALLOW_DOWNGRADE=1."
            exit 1
        fi
        important "RELAY_ALLOW_DOWNGRADE=1 set - continuing with the older version."
    fi
    latest="$(curl -fsSL --max-time 5 "https://raw.githubusercontent.com/6165-MSET-Cuttlefish/Relay/main/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
    latest="${latest#[vV]}"
    if relay_is_int "$latest" && [ "$checkout" -lt "$latest" ]; then
        warning "This checkout is Relay VERSION ${checkout}; the latest on GitHub is ${latest}."
        important "Run 'git pull' in this folder and re-run the installer to get the current version."
    fi
}
[ "$AUTO" = "1" ] || relay_stale_checkout_guard "${CONFIG_ROOT}/../installed-version"

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
    # PedroPathing autotuner. Defaulted for configs saved before this forward
    # existed, same pattern as the ports above.
    PEDRO_TUNER_LOCAL_PORT="${PEDRO_TUNER_LOCAL_PORT:-10158}"
    PEDRO_TUNER_REMOTE_PORT="${PEDRO_TUNER_REMOTE_PORT:-10158}"
    PEDRO_TUNER_WS_LOCAL_PORT="${PEDRO_TUNER_WS_LOCAL_PORT:-12649}"
    PEDRO_TUNER_WS_REMOTE_PORT="${PEDRO_TUNER_WS_REMOTE_PORT:-12649}"
    # FTC Dashboard's live-data WebSocket. The page itself comes over
    # WEB_LOCAL_PORT (/dash), but the client always connects to port 8000 on
    # the page's own hostname, so the LOCAL side must stay 8000 - it is not a
    # free choice. Without this forward the page loads but sits on "Op mode
    # controls have not initialized".
    DASH_WS_LOCAL_PORT="${DASH_WS_LOCAL_PORT:-8000}"
    DASH_WS_REMOTE_PORT="${DASH_WS_REMOTE_PORT:-8000}"
    # Extra forward requested for port 8092 on the Control Hub. Defaulted for
    # configs saved before this forward existed, same pattern as the ports above.
    HUB_8092_LOCAL_PORT="${HUB_8092_LOCAL_PORT:-8092}"
    HUB_8092_REMOTE_PORT="${HUB_8092_REMOTE_PORT:-8092}"
    section "=== ADB Tunnel auto-update (${REMOTE_HOST}), replaying saved config ==="
    if [ "$AUTH_CHOICE" != "1" ]; then
        warning "Password-auth config found under --auto - this should never happen (password configs aren't supposed to get an updater registered)."
        exit 1
    fi
    # A bridge that can't be reached at all (powered off, Tailscale down, this
    # laptop on another network) is not a reason to skip the update: the
    # laptop-side files - above all the guard that decides whether local adb
    # survives while the bridge is away - don't need the bridge. Without this,
    # the laptops that most need a guard fix are exactly the ones that can
    # never receive it. Such a run still installs everything, then exits
    # EXIT_BRIDGE_OFFLINE instead of 0: the updater (old or new) only records
    # a VERSION on exit 0, so a later run re-applies once the bridge answers
    # and the health check below can really verify the tunnel.
    # Anything else (key rejected, host key changed) still aborts untouched.
    EXIT_BRIDGE_OFFLINE=3
    BRIDGE_OFFLINE=0
    AUTH_CHECK_ERR="$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 "${REMOTE_USER}@${REMOTE_HOST}" 'echo ok' </dev/null 2>&1 >/dev/null)" || {
        AUTH_CHECK_ERR="$(printf '%s\n' "$AUTH_CHECK_ERR" | tr -d '\r' | awk 'NF { line = $0 } END { print line }')"
        case "$AUTH_CHECK_ERR" in
            *"Network is unreachable"*|*"timed out"*|*"Connection refused"*|*"No route to host"*|*"Host is down"*|\
            *"Could not resolve hostname"*|*"Name or service not known"*|*"nodename nor servname"*|*"Temporary failure in name resolution"*)
                BRIDGE_OFFLINE=1
                important "Bridge ${REMOTE_HOST} is unreachable (${AUTH_CHECK_ERR}) - updating this laptop's files anyway; the tunnel will be verified on a later run."
                ;;
            *)
                warning "Key auth check failed for ${REMOTE_HOST}${AUTH_CHECK_ERR:+ (${AUTH_CHECK_ERR})} - not touching the existing tunnel. (Key may be revoked or the host key changed. Fix manually, don't blind-retry.)"
                exit 1
                ;;
        esac
    }
else
    section "=== ADB Bridge Tunnel Setup ==="
    read -rp "Remote host (IP, Tailscale address, or hostname): " REMOTE_HOST
    [ -z "$REMOTE_HOST" ] && { echo "Aborting."; exit 1; }
    read -rp 'Remote username (username that you use to log into the remote host ex: "cuttlefish" if you log in as cuttlefish): ' REMOTE_USER
    [ -z "$REMOTE_USER" ] && { echo "Aborting."; exit 1; }
    # Both ends use the standard adb port. The bridge installer always runs its
    # shared adb server on 5037, and Android Studio and every adb client on
    # this laptop look for the server on 5037. Not prompted. (--auto keeps
    # whatever an older install saved in its config.)
    REMOTE_PORT="5037"
    LOCAL_PORT="5037"

    # Control Hub AP mode always assigns itself this address - it's a
    # hardware constant of AP mode, not a per-install variable, same as
    # WEB_REMOTE_PORT below. Not prompted.
    ROBOT_IP="192.168.43.1"

    # Local (laptop-side) forward ports - hardcoded, not prompted, per
    # explicit request. Trade-off: if a laptop already has something
    # bound to one of these, ExitOnForwardFailure=yes means the WHOLE
    # tunnel (including the ADB forward) fails to start. The fix is editing
    # these values in the script - except 8000, which Dashboard's client
    # hardcodes, so free that port instead.
    WEB_LOCAL_PORT="8091"
    WEB_REMOTE_PORT="8080"
    PANELS_LOCAL_PORT="8001"
    PANELS_REMOTE_PORT="8001"
    PANELS_WS_LOCAL_PORT="8002"
    PANELS_WS_REMOTE_PORT="8002"
    # PedroPathing autotuner - same port on both sides, hardcoded like the rest.
    PEDRO_TUNER_LOCAL_PORT="10158"
    PEDRO_TUNER_REMOTE_PORT="10158"
    # The autotuner's page opens a WebSocket to localhost:12649 on its own.
    PEDRO_TUNER_WS_LOCAL_PORT="12649"
    PEDRO_TUNER_WS_REMOTE_PORT="12649"
    # FTC Dashboard's live-data WebSocket. Local 8000 is fixed by the dashboard
    # client (ws://<page hostname>:8000), same reasoning as the other web ports.
    DASH_WS_LOCAL_PORT="8000"
    DASH_WS_REMOTE_PORT="8000"
    # Port 8092 on the Control Hub - same port on both sides, hardcoded like the rest.
    HUB_8092_LOCAL_PORT="8092"
    HUB_8092_REMOTE_PORT="8092"

    echo ""
    important "Auth Method:"
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
            # Windows (and any shell without ssh-copy-id) takes this path. The
            # old `echo '<key>' >> authorized_keys` appended unconditionally, so
            # every rerun added another copy of the same line - which is where a
            # bridge's authorized_keys grows three copies of one person's key and
            # nobody knows why. Pipe the key in on stdin and let the remote side
            # decide: no shell-escaping of a comment field that may contain
            # quotes, and no duplicates.
            if ! ssh -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_HOST}" \
                'mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && key="$(cat)" && if grep -qxF "$key" ~/.ssh/authorized_keys 2>/dev/null; then echo "key already present, not adding a duplicate"; else printf "%s\n" "$key" >> ~/.ssh/authorized_keys && echo "key added"; fi' \
                < "${KEY}.pub"; then
                warning "Could not install the public key on ${REMOTE_HOST}. Aborting."
                exit 1
            fi
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
PEDRO_TUNER_LOCAL_PORT="${PEDRO_TUNER_LOCAL_PORT}"
PEDRO_TUNER_REMOTE_PORT="${PEDRO_TUNER_REMOTE_PORT}"
PEDRO_TUNER_WS_LOCAL_PORT="${PEDRO_TUNER_WS_LOCAL_PORT}"
PEDRO_TUNER_WS_REMOTE_PORT="${PEDRO_TUNER_WS_REMOTE_PORT}"
DASH_WS_LOCAL_PORT="${DASH_WS_LOCAL_PORT}"
DASH_WS_REMOTE_PORT="${DASH_WS_REMOTE_PORT}"
HUB_8092_LOCAL_PORT="${HUB_8092_LOCAL_PORT}"
HUB_8092_REMOTE_PORT="${HUB_8092_REMOTE_PORT}"
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
    # The forwarded ports are hardcoded constants, never prompted, so a
    # laptop can only ever hold ONE Relay tunnel - a second registration for
    # the same ports is always a leftover, never a legitimate second bridge.
    # Match on the artifact pattern, never on SAFE_HOST: SAFE_HOST is derived
    # from REMOTE_HOST, so the same machine named two ways (`raspi` vs
    # `100.x.y.z`) yields two different names, and a name-scoped teardown
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
            # Reap by PORT, not by name. An ssh holding one of the forwarded
            # ports IS a Relay tunnel for this laptop - the ports are
            # hardcoded, so there is no legitimate second tunnel. Name-scoped
            # matching would miss a tunnel registered under a different host
            # string, which is exactly the hostname -> Tailscale IP case.
            #
            # Check every forwarded port, not just LOCAL_PORT: with
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
            for check_port in "$LOCAL_PORT" "$WEB_LOCAL_PORT" "$PANELS_LOCAL_PORT" "$PANELS_WS_LOCAL_PORT" "$PEDRO_TUNER_LOCAL_PORT" "$PEDRO_TUNER_WS_LOCAL_PORT" "$DASH_WS_LOCAL_PORT" "$HUB_8092_LOCAL_PORT"; do
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
        | awk -v p=":${port}\$" '$2 ~ p && $0 ~ /LISTENING/ { print $NF; exit }')"
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
# Except under --auto: an update can run from a terminal (via
# check-for-updates.sh) where adb is on PATH, and the guard, which runs as soon
# as the tunnel restarts, knows when a local server is in use and this does not.
if [ "$AUTO" = "1" ]; then
    :
elif [ "$PLATFORM" = "windows" ]; then
    if command -v netstat >/dev/null 2>&1 && netstat -ano 2>/dev/null | grep -q ":${LOCAL_PORT} .*LISTENING"; then
        LOCAL_PID="$(netstat -ano 2>/dev/null | tr -d '\r' | awk -v p=":${LOCAL_PORT}\$" '$2 ~ p && $0 ~ /LISTENING/ {print $NF; exit}')"
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

# linux_port_held_by_ssh <port> [bind-address] - is Relay's own ssh listening?
# Same question the macOS lsof and Windows netstat checks ask, in the tool a
# plain Linux box actually has. Falls back to a bare connect probe where neither
# ss nor lsof exists, which cannot prove ownership - the caller reports that
# distinction rather than claiming a verified tunnel.
linux_port_held_by_ssh() {
    local port="$1" addr="${2:-}"
    local filter=":${port}\$"
    [ -n "$addr" ] && filter="^${addr}:${port}\$"
    if command -v ss >/dev/null 2>&1; then
        ss -ltnpH 2>/dev/null | awk -v p="$filter" '$4 ~ p' | grep -q '(("ssh"'
    elif command -v lsof >/dev/null 2>&1; then
        local lsof_filter="-iTCP:${port}"
        [ -n "$addr" ] && lsof_filter="-iTCP@${addr}:${port}"
        lsof -nP "$lsof_filter" -sTCP:LISTEN -Fc 2>/dev/null | grep -qx 'cssh'
    else
        ( exec 3<>"/dev/tcp/${addr:-127.0.0.1}/$port" ) 2>/dev/null
    fi
}

# --- Port conflict check for the web-interface forwards (warn-only, never auto-killed) ---
for CHECK_PORT in "$WEB_LOCAL_PORT" "$PANELS_LOCAL_PORT" "$PANELS_WS_LOCAL_PORT" "$PEDRO_TUNER_LOCAL_PORT" "$PEDRO_TUNER_WS_LOCAL_PORT" "$DASH_WS_LOCAL_PORT" "$HUB_8092_LOCAL_PORT"; do
    if [ "$CHECK_PORT" = "$DASH_WS_LOCAL_PORT" ]; then
        PORT_NOTE="NOTE: local port $CHECK_PORT is FTC Dashboard's live-data WebSocket, and its client hardcodes that port - it cannot be moved. Free it before starting the tunnel; ExitOnForwardFailure takes down the whole tunnel, adb included, if it is occupied."
    else
        PORT_NOTE="NOTE: something is on local port $CHECK_PORT already - expected if the old tunnel is still up; it'll be replaced below. If this is the web-interface port and it's a leftover dev server (Tomcat/webpack/etc. commonly squat 8080), pick a different WEB_LOCAL_PORT instead of assuming it's safe to kill."
    fi
    if [ "$PLATFORM" = "windows" ]; then
        if command -v netstat >/dev/null 2>&1 && netstat -ano 2>/dev/null | grep -q ":${CHECK_PORT} .*LISTENING"; then
            important "$PORT_NOTE"
        fi
    elif command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$CHECK_PORT" -sTCP:LISTEN -P >/dev/null 2>&1; then
        important "$PORT_NOTE"
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
#
# Only when the tunnel will really take its place, and never while someone is
# using that server: otherwise a laptop away from the bridge (no Tailscale, or
# on a Control Hub's own Wi-Fi) loses its local adb on every respawn. So a
# local server is left alone unless ssh can log in and bind the tunnel's other
# forwards, and for as long as it lives once it has had a usable device.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
PORT="${1:?usage: adb-tunnel-guard.sh LOCAL_PORT command [args...]}"
shift
[ "$#" -gt 0 ] || { echo "adb-tunnel-guard: no command given" >&2; exit 2; }
RETRY_S=15
STATE_DIR="$(cd "$(dirname "$0")" && pwd)"
MSG_FILE="${STATE_DIR}/guard-${PORT}.msg"
KEEP_FILE="${STATE_DIR}/guard-${PORT}.keep"

log() { printf '%s adb-tunnel-guard: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2; }

# launchd appends to the tunnel's logs on every respawn and /tmp lasts until
# reboot, so keep the newest 2.5 MB of each once it passes 5 MB. Rewritten in
# place, not replaced, so the file launchd has open stays the one on disk.
lsof -a -p $$ -d 1,2 -Fn 2>/dev/null | sed -n 's/^n//p' | sort -u | while IFS= read -r f; do
    [ -f "$f" ] && [ "$(stat -f %z "$f" 2>/dev/null || echo 0)" -gt 5242880 ] || continue
    tail -c 2621440 "$f" > "$f.tmp" && cat "$f.tmp" > "$f"
    rm -f "$f.tmp"
done

# wait_and_retry KIND MESSAGE - logged once per change, not every retry; the
# sleep keeps launchd's respawn from becoming a 10-second loop. install.sh's
# health check reads KIND back: "in-use" means a working install waiting on
# this laptop's own adb server, anything else is a failure.
wait_and_retry() {
    if [ "$(cat "$MSG_FILE" 2>/dev/null)" != "$1 $2" ]; then
        log "$2"
        printf '%s %s' "$1" "$2" > "$MSG_FILE"
    fi
    sleep "$RETRY_S"
    exit 0
}

SSH_AT=0
i=1
for arg in "$@"; do
    if [ "${arg##*/}" = "ssh" ]; then
        SSH_AT=$i
        break
    fi
    i=$((i + 1))
done

# Runs the tunnel's own ssh with a remote `true` and every forward except the
# adb one, which the local server still holds, so a failed login or a taken
# web port (ExitOnForwardFailure) fails here instead of after the kill. Its
# forwards lead to a closed port on the bridge: ssh stays up for as long as a
# connection through one lasts, and a dashboard tab reconnecting every second
# would otherwise land one and hold the probe open.
SSH_ERROR=""
ssh_can_take_over() {
    local -a probe
    local arg prev="" out rc
    [ "$SSH_AT" -gt 0 ] || return 0
    probe=("${@:1:SSH_AT}" -o ConnectTimeout=10)
    for arg in "${@:SSH_AT+1}"; do
        if [ "$prev" = "-L" ]; then
            prev=""
            case "$arg" in
                "$PORT":*|*:"$PORT":*:*) ;;
                *) probe+=(-L "${arg%:*:*}:127.0.0.1:1") ;;
            esac
            continue
        fi
        case "$arg" in
            -N) ;;
            -L) prev=-L ;;
            *) probe+=("$arg") ;;
        esac
    done
    out="$("${probe[@]}" true </dev/null 2>&1 >/dev/null)"
    rc=$?
    # ssh ends lines with \r\n, and its last line is the fatal one; a changed
    # host key starts with a row of @ signs.
    SSH_ERROR="$(printf '%s\n' "$out" | tr -d '\r' | awk 'NF { line = $0 } END { print line }')"
    return "$rc"
}

# The local server's usable devices, asked the way `adb devices` does. Only
# state "device" counts: a dropped Wi-Fi hub lingers as "offline" for minutes,
# and an emulator is never a robot. ANSWERED stays empty without a full reply.
ANSWERED=""
USABLE=""
query_local_adb() {
    local status="" length="" payload="" serial state
    ANSWERED=""
    USABLE=""
    { exec 3<>"/dev/tcp/127.0.0.1/$PORT"; } 2>/dev/null || return 0
    printf '000chost:devices' >&3
    # A freshly started adb server takes up to 3 s to accept connections.
    IFS= read -r -t 5 -n 4 status <&3
    [ "$status" = "OKAY" ] && IFS= read -r -t 3 -n 4 length <&3
    case "$length" in
        0000) ANSWERED=1 ;;
        [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
            IFS= read -r -t 3 -d '' -n "$((16#$length))" payload <&3 && ANSWERED=1 ;;
    esac
    exec 3<&-
    while IFS=$'\t' read -r serial state; do
        case "$serial:$state" in
            emulator-*) ;;
            *:device) USABLE="${USABLE:+$USABLE }$serial" ;;
        esac
    done <<< "$payload"
}

# Protection sticks to the server process (pid and start time): a hub
# rebooting or reconnecting empties the list for a moment, and a kill then
# would send the next `adb connect` to the bridge's robot instead of this one.
leave_alone_if_in_use() {
    local kept_pid="" kept_start="" kept_serials="" start
    start="$(ps -p "$1" -o lstart= 2>/dev/null | tr ' ' _)"
    { read -r kept_pid kept_start kept_serials < "$KEEP_FILE"; } 2>/dev/null
    if [ "$kept_pid" != "$1" ] || [ "$kept_start" != "$start" ]; then
        query_local_adb
        [ -n "$ANSWERED" ] || wait_and_retry in-use "local adb server (pid $1) on port $PORT didn't answer - leaving it alone."
        [ -n "$USABLE" ] || return 0
        kept_serials="$USABLE"
        printf '%s %s %s\n' "$1" "$start" "$kept_serials" > "$KEEP_FILE"
    fi
    wait_and_retry in-use "local adb server (pid $1) on port $PORT has been used for $kept_serials - leaving it alone until it exits."
}

for PID in $(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | sort -u); do
    NAME="$(basename "$(ps -p "$PID" -o comm= 2>/dev/null)")"
    if [ "$NAME" = "adb" ]; then
        leave_alone_if_in_use "$PID"
        ssh_can_take_over "$@" || wait_and_retry ssh "the tunnel can't start (${SSH_ERROR:-ssh failed}) - leaving local adb on port $PORT alone."
        leave_alone_if_in_use "$PID"
        log "local adb server (pid $PID) is holding port $PORT - shutting it down."
        # Same request `adb kill-server` sends. Speaking it directly means we
        # don't depend on finding an adb binary on launchd's minimal PATH.
        ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" && printf '0009host:kill' >&3 ) 2>/dev/null || true
        sleep 1
        if lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | grep -qx "$PID"; then
            wait_and_retry in-use "local adb server (pid $PID) on port $PORT refused to shut down - leaving it alone."
        fi
    else
        log "port $PORT is held by a non-adb process (pid $PID, ${NAME:-unknown}) - leaving it alone."
    fi
done

rm -f "$MSG_FILE" "$KEEP_FILE"
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
        <string>-L</string>
        <string>${PEDRO_TUNER_LOCAL_PORT}:${ROBOT_IP}:${PEDRO_TUNER_REMOTE_PORT}</string>
        <string>-L</string>
        <string>${PEDRO_TUNER_WS_LOCAL_PORT}:${ROBOT_IP}:${PEDRO_TUNER_WS_REMOTE_PORT}</string>
        <string>-L</string>
        <string>${DASH_WS_LOCAL_PORT}:${ROBOT_IP}:${DASH_WS_REMOTE_PORT}</string>
        <string>-L</string>
        <string>${HUB_8092_LOCAL_PORT}:${ROBOT_IP}:${HUB_8092_REMOTE_PORT}</string>
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
        <string>-L</string>
        <string>${PEDRO_TUNER_LOCAL_PORT}:${ROBOT_IP}:${PEDRO_TUNER_REMOTE_PORT}</string>
        <string>-L</string>
        <string>${PEDRO_TUNER_WS_LOCAL_PORT}:${ROBOT_IP}:${PEDRO_TUNER_WS_REMOTE_PORT}</string>
        <string>-L</string>
        <string>${DASH_WS_LOCAL_PORT}:${ROBOT_IP}:${DASH_WS_REMOTE_PORT}</string>
        <string>-L</string>
        <string>${HUB_8092_LOCAL_PORT}:${ROBOT_IP}:${HUB_8092_REMOTE_PORT}</string>
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
    # Cap the macOS tunnel logs. launchd appends to these on every ssh
    # (re)start, so a persistently failing tunnel grows them without bound for
    # as long as the machine stays up - /tmp is not cleared until reboot. Prune
    # at install and on every agent start (the guard runs on every respawn, so
    # hooking it there bounds the file even when nobody reinstalls). Same
    # keep-the-newest-half approach as the Windows prune script.
    for mac_log in "/tmp/adbtunnel-${SAFE_HOST}.log" "/tmp/adbtunnel-${SAFE_HOST}.err" "/tmp/adbtunnel-updater.log"; do
        if [ -f "$mac_log" ] && [ "$(wc -c < "$mac_log" 2>/dev/null || echo 0)" -gt 5242880 ]; then
            tail -c 2621440 "$mac_log" > "$mac_log.tmp" 2>/dev/null && mv "$mac_log.tmp" "$mac_log"
            echo "  capped $mac_log to 2.5MB (was over 5MB)"
        fi
    done
    launchctl unload "$PLIST" 2>/dev/null || true
    # The health check below reads the guard's message, so it must be this run's.
    rm -f "${CONFIG_ROOT}/guard-${LOCAL_PORT}.msg"
    launchctl load "$PLIST"

    # Register the updater LaunchAgent (key-auth only), once.
    if [ "$AUTH_CHOICE" = "1" ] && [ "$AUTO" != "1" ]; then
        UPDATER_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/adb-tunnel-updater.sh"
        if [ -f "$UPDATER_SRC" ] && bash -n "$UPDATER_SRC"; then
            UPDATER_DEST="${CONFIG_ROOT}/../adb-tunnel-updater.sh"
            # Replace by rename, never in place: the nightly updater may be
            # executing this very file while install.sh --auto rewrites it.
            if cp "$UPDATER_SRC" "${UPDATER_DEST}.new.$$" 2>/dev/null \
                && chmod 755 "${UPDATER_DEST}.new.$$" 2>/dev/null \
                && mv -f "${UPDATER_DEST}.new.$$" "$UPDATER_DEST"; then
                :
            else
                rm -f "${UPDATER_DEST}.new.$$" 2>/dev/null || true
                echo "Auto-update could not be installed to ${UPDATER_DEST}."
            fi
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
    # Bound the tunnel log. The .bat appends a line every 5 seconds while the
    # tunnel is down, so a persistently broken tunnel writes ~17k lines/day and
    # the file grows forever inside %APPDATA%. Truncate-on-reinstall only helps
    # if someone reruns the installer, which is exactly what people stop doing
    # once they trust the thing - so cap the size here instead. Windows has no
    # logrotate; a scheduled task would be more machinery than this deserves,
    # so the installer prunes on every run and the .bat prunes on every start.
    truncate_log_if_large() {
        local f="$1" max_mb="${2:-5}" max_bytes
        [ -f "$f" ] || return 0
        max_bytes=$((max_mb * 1024 * 1024))
        # stat -c is GNU; the BSD/macOS form is different, but this branch is
        # Windows-only, where Git Bash ships the GNU coreutils.
        local size
        size="$(stat -c %s "$f" 2>/dev/null || echo 0)"
        if [ "$size" -gt "$max_bytes" ]; then
            local keep=$((max_bytes / 2))
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] adb-tunnel: log exceeded ${max_mb}MB, keeping newest ${keep} bytes." >> "$f"
            tail -c "$keep" "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
        fi
    }
    truncate_log_if_large "${INSTALL_DIR}/adb-tunnel-${SAFE_HOST}.log"
    TASK_NAME="ADBTunnel-${SAFE_HOST}"

    # Guard script: run before every (re)start of the tunnel's ssh while
    # something listens on LOCAL_PORT. Rewritten on every install/auto-update
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
    #
    # Same rules as the macOS guard: a local server is shut down only when ssh
    # can log in and bind the tunnel's other forwards, and never once it has
    # had a usable device, or a laptop away from the bridge loses its own adb
    # on every retry. The guard reads the tunnel's command from COMMAND_FILE,
    # one argument per line, written below from the same array as the .bat's
    # ssh line. Exit 0 starts ssh; anything else makes the .bat wait and ask
    # again.
    GUARD_PS1="${INSTALL_DIR}/adb-tunnel-guard.ps1"
    cat > "$GUARD_PS1" <<'GUARD_EOF'
param([int]$Port, [string]$CommandFile)
# adb-tunnel-guard.ps1 - written by laptop/install.sh, run by the tunnel's
# .bat before every (re)start of ssh while something listens on the port.
# Windows counterpart of the macOS adb-tunnel-guard.sh.
$ErrorActionPreference = 'SilentlyContinue'
$RetrySeconds = 10
$MsgFile = Join-Path $PSScriptRoot "guard-$Port.msg"
$KeepFile = Join-Path $PSScriptRoot "guard-$Port.keep"

# Straight to stdout: Write-Output inside a function would become part of its
# return value.
function Write-GuardLog([string]$Message) {
    [Console]::Out.WriteLine(('{0} adb-tunnel-guard: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message))
}

# Logged once per change, not every retry. install.sh's health check reads
# KIND back: "in-use" means a working install waiting on this laptop's own adb
# server, anything else is a failure.
function Wait-AndRetry([string]$Kind, [string]$Message) {
    $previous = $null
    try { $previous = [IO.File]::ReadAllText($MsgFile) } catch { }
    if ($previous -cne "$Kind $Message") {
        Write-GuardLog $Message
        try { [IO.File]::WriteAllText($MsgFile, "$Kind $Message") } catch { }
    }
    Start-Sleep -Seconds $RetrySeconds
    exit 1
}

function Get-PortOwners {
    @(Get-NetTCPConnection -State Listen -LocalPort $Port | Select-Object -ExpandProperty OwningProcess -Unique)
}

# Runs the tunnel's own ssh with a remote `true` and every forward except the
# adb one, which the local server still holds, so a failed login or a taken
# web port (ExitOnForwardFailure) fails here instead of after the kill. Its
# forwards lead to a closed port on the bridge: ssh stays up for as long as a
# connection through one lasts, and a dashboard tab reconnecting every second
# would otherwise land one and hold the probe open. With no command to read
# there is nothing to test, as before this check existed.
$SshError = ''
function Test-TunnelCanStart {
    $command = @(Get-Content -LiteralPath $CommandFile -Encoding UTF8 | Where-Object { $_ -ne '' })
    $sshAt = -1
    for ($i = 0; $i -lt $command.Count; $i++) {
        if ([IO.Path]::GetFileNameWithoutExtension($command[$i]) -eq 'ssh') { $sshAt = $i; break }
    }
    if ($sshAt -lt 0) { return $true }
    $probe = @()
    for ($i = 0; $i -lt $command.Count; $i++) {
        $arg = $command[$i]
        if ($i -gt $sshAt -and $arg -ceq '-N') { continue }
        if ($i -gt $sshAt -and $arg -ceq '-L' -and $i + 1 -lt $command.Count) {
            $i++
            $forward = $command[$i]
            if ($forward -like "${Port}:*" -or $forward -like "*:${Port}:*:*") { continue }
            $probe += '-L', ($forward -replace ':[^:]+:[^:]+$', ':127.0.0.1:1')
            continue
        }
        $probe += $arg
        if ($i -eq $sshAt) { $probe += '-n' }
    }
    $probe += 'true'
    $exe = $probe[0]
    $rest = $probe[1..($probe.Count - 1)]
    # Windows PowerShell drops native stderr under SilentlyContinue instead of
    # handing it to 2>&1. ssh ends lines with \r\n, and its last line is the
    # fatal one; a changed host key starts with a row of @ signs.
    $ErrorActionPreference = 'Continue'
    $output = & $exe @rest 2>&1
    $rc = $LASTEXITCODE
    $lines = @($output | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    $script:SshError = ''
    if ($lines.Count -gt 0) { $script:SshError = $lines[-1] }
    return ($rc -eq 0)
}

function Read-AdbBytes($Stream, [int]$Count) {
    $buffer = New-Object byte[] $Count
    $done = 0
    while ($done -lt $Count) {
        $n = $Stream.Read($buffer, $done, $Count - $done)
        if ($n -le 0) { return $null }
        $done += $n
    }
    return [Text.Encoding]::ASCII.GetString($buffer)
}

# The local server's usable devices, asked the way `adb devices` does. Only
# state "device" counts: a dropped Wi-Fi hub lingers as "offline" for minutes,
# and an emulator is never a robot. Answered stays false without a full reply.
$Answered = $false
$Usable = @()
function Get-LocalAdbDevices {
    $script:Answered = $false
    $script:Usable = @()
    $client = New-Object Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', $Port)
        $stream = $client.GetStream()
        # A freshly started adb server takes up to 3 s to accept connections.
        $stream.ReadTimeout = 5000
        $request = [Text.Encoding]::ASCII.GetBytes('000chost:devices')
        $stream.Write($request, 0, $request.Length)
        if ((Read-AdbBytes $stream 4) -cne 'OKAY') { return }
        $length = Read-AdbBytes $stream 4
        if ($length -notmatch '^[0-9a-fA-F]{4}$') { return }
        $payload = Read-AdbBytes $stream ([Convert]::ToInt32($length, 16))
        if ($null -eq $payload) { return }
        $script:Answered = $true
        foreach ($line in $payload -split "`n") {
            $fields = @($line -split "`t")
            if ($fields.Count -eq 2 -and $fields[1] -ceq 'device' -and $fields[0] -notlike 'emulator-*') {
                $script:Usable += $fields[0]
            }
        }
    } catch {
    } finally {
        $client.Close()
    }
}

# Protection sticks to the server process (pid and start time): a hub
# rebooting or reconnecting empties the list for a moment, and a kill then
# would send the next `adb connect` to the bridge's robot instead of this one.
function Exit-IfInUse([int]$ProcId) {
    $start = '0'
    $proc = Get-Process -Id $ProcId
    if ($proc -and $proc.StartTime) { $start = [string]$proc.StartTime.ToUniversalTime().Ticks }
    $kept = @()
    try { $kept = @([IO.File]::ReadAllText($KeepFile).Trim() -split ' ', 3) } catch { }
    if ($kept.Count -eq 3 -and $kept[0] -ceq [string]$ProcId -and $kept[1] -ceq $start) {
        $serials = $kept[2]
    } else {
        Get-LocalAdbDevices
        if (-not $script:Answered) { Wait-AndRetry 'in-use' "local adb server (pid $ProcId) on port $Port didn't answer - leaving it alone." }
        if ($script:Usable.Count -eq 0) { return }
        $serials = $script:Usable -join ' '
        try { [IO.File]::WriteAllText($KeepFile, "$ProcId $start $serials") } catch { }
    }
    Wait-AndRetry 'in-use' "local adb server (pid $ProcId) on port $Port has been used for $serials - leaving it alone until it exits."
}

foreach ($procId in @(Get-PortOwners)) {
    $proc = Get-Process -Id $procId
    if (-not $proc -or $proc.ProcessName -ne 'adb') { continue }
    Exit-IfInUse $procId
    if (-not (Test-TunnelCanStart)) {
        $reason = $SshError
        if (-not $reason) { $reason = 'ssh failed' }
        Wait-AndRetry 'ssh' "the tunnel can't start ($reason) - leaving local adb on port $Port alone."
    }
    Exit-IfInUse $procId
    Write-GuardLog "local adb server (pid $procId) is holding port $Port - shutting it down."
    # Same request `adb kill-server` sends, so no adb binary has to be on the
    # task's PATH. The server answers OKAY just before it exits.
    $client = New-Object Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', $Port)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 2000
        $request = [Text.Encoding]::ASCII.GetBytes('0009host:kill')
        $stream.Write($request, 0, $request.Length)
        Read-AdbBytes $stream 4 | Out-Null
    } catch {
    } finally {
        $client.Close()
    }
    $stillThere = $true
    for ($i = 0; $i -lt 10 -and $stillThere; $i++) {
        Start-Sleep -Milliseconds 300
        $stillThere = @(Get-PortOwners) -contains $procId
    }
    if ($stillThere) { Wait-AndRetry 'in-use' "local adb server (pid $procId) on port $Port refused to shut down - leaving it alone." }
}

Remove-Item -LiteralPath $MsgFile, $KeepFile -Force
exit 0
GUARD_EOF
    GUARD_PS1_WIN="$(cygpath -w "$GUARD_PS1")"
    # Cheap native pre-check so the common case (nothing on the port) does not
    # pay PowerShell startup cost five times a minute.
    # Prune the log at the top of every loop iteration, not just at install:
    # the loop is what runs unattended, so this is the only size bound that
    # applies while nobody is thinking about Relay.
    #
    # The PowerShell is written to a .ps1 rather than inlined. A single-quoted
    # bash string means $ is never expanded by bash and needs no escaping, and
    # cmd.exe is not asked to parse quotes and braces - which it does badly, and
    # which previously produced literal \$f in the generated .bat.
    PRUNE_PS1="${INSTALL_DIR}/adb-tunnel-prune.ps1"
    cat > "$PRUNE_PS1" <<'PRUNE_EOF'
param([string]$Path, [int]$MaxBytes = 5242880)
# adb-tunnel-prune.ps1 - written by laptop/install.sh, run by the tunnel's .bat
# on every reconnect attempt. The .bat logs a line every 5 seconds while the
# tunnel is down, so without this the log grows without bound inside %APPDATA%.
try {
    if (-not (Test-Path $Path)) { exit 0 }
    $len = (Get-Item $Path).Length
    if ($len -gt $MaxBytes) {
        $keep = [int]($MaxBytes / 2)
        $text = [IO.File]::ReadAllText($Path)
        $tail = $text.Substring([Math]::Max(0, $text.Length - $keep))
        [IO.File]::WriteAllText($Path, $tail)
        Add-Content -Path $Path -Value ("{0} adb-tunnel: log exceeded {1} bytes, kept newest {2}." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $len, $keep)
    }
} catch {
    # Never let log housekeeping break the tunnel.
    exit 0
}
exit 0
PRUNE_EOF
    PRUNE_PS1_WIN="$(cygpath -w "$PRUNE_PS1")"
    PRUNE_LINE="powershell -NoProfile -ExecutionPolicy Bypass -File \"${PRUNE_PS1_WIN}\" -Path \"${LOG_FILE_WIN}\" -MaxBytes 5242880 >> \"${LOG_FILE_WIN}\" 2>&1"
    TUNNEL_FORWARDS=(
        -L "127.0.0.1:${LOCAL_PORT}:localhost:${REMOTE_PORT}"
        -L "${WEB_LOCAL_PORT}:${ROBOT_IP}:${WEB_REMOTE_PORT}"
        -L "${PANELS_LOCAL_PORT}:${ROBOT_IP}:${PANELS_REMOTE_PORT}"
        -L "${PANELS_WS_LOCAL_PORT}:${ROBOT_IP}:${PANELS_WS_REMOTE_PORT}"
        -L "${PEDRO_TUNER_LOCAL_PORT}:${ROBOT_IP}:${PEDRO_TUNER_REMOTE_PORT}"
        -L "${PEDRO_TUNER_WS_LOCAL_PORT}:${ROBOT_IP}:${PEDRO_TUNER_WS_REMOTE_PORT}"
        -L "${DASH_WS_LOCAL_PORT}:${ROBOT_IP}:${DASH_WS_REMOTE_PORT}"
        -L "${HUB_8092_LOCAL_PORT}:${ROBOT_IP}:${HUB_8092_REMOTE_PORT}"
    )
    if [ "$AUTH_CHOICE" = "1" ]; then
        TUNNEL_CMD=("$SSH_BIN_WIN" -i "$(cygpath -w "$KEY")" -N -o BatchMode=yes)
    else
        TUNNEL_CMD=("$(cygpath -w "$(command -v sshpass)")" -f "$(cygpath -w "$PASSFILE")" "$SSH_BIN_WIN" -N)
    fi
    TUNNEL_CMD+=(-o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "${TUNNEL_FORWARDS[@]}" "${REMOTE_USER}@${REMOTE_HOST}")
    COMMAND_FILE="${INSTALL_DIR}/adb-tunnel-${SAFE_HOST}.args"
    printf '%s\n' "${TUNNEL_CMD[@]}" > "$COMMAND_FILE"
    TUNNEL_LINE=""
    for arg in "${TUNNEL_CMD[@]}"; do
        TUNNEL_LINE="${TUNNEL_LINE:+$TUNNEL_LINE }\"${arg}\""
    done
    GUARD_LINE="powershell -NoProfile -ExecutionPolicy Bypass -File \"${GUARD_PS1_WIN}\" -Port ${LOCAL_PORT} -CommandFile \"$(cygpath -w "$COMMAND_FILE")\" >> \"${LOG_FILE_WIN}\" 2>&1"

    # findstr's exit code is the pipeline's, and without /C: it would read the
    # space as "or" and match every listening port. The guard has already slept
    # when it says wait; the 5 s on that path also keeps a guard that can't run
    # at all from spinning the loop. CRLF: with LF endings cmd can miss a label
    # it has to search forward for.
    cat <<EOF | awk '{ printf "%s\r\n", $0 }' > "$WRAPPER_BAT"
@echo off
:loop
${PRUNE_LINE}
netstat -ano | findstr /R /C:":${LOCAL_PORT} .*LISTENING" >nul 2>&1
if errorlevel 1 goto tunnel
${GUARD_LINE}
if errorlevel 1 goto wait
:tunnel
echo [%date% %time%] starting tunnel to ${REMOTE_HOST} >> "${LOG_FILE_WIN}"
${TUNNEL_LINE} >> "${LOG_FILE_WIN}" 2>&1
echo [%date% %time%] tunnel exited, restarting in 5s >> "${LOG_FILE_WIN}"
:wait
timeout /t 5 /nobreak >nul
goto loop
EOF
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
param([string]$TaskName, [string]$Launcher, [string]$Ports)
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
# Unregistering leaves a running loop behind, and once its ssh dies its cmd.exe
# reads the rewritten .bat from where it was and becomes a second loop.
foreach ($image in 'wscript.exe', 'cmd.exe') {
    Get-CimInstance Win32_Process -Filter "Name='$image'" |
        Where-Object { $_.CommandLine -match 'adb-tunnel-[^\\"]+\.(vbs|bat)' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
# Stop only an ssh that is holding one of Relay's own forwarded ports.
#
# The previous version of this script matched on the bridge host appearing
# anywhere in the command line, which also matched every interactive
# `ssh user@bridge` the operator had open in another terminal - it killed their
# own shell sessions during an ordinary reinstall. Holding a Relay forward port
# is the actual test: those ports are Relay's by definition here, and an
# ssh that owns one of them is this laptop's previous tunnel (or a rogue local
# adb, which the guard handles). A non-ssh listener is somebody's dev server:
# reported, never touched.
$portList = @($Ports -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
foreach ($port in $portList) {
    $owners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue |
               Select-Object -ExpandProperty OwningProcess -Unique)
    foreach ($procId in $owners) {
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        if ($proc.ProcessName -ne 'ssh') {
            Write-Output ("port {0} is held by {1} (pid {2}) - leaving it alone." -f $port, $proc.ProcessName, $procId)
            continue
        }
        Write-Output ("stopping stale Relay tunnel ssh (pid {0}) still holding port {1}." -f $procId, $port)
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Milliseconds 500
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
    # The health check below reads the guard's message, so it must be this run's.
    rm -f "${INSTALL_DIR}/guard-${LOCAL_PORT}.msg"
    if powershell -NoProfile -ExecutionPolicy Bypass -File "$PS1_WIN" -TaskName "$TASK_NAME" -Launcher "$WIN_WRAPPER_VBS" -Ports "${LOCAL_PORT},${WEB_LOCAL_PORT},${PANELS_LOCAL_PORT},${PANELS_WS_LOCAL_PORT},${PEDRO_TUNER_LOCAL_PORT},${PEDRO_TUNER_WS_LOCAL_PORT},${DASH_WS_LOCAL_PORT},${HUB_8092_LOCAL_PORT}"; then
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
            # Rename into place, same reason as the macOS path above: a running
            # updater must never have its own file rewritten underneath it.
            if cp "$UPDATER_SRC" "${UPDATER_DEST}.new.$$" 2>/dev/null \
                && chmod 755 "${UPDATER_DEST}.new.$$" 2>/dev/null \
                && mv -f "${UPDATER_DEST}.new.$$" "$UPDATER_DEST"; then
                :
            else
                rm -f "${UPDATER_DEST}.new.$$" 2>/dev/null || true
                echo "Auto-update could not be installed to ${UPDATER_DEST}."
            fi
            BASH_BIN_WIN="$(cygpath -w "$(command -v bash)")"
            UPDATER_DEST_WIN="$(cygpath -w "$UPDATER_DEST")"
            UPD_PS1="${INSTALL_DIR}/install-updater-task.ps1"
            cat > "$UPD_PS1" <<'PSEOF'
param([string]$BashBin, [string]$ScriptPath)
Unregister-ScheduledTask -TaskName "ADBTunnelUpdater" -Confirm:$false -ErrorAction SilentlyContinue
try {
    $Action   = New-ScheduledTaskAction -Execute $BashBin -Argument "`"$ScriptPath`""
    $Trigger  = New-ScheduledTaskTrigger -Daily -At 3am
    # -StartWhenAvailable: a workshop laptop is almost always powered off at 3am,
    # and without this the daily trigger is simply missed - those machines then
    # never receive an update, silently, for as long as they stay off overnight.
    # It runs the check as soon as the machine is next available instead.
    $Settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
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
        # Plain Linux has no LaunchAgent and no Task Scheduler, so this path used
        # to print a command and nothing else - no tunnel, no persistence, no
        # health check - and then still report "Done / adb server should be
        # reachable at localhost:5037", which was only true if the user had run
        # the printed command themselves. Start the tunnel now for real, verify
        # it below like every other platform, and say plainly which parts are
        # still the user's job.
        LINUX_LOG="${CONFIG_ROOT}/adb-tunnel-${SAFE_HOST}.log"
        LINUX_FORWARDS=(
            -L "127.0.0.1:${LOCAL_PORT}:localhost:${REMOTE_PORT}"
            -L "${WEB_LOCAL_PORT}:${ROBOT_IP}:${WEB_REMOTE_PORT}"
            -L "${PANELS_LOCAL_PORT}:${ROBOT_IP}:${PANELS_REMOTE_PORT}"
            -L "${PANELS_WS_LOCAL_PORT}:${ROBOT_IP}:${PANELS_WS_REMOTE_PORT}"
            -L "${PEDRO_TUNER_LOCAL_PORT}:${ROBOT_IP}:${PEDRO_TUNER_REMOTE_PORT}"
            -L "${PEDRO_TUNER_WS_LOCAL_PORT}:${ROBOT_IP}:${PEDRO_TUNER_WS_REMOTE_PORT}"
            -L "${DASH_WS_LOCAL_PORT}:${ROBOT_IP}:${DASH_WS_REMOTE_PORT}"
            -L "${HUB_8092_LOCAL_PORT}:${ROBOT_IP}:${HUB_8092_REMOTE_PORT}"
        )
        LINUX_OPTS=(-N -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
        if [ "$AUTH_CHOICE" = "1" ]; then
            LINUX_SSH=(ssh -i "$KEY" -o BatchMode=yes "${LINUX_OPTS[@]}" "${LINUX_FORWARDS[@]}" "${REMOTE_USER}@${REMOTE_HOST}")
        else
            LINUX_SSH=(sshpass -f "$PASSFILE" ssh "${LINUX_OPTS[@]}" "${LINUX_FORWARDS[@]}" "${REMOTE_USER}@${REMOTE_HOST}")
        fi
        # Detach properly: setsid so the tunnel is not in this terminal's
        # process group (a Ctrl-C here would otherwise take the tunnel with it),
        # nohup as the fallback on boxes without util-linux's setsid.
        if command -v setsid >/dev/null 2>&1; then
            setsid "${LINUX_SSH[@]}" >>"$LINUX_LOG" 2>&1 < /dev/null &
        else
            nohup "${LINUX_SSH[@]}" >>"$LINUX_LOG" 2>&1 < /dev/null &
        fi
        disown 2>/dev/null || true
        important "Tunnel started (pid $!). Log: ${LINUX_LOG}"

        # A ready-to-enable systemd --user unit, written but NOT enabled: which
        # of these applies (linger, which key, key permissions) differs per
        # distro, and silently enabling a unit that cannot log in unattended is
        # worse than printing the two commands.
        LINUX_UNIT="${CONFIG_ROOT}/adb-tunnel-${SAFE_HOST}.service"
        {
            echo "[Unit]"
            echo "Description=Relay ADB tunnel to ${REMOTE_HOST}"
            echo "After=network-online.target"
            echo ""
            echo "[Service]"
            echo "Type=simple"
            printf 'ExecStart='
            printf '%q ' "${LINUX_SSH[@]}"
            echo ""
            echo "Restart=always"
            echo "RestartSec=5"
            echo ""
            echo "[Install]"
            echo "WantedBy=default.target"
        } > "$LINUX_UNIT"
        important "No auto-start on plain Linux yet. To persist this tunnel:"
        important "  loginctl enable-linger \$USER      # so it runs without an open session"
        important "  systemctl --user enable --now adb-tunnel-$(basename "$LINUX_UNIT" .service)"
        echo "  (unit written to ${LINUX_UNIT}, adapted to your paths if needed)"
        echo "Auto-update is not installed on this platform - 'git pull' and re-run"
        echo "install.sh to pick up fixes."
        ;;
esac

# --- Verify the tunnel actually came up before declaring success ---
# launchctl load / Register-ScheduledTask can report success even when the
# underlying ssh process immediately dies (e.g. ExitOnForwardFailure killing
# ALL forwards over a single port conflict) - a loader exit code only tells
# you the service was registered, not that it's running. Check the real
# local port state directly instead of trusting that.
HEALTH_OK=1
TUNNEL_WAITING=0
if [ "$AUTO" = "1" ] && [ "${BRIDGE_OFFLINE:-0}" = "1" ]; then
    # Nothing to verify against: ssh can't reach the bridge, so the guard is
    # (correctly) holding off. See EXIT_BRIDGE_OFFLINE above.
    important "Laptop files updated for ${REMOTE_HOST}; tunnel not verified because the bridge is unreachable."
    exit "$EXIT_BRIDGE_OFFLINE"
fi
if [ "$PLATFORM" = "mac" ]; then
    # The adb port only counts as up if the tunnel's ssh owns it on 127.0.0.1.
    # "Something is listening" is not enough: it also passes for a rogue local
    # adb server, or for a half-bound tunnel holding only [::1]. Poll instead
    # of a fixed sleep - the guard may spend a few seconds checking the bridge
    # and shutting a rogue adb server down before ssh even starts.
    #
    # A guard that is deliberately waiting leaves "KIND reason" in
    # guard-PORT.msg. KIND "in-use" (this laptop's own adb server has a device)
    # is a working install with the tunnel deferred, not a failure: failing
    # here would keep the nightly updater from ever recording the new VERSION
    # on that laptop. Any other reason is a real failure - this installer
    # logged in to the bridge moments ago.
    GUARD_MSG="${CONFIG_ROOT}/guard-${LOCAL_PORT}.msg"
    for _ in $(seq 1 20); do
        lsof -nP -iTCP@127.0.0.1:"$LOCAL_PORT" -sTCP:LISTEN -Fc 2>/dev/null | grep -qx 'cssh' && break
        [ -s "$GUARD_MSG" ] && break
        sleep 1
    done
    if ! lsof -nP -iTCP@127.0.0.1:"$LOCAL_PORT" -sTCP:LISTEN -Fc 2>/dev/null | grep -qx 'cssh'; then
        GUARD_KIND=""
        GUARD_REASON=""
        { read -r GUARD_KIND GUARD_REASON < "$GUARD_MSG"; } 2>/dev/null || true
        if [ "$GUARD_KIND" = "in-use" ]; then
            important "Installed, but the tunnel is waiting: ${GUARD_REASON}"
            TUNNEL_WAITING=1
        else
            warning "127.0.0.1:${LOCAL_PORT} is not held by the tunnel's ssh - adb clients on this machine will not reach the bridge.${GUARD_REASON:+ The guard says: ${GUARD_REASON}}"
            HEALTH_OK=0
        fi
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
    for CHECK_PORT in "$WEB_LOCAL_PORT" "$PANELS_LOCAL_PORT" "$PANELS_WS_LOCAL_PORT" "$PEDRO_TUNER_LOCAL_PORT" "$PEDRO_TUNER_WS_LOCAL_PORT" "$DASH_WS_LOCAL_PORT" "$HUB_8092_LOCAL_PORT"; do
        [ "$TUNNEL_WAITING" = "1" ] && break
        if ! lsof -nP -iTCP:"$CHECK_PORT" -sTCP:LISTEN -Fc 2>/dev/null | grep -qx 'cssh'; then
            warning "port $CHECK_PORT is not held by the tunnel's ssh - that web tool will not reach the Control Hub."
            HEALTH_OK=0
        fi
    done
elif [ "$PLATFORM" = "windows" ]; then
    # Listening is not enough on LOCAL_PORT: a rogue local adb server sitting
    # there reports healthy while adb clients never reach the bridge. Require
    # the tunnel's own ssh, the same assertion the macOS path makes, and read
    # a waiting guard's message the same way. Polled: PowerShell starts twice
    # before ssh does, and the guard may spend 10 s checking the bridge.
    GUARD_MSG="${INSTALL_DIR}/guard-${LOCAL_PORT}.msg"
    for _ in $(seq 1 30); do
        [ "$(windows_listener_image "$LOCAL_PORT")" = "ssh.exe" ] && break
        [ -s "$GUARD_MSG" ] && break
        sleep 1
    done
    LOCAL_LISTENER="$(windows_listener_image "$LOCAL_PORT")"
    if [ "$LOCAL_LISTENER" != "ssh.exe" ]; then
        GUARD_KIND=""
        GUARD_REASON=""
        { read -r GUARD_KIND GUARD_REASON < "$GUARD_MSG"; } 2>/dev/null || true
        if [ "$GUARD_KIND" = "in-use" ]; then
            important "Installed, but the tunnel is waiting: ${GUARD_REASON}"
            TUNNEL_WAITING=1
        else
            warning "port ${LOCAL_PORT} is held by ${LOCAL_LISTENER:-nothing}, not the tunnel's ssh.exe - adb clients will not reach the bridge.${GUARD_REASON:+ The guard says: ${GUARD_REASON}}"
            HEALTH_OK=0
        fi
    fi
    for CHECK_PORT in "$WEB_LOCAL_PORT" "$PANELS_LOCAL_PORT" "$PANELS_WS_LOCAL_PORT" "$PEDRO_TUNER_LOCAL_PORT" "$PEDRO_TUNER_WS_LOCAL_PORT" "$DASH_WS_LOCAL_PORT" "$HUB_8092_LOCAL_PORT"; do
        [ "$TUNNEL_WAITING" = "1" ] && break
        if ! command -v netstat >/dev/null 2>&1 || ! netstat -ano 2>/dev/null | grep -q ":${CHECK_PORT} .*LISTENING"; then
            warning "port $CHECK_PORT is not listening - tunnel did not come up cleanly."
            HEALTH_OK=0
        fi
    done
elif [ "$PLATFORM" = "linux" ]; then
    # Same standard as macOS: the adb forward is declared on 127.0.0.1 only, so
    # check that address specifically - an adb server that auto-spawned on the
    # machine in the gap before our ssh started would otherwise pass.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        linux_port_held_by_ssh "$LOCAL_PORT" "127.0.0.1" && break
        sleep 1
    done
    if ! linux_port_held_by_ssh "$LOCAL_PORT" "127.0.0.1"; then
        warning "127.0.0.1:${LOCAL_PORT} is not held by the tunnel's ssh - adb clients on this machine will not reach the bridge."
        HEALTH_OK=0
    fi
    for CHECK_PORT in "$WEB_LOCAL_PORT" "$PANELS_LOCAL_PORT" "$PANELS_WS_LOCAL_PORT" "$PEDRO_TUNER_LOCAL_PORT" "$PEDRO_TUNER_WS_LOCAL_PORT" "$DASH_WS_LOCAL_PORT" "$HUB_8092_LOCAL_PORT"; do
        if ! linux_port_held_by_ssh "$CHECK_PORT"; then
            warning "port $CHECK_PORT is not held by the tunnel's ssh - that web tool will not reach the Control Hub."
            HEALTH_OK=0
        fi
    done
fi

if [ "$AUTO" = "1" ]; then
    if [ "$HEALTH_OK" = "0" ]; then
        warning "Auto-update replay did NOT bring the tunnel up cleanly - see log for ${REMOTE_HOST}."
        exit 1
    fi
else
    echo ""
    if [ "$HEALTH_OK" = "1" ] && [ "$TUNNEL_WAITING" = "1" ]; then
        section "=== Done (tunnel waiting) ==="
        echo "Relay is installed, but this laptop's own adb server is in use, so the tunnel waits for it."
        echo "To hand the port to Relay: unplug or 'adb disconnect' that device, then run 'adb kill-server'."
        case "$PLATFORM" in
            mac) echo "The tunnel then starts within about 15 seconds. Its log: /tmp/adbtunnel-${SAFE_HOST}.err" ;;
            windows) echo "The tunnel then starts within about 15 seconds. Its log: ${LOG_FILE_WIN}" ;;
        esac
    elif [ "$HEALTH_OK" = "1" ]; then
        section "=== Done ==="
        echo "adb server should be reachable at localhost:${LOCAL_PORT}."
        echo "Control Hub web interface (Program & Manage) should be reachable at http://localhost:${WEB_LOCAL_PORT}"
        echo "Panels dashboard (if used) should be reachable at http://localhost:${PANELS_LOCAL_PORT}"
        echo "PedroPathing autotuner (if used) should be reachable at localhost:${PEDRO_TUNER_LOCAL_PORT}"
        echo "Quit and reopen Android Studio, confirm the device shows up before deploying."
    else
        warning "Setup ran, but the tunnel is NOT confirmed healthy"
        echo "One or more forwarded ports never came up. Likely cause: something else is"
        echo "already bound to one of ${LOCAL_PORT}/${WEB_LOCAL_PORT}/${PANELS_LOCAL_PORT}/${PANELS_WS_LOCAL_PORT}/${PEDRO_TUNER_LOCAL_PORT}/${PEDRO_TUNER_WS_LOCAL_PORT}/${DASH_WS_LOCAL_PORT}/${HUB_8092_LOCAL_PORT} -"
        echo "ExitOnForwardFailure kills the WHOLE tunnel if even one forward fails, so the"
        echo "adb forward can be down even though only the web-interface port collided."
        case "$PLATFORM" in
            mac) echo "Check: /tmp/adbtunnel-${SAFE_HOST}.log and /tmp/adbtunnel-${SAFE_HOST}.err" ;;
            windows) echo "Check: ${LOG_FILE_WIN}" ;;
            linux) echo "Check: ${LINUX_LOG}" ;;
        esac
        exit 1
    fi
fi
