#!/bin/bash
# adb-tunnel-updater.sh
# Run daily by the LaunchAgent (mac) or Scheduled Task (Windows) that
# install.sh registers - only for key-auth tunnels. Only applies an update
# if the repo's VERSION file increased. Downloads are syntax-checked before
# anything touches the running tunnel; any failure leaves the current
# install untouched.
#
# "Increased" is literal. Comparing with != also fires when the repo's VERSION
# is *lower* than what is installed, so reverting a bad bump on main would
# silently roll every laptop backwards - the exact opposite of what the
# script says it does.

set -uo pipefail

REPO_RAW="https://raw.githubusercontent.com/Bob-41/Relay/main"

case "$(uname -s)" in
    Darwin) CONFIG_ROOT="${HOME}/.config/adb-tunnel"; LOG_FILE="/tmp/adbtunnel-updater.log" ;;
    MINGW*|MSYS*|CYGWIN*)
        CONFIG_ROOT="$(cygpath -u "$APPDATA")/adb-tunnel/config"
        LOG_FILE="$(cygpath -u "$APPDATA")/adb-tunnel/updater.log"
        ;;
    *) CONFIG_ROOT="${HOME}/.config/adb-tunnel"; LOG_FILE="/tmp/adbtunnel-updater.log" ;;
esac

STATE_FILE="${CONFIG_ROOT}/../installed-version"
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

REMOTE_VERSION="$(curl -fsSL --max-time 15 "${REPO_RAW}/VERSION" 2>/dev/null)"
if [ -z "$REMOTE_VERSION" ]; then
    log "Could not fetch remote VERSION - skipping."
    exit 0
fi
LOCAL_VERSION="0"
[ -f "$STATE_FILE" ] && LOCAL_VERSION="$(cat "$STATE_FILE")"
if [ "$REMOTE_VERSION" = "$LOCAL_VERSION" ]; then
    log "Already at VERSION ${LOCAL_VERSION}. Nothing to do."
    exit 0
fi
if ! version_newer "$REMOTE_VERSION" "$LOCAL_VERSION"; then
    log "Repo VERSION (${REMOTE_VERSION}) is not newer than this laptop's (${LOCAL_VERSION}) - skipping."
    log "A reverted or re-pinned VERSION must not roll this laptop backwards."
    exit 0
fi

log "VERSION ${LOCAL_VERSION} -> ${REMOTE_VERSION}. Fetching update..."
curl -fsSL --max-time 15 -o "${TMP_DIR}/install.sh" "${REPO_RAW}/laptop/install.sh" || { log "ERROR: download failed."; exit 1; }
curl -fsSL --max-time 15 -o "${TMP_DIR}/adb-tunnel-updater.sh" "${REPO_RAW}/laptop/adb-tunnel-updater.sh" || { log "ERROR: download failed."; exit 1; }

for f in install.sh adb-tunnel-updater.sh; do
    if ! bash -n "${TMP_DIR}/${f}"; then
        log "ERROR: ${f} fails syntax check. NOT applying. Current tunnel(s) left untouched."
        exit 1
    fi
done

FAILED=0
for cfg in "${CONFIG_ROOT}"/*.env; do
    [ -e "$cfg" ] || continue
    log "Updating tunnel config: $cfg"
    if bash "${TMP_DIR}/install.sh" --auto "$cfg" >>"$LOG_FILE" 2>&1; then
        log "OK: $cfg"
    else
        log "ERROR applying update for $cfg - left previous tunnel running for this host."
        FAILED=1
    fi
done

if [ "$FAILED" = "0" ]; then
    echo "$REMOTE_VERSION" > "$STATE_FILE"
    # Refresh this script by rename, never by overwriting it in place. bash has
    # the old file open and reads it lazily by byte offset; `cp new "$0"` while
    # the new version is longer than the old one makes the running process
    # continue executing from the middle of unrelated bytes. Only bites when the
    # updater itself changed, which is exactly when it must not.
    SELF_DIR="$(dirname "$0")"
    if cp "${TMP_DIR}/adb-tunnel-updater.sh" "${SELF_DIR}/.adb-tunnel-updater.sh.new.$$" 2>/dev/null \
        && chmod 755 "${SELF_DIR}/.adb-tunnel-updater.sh.new.$$" 2>/dev/null \
        && mv -f "${SELF_DIR}/.adb-tunnel-updater.sh.new.$$" "$0"; then
        log "Refreshed ${0}."
    else
        rm -f "${SELF_DIR}/.adb-tunnel-updater.sh.new.$$" 2>/dev/null || true
        log "WARNING: could not refresh ${0} - this copy stays as-is until the next VERSION bump."
    fi
    log "Update to VERSION ${REMOTE_VERSION} applied successfully."
else
    log "One or more tunnels failed to update - VERSION not bumped, will retry next run."
    exit 1
fi
