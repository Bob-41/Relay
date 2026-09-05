#!/bin/bash
# adb-forwarder-updater.sh
# Run nightly by adb-forwarder-updater.timer. Only applies an update if the
# repo's VERSION file increased since last time - a broken commit that
# forgets to bump VERSION never gets pulled. Downloads are syntax-checked
# with `bash -n` before anything touches the running install; on any
# failure this exits non-zero and leaves the current install untouched.

set -uo pipefail  # not -e: we want to log+exit cleanly on failure, not abort mid-cleanup

REPO_RAW="https://raw.githubusercontent.com/Bob-41/Relay/main"
STATE_DIR="/etc/adb-forwarder"
INSTALLED_VERSION_FILE="${STATE_DIR}/installed-version"
LOG_FILE="/var/log/adb-forwarder.log"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [updater] $*" | tee -a "$LOG_FILE"; }

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

log "VERSION ${LOCAL_VERSION} -> ${REMOTE_VERSION}. Fetching update..."

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

log "Syntax checks passed. Applying via install.sh --auto..."
if bash "${TMP_DIR}/install.sh" --auto >>"$LOG_FILE" 2>&1; then
    echo "$REMOTE_VERSION" > "$INSTALLED_VERSION_FILE"
    # Refresh our own copy so next run's diff/logic changes take effect too.
    install -m 755 "${TMP_DIR}/adb-forwarder-updater.sh" /usr/local/bin/adb-forwarder-updater.sh
    log "Update to VERSION ${REMOTE_VERSION} applied successfully."
else
    log "ERROR: install.sh --auto failed. VERSION not bumped locally - will retry next run."
    exit 1
fi
