#!/bin/bash
# adb-forwarder-updater.sh
# Run nightly by adb-forwarder-updater.timer. Only applies an update if the
# repo's VERSION file increased since last time - a broken commit that forgets
# to bump VERSION never gets pulled, and a version bump that is later reverted
# never rolls every bridge backwards. Downloads are syntax-checked with
# `bash -n` before anything touches the running install.
#
# `bash -n` is a syntax check, not a safety check: whatever is on main runs
# unattended as root on every registered bridge. Keep the repository protected
# (2FA on every maintainer account, branch protection on main, no web edits),
# and pin the check to a tag rather than a moving branch if you need more than
# that. `echo manual > /etc/adb-forwarder/update-policy` turns this into a
# report-only checker: it still reports an available VERSION every night and
# applies nothing until you remove that file.
#
# On failure this exits non-zero, restores the previous install, and leaves the
# locally recorded VERSION alone so the next run retries.

set -uo pipefail  # not -e: we want to log+exit cleanly on failure, not abort mid-cleanup

REPO_RAW="https://raw.githubusercontent.com/Bob-41/Relay/main"
STATE_DIR="/etc/adb-forwarder"
INSTALLED_VERSION_FILE="${STATE_DIR}/installed-version"
UPDATE_POLICY_FILE="${STATE_DIR}/update-policy"
CONFIG_FILE="${STATE_DIR}/config.env"
LOG_FILE="/var/log/adb-forwarder.log"
ROLLBACK_ROOT="/var/lib/adb-forwarder/rollback"
# Everything install.sh --auto (and this script) writes. Snapshotted before an
# apply so a bad release can be put back the way it was.
MANAGED_PATHS=(
    /usr/local/bin/adb-forwarder-connect.sh
    /usr/local/bin/adb-forwarder-updater.sh
    /etc/systemd/system/adb-forwarder-server.service
    /etc/systemd/system/adb-forwarder-connect.service
    /etc/systemd/system/adb-forwarder-updater.service
    /etc/systemd/system/adb-forwarder-updater.timer
    /etc/polkit-1/rules.d/50-adb-forwarder-nm.rules
    /etc/logrotate.d/adb-forwarder
    /usr/local/bin/adb
)
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [updater] $*" | tee -a "$LOG_FILE"; }

# True when $1 is strictly newer than $2. Both must parse as a version, so a
# merge-conflict marker or an HTML error page in VERSION can only ever block an
# update - never be mistaken for one.
version_is_parseable() {
    printf '%s' "$1" | grep -qE '^[vV]?[0-9]+([._-][0-9]+)*$'
}

version_newer() {
    local a="$1" b="$2"
    version_is_parseable "$a" && version_is_parseable "$b" || return 1
    a="${a#[vV]}"
    b="${b#[vV]}"
    [ "$a" != "$b" ] || return 1
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V 2>/dev/null | head -n1)" = "$b" ]
}

# --- Snapshot / restore -------------------------------------------------------

snapshot() {
    local dest="$1" p
    mkdir -p "$dest"
    for p in "${MANAGED_PATHS[@]}"; do
        [ -e "$p" ] || continue
        mkdir -p "$dest$(dirname "$p")"
        cp -a "$p" "$dest$p"
    done
    printf '%s\n' "$2" > "${dest}/from-version"
}

restore() {
    local src="$1" p target
    log "Restoring the previous install from ${src}..."
    for target in "${MANAGED_PATHS[@]}"; do
        p="${src}${target}"
        [ -e "$p" ] || continue
        mkdir -p "$(dirname "$target")"
        cp -a "$p" "$target"
        log "  restored ${target}"
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart adb-forwarder-server.service >/dev/null 2>&1 || true
    systemctl restart adb-forwarder-connect.service >/dev/null 2>&1 || true
}

# --- Health check after an apply ----------------------------------------------
# install.sh --auto exiting 0 only means the script ran to the end. What has to
# be true afterwards is that the bridge is actually serving: unit active, port
# bound. Reported failure is the difference between "applied successfully" in
# the log and a workshop that silently cannot deploy.
health_check() {
    local port="$1" rc=0 listen _
    if ! systemctl is-active --quiet adb-forwarder-server.service; then
        log "HEALTH: adb-forwarder-server.service is not active."
        rc=1
    fi
    # Give the unit a few seconds to bind before calling it broken - install.sh
    # restarts it moments ago and RestartSec=3 means a respawn can be in flight.
    listen=""
    for _ in 1 2 3 4 5; do
        listen="$(ss -ltn 2>/dev/null | awk -v p=":${port}$" '$4 ~ p { print $4; exit }')"
        [ -n "$listen" ] && break
        sleep 2
    done
    if [ -z "$listen" ]; then
        log "HEALTH: nothing is listening on port ${port}."
        rc=1
    else
        log "HEALTH: adb server listening on ${listen}."
        case "$listen" in
            127.0.0.1:*|\[::1\]:*) ;;
            *) log "HEALTH: WARNING - bound to ${listen}, not loopback. The shared adb server is LAN-reachable." ;;
        esac
    fi
    if ! systemctl is-active --quiet adb-forwarder-connect.service; then
        # Not fatal: this service is expected to be running even while the
        # Control Hub is off - it loops and waits. Say so rather than rolling
        # back a perfectly good install over a powered-off robot.
        log "HEALTH: note - adb-forwarder-connect.service is not active (it also stays up with the hub off; check journalctl -u adb-forwarder-connect.service)."
    fi
    return "$rc"
}

# --- Check for an update ------------------------------------------------------

REMOTE_VERSION="$(curl -fsSL --max-time 15 "${REPO_RAW}/VERSION" 2>/dev/null)"
if [ -z "$REMOTE_VERSION" ]; then
    log "Could not fetch remote VERSION - skipping (offline or GitHub unreachable)."
    exit 0
fi

LOCAL_VERSION="0"
[ -f "$INSTALLED_VERSION_FILE" ] && LOCAL_VERSION="$(cat "$INSTALLED_VERSION_FILE")"

if [ "$REMOTE_VERSION" = "$LOCAL_VERSION" ]; then
    log "Already at VERSION ${LOCAL_VERSION}. Nothing to do."
    exit 0
fi
if ! version_newer "$REMOTE_VERSION" "$LOCAL_VERSION"; then
    log "Repo VERSION (${REMOTE_VERSION}) is not newer than this bridge's (${LOCAL_VERSION}) - skipping."
    log "A reverted or re-pinned VERSION must not roll this bridge backwards."
    exit 0
fi

log "VERSION ${LOCAL_VERSION} -> ${REMOTE_VERSION}."

if [ -f "$UPDATE_POLICY_FILE" ] && grep -qiw 'manual' "$UPDATE_POLICY_FILE" 2>/dev/null; then
    log "update-policy says manual - NOT applying. Review the VERSION bump on the repo, then:"
    log "  sudo rm ${UPDATE_POLICY_FILE} && systemctl start adb-forwarder-updater.service"
    exit 0
fi

log "Fetching update..."
curl -fsSL --max-time 15 -o "${TMP_DIR}/install.sh" "${REPO_RAW}/bridge/install.sh" || {
    log "ERROR: failed to download install.sh. Aborting update."; exit 1;
}
curl -fsSL --max-time 15 -o "${TMP_DIR}/adb-forwarder-connect.sh" "${REPO_RAW}/bridge/adb-forwarder-connect.sh" || {
    log "ERROR: failed to download adb-forwarder-connect.sh. Aborting update."; exit 1;
}
curl -fsSL --max-time 15 -o "${TMP_DIR}/adb-forwarder-updater.sh" "${REPO_RAW}/bridge/adb-forwarder-updater.sh" || {
    log "ERROR: failed to download adb-forwarder-updater.sh. Aborting update."; exit 1;
}

for f in install.sh adb-forwarder-connect.sh adb-forwarder-updater.sh; do
    if ! bash -n "${TMP_DIR}/${f}"; then
        log "ERROR: ${f} fails syntax check. NOT applying this update. Current install left untouched."
        exit 1
    fi
done

SNAPSHOT_DIR="${ROLLBACK_ROOT}/$(date +%Y%m%d-%H%M%S)-from-v${LOCAL_VERSION}"
snapshot "$SNAPSHOT_DIR" "$LOCAL_VERSION"
# Keep the newest three snapshots and delete the rest, so /var/lib does not
# grow by a copy of every release forever. `awk 'NR>3'` rather than `head -n -3`
# because negative head counts are a GNU extension.
find "$ROLLBACK_ROOT" -maxdepth 1 -mindepth 1 -type d -name '*-from-v*' -print 2>/dev/null \
    | sort | awk 'NR > 3' | while read -r old; do rm -rf "$old"; done

ADB_PORT="5037"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    ADB_PORT="$( . "$CONFIG_FILE" >/dev/null 2>&1; printf '%s' "${ADB_PORT:-5037}" )"
fi

log "Applying via install.sh --auto (snapshot: ${SNAPSHOT_DIR})..."
if ! bash "${TMP_DIR}/install.sh" --auto >>"$LOG_FILE" 2>&1; then
    log "ERROR: install.sh --auto failed. Rolling back."
    restore "$SNAPSHOT_DIR"
    log "ERROR: VERSION not bumped locally - will retry next run."
    exit 1
fi

if ! health_check "$ADB_PORT"; then
    log "ERROR: update applied but the bridge is not healthy. Rolling back."
    restore "$SNAPSHOT_DIR"
    if health_check "$ADB_PORT"; then
        log "Rolled back to VERSION ${LOCAL_VERSION}; the bridge is serving again."
    else
        log "WARNING: the bridge is STILL not healthy after rollback. Needs hands on it:"
        log "  journalctl -u adb-forwarder-server.service -u adb-forwarder-connect.service -n 50"
    fi
    log "ERROR: VERSION not bumped locally - will retry next run."
    exit 1
fi

echo "$REMOTE_VERSION" > "$INSTALLED_VERSION_FILE"
# Refresh our own copy so next run's diff/logic changes take effect too.
# Never write the running script in place: this process is still reading it, and
# a longer replacement silently shifts the bytes bash is executing. Write
# alongside, then rename over it - rename is atomic and the running interpreter
# keeps its open copy of the old inode.
SELF_DIR="$(dirname "$0")"
if install -m 755 "${TMP_DIR}/adb-forwarder-updater.sh" "${SELF_DIR}/.adb-forwarder-updater.sh.new.$$" 2>/dev/null \
    && mv -f "${SELF_DIR}/.adb-forwarder-updater.sh.new.$$" "$0"; then
    log "Refreshed ${0}."
else
    rm -f "${SELF_DIR}/.adb-forwarder-updater.sh.new.$$" 2>/dev/null || true
    log "WARNING: could not refresh ${0} - this run's logic stays in place until the next VERSION bump."
fi
log "Update to VERSION ${REMOTE_VERSION} applied and verified healthy."