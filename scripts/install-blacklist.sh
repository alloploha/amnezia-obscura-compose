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

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: install-blacklist.sh must be run as root." >&2
    echo "Run: sudo sh $0" >&2
    exit 1
fi

if ! have_cmd python3; then
    echo "ERROR: python3 is not installed or not in PATH." >&2
    echo "Install Python 3 before running this script." >&2
    exit 1
fi

if ! have_cmd docker; then
    echo "ERROR: docker is not installed or not in PATH." >&2
    echo "Install Docker Engine before running this script." >&2
    exit 1
fi

if ! have_cmd systemctl; then
    echo "ERROR: systemctl is not installed or not in PATH." >&2
    echo "Install and boot the host with systemd before running this script." >&2
    exit 1
fi

if [ ! -d /run/systemd/system ]; then
    echo "ERROR: systemd does not appear to be the active init system." >&2
    echo "Run blacklist installation on a systemd-based host." >&2
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: docker is installed, but the Docker daemon is not reachable." >&2
    echo "Start Docker and verify 'docker info' works before running this script." >&2
    exit 1
fi

if systemctl is-active --quiet "$SERVICE_NAME"; then
    systemctl stop "$SERVICE_NAME" || true
fi

python3 "$BLACKLIST_BIN" install-systemd
if ! /usr/local/bin/obscura-blacklist --config "$INSTALLED_CONFIG" check; then
    echo "ERROR: blacklist installation completed, but post-install checks failed." >&2
    echo "Fix the reported issues before retrying refresh." >&2
    exit 1
fi
exec /usr/local/bin/obscura-blacklist --config "$INSTALLED_CONFIG" refresh
