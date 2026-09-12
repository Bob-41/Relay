#!/usr/bin/env bash
# check-for-updates.sh
# Manually run the same update check the nightly LaunchAgent (mac) or
# Scheduled Task (Windows) already runs at 3am, instead of waiting for it.
# Does not duplicate any of the updater's logic - just finds the copy
# install.sh already installed for this laptop and runs it. All the real
# safety logic (VERSION check, syntax-check before applying, per-config
# apply, leave-untouched-on-failure) lives in that script, not here.
#
# Only works for key-auth tunnels - password-auth tunnels never get an
# updater installed (see adb-tunnel-updater.sh header for why), so there's
# nothing here to trigger for those; re-run install.sh manually instead.

set -uo pipefail

# Paths must match exactly where laptop/install.sh deploys the updater
# (see UPDATER_DEST in install.sh) - do not guess at alternate locations.
case "$(uname -s)" in
    Darwin)
        UPDATER="${HOME}/.config/adb-tunnel-updater.sh"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        if [ -z "${APPDATA:-}" ]; then
            echo "APPDATA is not set - can't locate the updater. Run this from a normal Git Bash session on Windows."
            exit 1
        fi
        UPDATER="$(cygpath -u "$APPDATA")/adb-tunnel/adb-tunnel-updater.sh"
        ;;
    *)
        echo "No installed updater for this platform - plain Linux tunnels are manual-only (see laptop/install.sh)."
        exit 1
        ;;
esac

if [ ! -f "$UPDATER" ]; then
    echo "No updater found at: $UPDATER"
    echo "This usually means one of:"
    echo "  - this laptop's tunnel uses password auth (no updater is installed for that path)"
    echo "  - laptop/install.sh hasn't been run on this laptop yet"
    echo "Run laptop/install.sh first if you haven't already."
    exit 1
fi

echo "Found updater at: $UPDATER"
echo "Running it now (identical to what the nightly schedule runs)..."
exec bash "$UPDATER"
