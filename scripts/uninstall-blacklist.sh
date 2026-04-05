#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BLACKLIST_BIN="$REPO_ROOT/blacklist/bin/obscura-blacklist"
INSTALLED_CONFIG="/etc/obscura-blacklist/blacklist.conf"
SERVICE_NAME="obscura-blacklist.service"
TIMER_NAME="obscura-blacklist.timer"

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

wait_inactive() {
    unit_name="$1"
    attempts=30
    while [ "$attempts" -gt 0 ]; do
        state=$(systemctl is-active "$unit_name" 2>/dev/null || true)
        case "$state" in
            inactive|failed|unknown|not-found)
                return 0
                ;;
        esac
        sleep 1
        attempts=$((attempts - 1))
    done
    return 1
}

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: uninstall-blacklist.sh must be run as root." >&2
    echo "Run: sudo sh $0" >&2
    exit 1
fi

if ! have_cmd python3; then
    echo "ERROR: python3 is not installed or not in PATH." >&2
    echo "Install Python 3 before running this script." >&2
    exit 1
fi

if ! have_cmd systemctl; then
    echo "ERROR: systemctl is not installed or not in PATH." >&2
    echo "Blacklist uninstall expects a systemd-managed installation." >&2
    exit 1
fi

systemctl disable --now "$TIMER_NAME" >/dev/null 2>&1 || true
systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

if ! wait_inactive "$TIMER_NAME"; then
    echo "ERROR: timed out waiting for $TIMER_NAME to stop." >&2
    exit 1
fi

if ! wait_inactive "$SERVICE_NAME"; then
    echo "ERROR: timed out waiting for $SERVICE_NAME to stop." >&2
    exit 1
fi

if [ -f "$INSTALLED_CONFIG" ]; then
    if ! python3 "$BLACKLIST_BIN" --config "$INSTALLED_CONFIG" flush; then
        echo "WARNING: blacklist flush failed; continuing with uninstall-systemd." >&2
    fi
else
    echo "WARNING: installed blacklist config not found at $INSTALLED_CONFIG; skipping flush." >&2
fi

exec python3 "$BLACKLIST_BIN" uninstall-systemd
