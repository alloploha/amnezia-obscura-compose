#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BLACKLIST_BIN="$REPO_ROOT/blacklist/bin/obscura-blacklist"
INSTALLED_CONFIG="/etc/obscura-blacklist/blacklist.conf"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: install-blacklist.sh must be run as root." >&2
    echo "Run: sudo sh $0" >&2
    exit 1
fi

python3 "$BLACKLIST_BIN" install-systemd
exec /usr/local/bin/obscura-blacklist --config "$INSTALLED_CONFIG" refresh
