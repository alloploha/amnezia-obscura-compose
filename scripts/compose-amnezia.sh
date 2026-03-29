#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

cd "$REPO_ROOT"

if [ "$#" -eq 0 ]; then
    set -- up -d --build
fi

exec docker compose -f compose.yaml -f compose.amnezia.yaml "$@"
