#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
INSTALLED_CONFIG="/etc/obscura-blacklist/blacklist.conf"
INSTALLED_SOURCES_DIR="/etc/obscura-blacklist/sources"
REPO_SOURCES_DIR="$REPO_ROOT/blacklist/config/sources"
MODE="installed"

usage() {
    cat <<EOF
Usage: sudo sh $0 [--installed|--repo]

Modes:
  --installed  Refresh using /etc/obscura-blacklist/blacklist.conf and /etc/obscura-blacklist/sources (default)
  --repo       Copy repo source files into /etc/obscura-blacklist/sources, then refresh the installed blacklist
EOF
}

copy_repo_sources_into_installed_dir() {
    if [ ! -f "$INSTALLED_CONFIG" ]; then
        echo "ERROR: installed blacklist config not found at $INSTALLED_CONFIG" >&2
        echo "Install the blacklist module first, or use the installed mode on a host where it is already installed." >&2
        exit 1
    fi

    if [ ! -d "$REPO_SOURCES_DIR" ]; then
        echo "ERROR: repo source directory not found: $REPO_SOURCES_DIR" >&2
        exit 1
    fi

    mkdir -p "$INSTALLED_SOURCES_DIR"

    copied_any=false
    for source_path in "$REPO_SOURCES_DIR"/*; do
        if [ ! -e "$source_path" ]; then
            continue
        fi
        if [ ! -f "$source_path" ]; then
            continue
        fi
        install -m 0644 "$source_path" "$INSTALLED_SOURCES_DIR/$(basename "$source_path")"
        copied_any=true
    done

    if [ "$copied_any" = false ]; then
        echo "ERROR: no repo source files found in $REPO_SOURCES_DIR" >&2
        exit 1
    fi

    echo "Copied repo blacklist source files into $INSTALLED_SOURCES_DIR"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --installed)
            MODE="installed"
            ;;
        --repo)
            MODE="repo"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
    shift
done

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: refresh-blacklist.sh must be run as root." >&2
    echo "Run: sudo sh $0" >&2
    exit 1
fi

if [ "$MODE" = "repo" ]; then
    copy_repo_sources_into_installed_dir
fi

exec /usr/local/bin/obscura-blacklist --config "$INSTALLED_CONFIG" refresh
