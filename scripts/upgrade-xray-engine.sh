#!/usr/bin/env bash
set -euo pipefail

DEFAULT_CONTAINER="amnezia-xray"
DEFAULT_PROJECT_LABEL="com.docker.compose.project=obscura"
DEFAULT_SERVICE_LABEL="com.docker.compose.service=xray"
DEFAULT_CONTAINER_NUMBER_LABEL="com.docker.compose.container-number=1"
DEFAULT_RELEASE="latest"
DEFAULT_RESTART_TIMEOUT="${XRAY_UPGRADE_RESTART_TIMEOUT:-30}"

ACTION=""
CONTAINER_NAME=""
RELEASE_NAME="$DEFAULT_RELEASE"
FORCE=0
RESTART_TIMEOUT="$DEFAULT_RESTART_TIMEOUT"

TMPDIR=""
ZIP_PATH=""
DOWNLOADED_BINARY=""
DOWNLOAD_URL=""
TARGET_BINARY_PATH=""
CURRENT_VERSION=""
DOWNLOADED_VERSION=""

usage() {
    cat <<'EOF'
Usage: upgrade-xray-engine.sh <command> [options]

Inspect or in-place upgrade the Xray binary inside a running container.

This helper is intended for rare urgent cases where the Xray engine inside an
existing container must be updated without rebuilding the full image layer.
It downloads and extracts only the `xray` binary on the host, copies that
single file into the container with `docker cp`, then restarts the container.

Commands:
  current                      Show the current container Xray path and version
  compare                      Show the current container version and a freshly downloaded version
  upgrade                      Download, compare, copy the binary into the container, restart, and verify

Options:
  --container <name>           Target container name
                               Default: amnezia-xray if present, otherwise the running Obscura xray container
  --release <tag|latest>       Upstream Xray release tag or `latest`, default latest
  --force                      Install even if the downloaded version matches the current one
  -h, --help                   Show this help

Examples:
  sudo bash scripts/upgrade-xray-engine.sh current --container amnezia-xray
  sudo bash scripts/upgrade-xray-engine.sh compare --container obscura-xray-1
  sudo bash scripts/upgrade-xray-engine.sh upgrade --container amnezia-xray
  sudo bash scripts/upgrade-xray-engine.sh upgrade --container obscura-xray-1 --release v25.8.3
EOF
}

log() {
    printf '%s\n' "$*"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'ERROR: required command not found: %s\n' "$1" >&2
        exit 1
    }
}

cleanup() {
    local exit_code=$?

    if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
        rm -rf "$TMPDIR"
    fi

    exit "$exit_code"
}

parse_args() {
    [ "$#" -gt 0 ] || {
        usage
        exit 1
    }

    case "$1" in
        current|compare|upgrade)
            ACTION="$1"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'ERROR: unknown command: %s\n' "$1" >&2
            usage
            exit 1
            ;;
    esac

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --container)
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --container\n' >&2
                    exit 1
                }
                CONTAINER_NAME="$2"
                shift 2
                ;;
            --release)
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --release\n' >&2
                    exit 1
                }
                RELEASE_NAME="$2"
                shift 2
                ;;
            --force)
                FORCE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                printf 'ERROR: unknown argument: %s\n' "$1" >&2
                usage
                exit 1
                ;;
        esac
    done
}

discover_container() {
    if [ -n "$CONTAINER_NAME" ]; then
        return
    fi

    if docker inspect "$DEFAULT_CONTAINER" >/dev/null 2>&1; then
        CONTAINER_NAME="$DEFAULT_CONTAINER"
        return
    fi

    CONTAINER_NAME="$(
        docker ps \
            --filter "label=$DEFAULT_PROJECT_LABEL" \
            --filter "label=$DEFAULT_SERVICE_LABEL" \
            --filter "label=$DEFAULT_CONTAINER_NUMBER_LABEL" \
            --format '{{.Names}}' \
            | head -n 1
    )"

    if [ -z "$CONTAINER_NAME" ]; then
        printf 'ERROR: no target xray container found\n' >&2
        printf 'ERROR: use --container to specify one explicitly\n' >&2
        exit 1
    fi
}

require_running_container() {
    local state

    docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || {
        printf 'ERROR: container not found: %s\n' "$CONTAINER_NAME" >&2
        exit 1
    }

    state="$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")"
    if [ "$state" != "running" ]; then
        printf 'ERROR: container %s is not running (state=%s)\n' "$CONTAINER_NAME" "$state" >&2
        exit 1
    fi
}

read_current_version() {
    TARGET_BINARY_PATH="$(docker exec "$CONTAINER_NAME" sh -lc 'command -v xray')"
    CURRENT_VERSION="$(docker exec "$CONTAINER_NAME" sh -lc 'xray version | head -n 1')"

    if [ -z "$TARGET_BINARY_PATH" ] || [ -z "$CURRENT_VERSION" ]; then
        printf 'ERROR: failed to detect current Xray path or version inside %s\n' "$CONTAINER_NAME" >&2
        exit 1
    fi
}

prepare_tmpdir() {
    if [ -n "$TMPDIR" ]; then
        return
    fi

    TMPDIR="$(mktemp -d)"
    ZIP_PATH="$TMPDIR/Xray-linux-64.zip"
    DOWNLOADED_BINARY="$TMPDIR/xray"
}

build_download_url() {
    if [ "$RELEASE_NAME" = "latest" ]; then
        DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
    else
        DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${RELEASE_NAME}/Xray-linux-64.zip"
    fi
}

download_release_binary() {
    prepare_tmpdir
    build_download_url

    curl --fail --silent --show-error --location "$DOWNLOAD_URL" -o "$ZIP_PATH"
    unzip -j -o "$ZIP_PATH" xray -d "$TMPDIR" >/dev/null
    chmod 0755 "$DOWNLOADED_BINARY"

    DOWNLOADED_VERSION="$("$DOWNLOADED_BINARY" version | head -n 1)"
    if [ -z "$DOWNLOADED_VERSION" ]; then
        printf 'ERROR: failed to read downloaded Xray version from %s\n' "$DOWNLOADED_BINARY" >&2
        exit 1
    fi
}

print_current_summary() {
    log "Current container Xray:"
    log "  container: $CONTAINER_NAME"
    log "  binary path: $TARGET_BINARY_PATH"
    log "  version: $CURRENT_VERSION"
}

print_compare_summary() {
    print_current_summary
    log "Downloaded Xray candidate:"
    log "  release selector: $RELEASE_NAME"
    log "  download URL: $DOWNLOAD_URL"
    log "  extracted binary: $DOWNLOADED_BINARY"
    log "  version: $DOWNLOADED_VERSION"
}

wait_for_restart() {
    local attempt
    local state

    for attempt in $(seq 1 "$RESTART_TIMEOUT"); do
        state="$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")"
        if [ "$state" = "running" ]; then
            return 0
        fi
        sleep 1
    done

    printf 'ERROR: container %s did not return to running state after restart\n' "$CONTAINER_NAME" >&2
    exit 1
}

install_downloaded_binary() {
    docker cp "$DOWNLOADED_BINARY" "$CONTAINER_NAME:/tmp/xray.upgrade"
    docker exec "$CONTAINER_NAME" sh -lc "cp /tmp/xray.upgrade '$TARGET_BINARY_PATH' && chmod 0755 '$TARGET_BINARY_PATH' && rm -f /tmp/xray.upgrade"
}

upgrade_container() {
    if [ "$FORCE" -eq 0 ] && [ "$CURRENT_VERSION" = "$DOWNLOADED_VERSION" ]; then
        log "Current Xray version already matches the downloaded version."
        log "Use --force to reinstall the same version anyway."
        return
    fi

    install_downloaded_binary
    docker restart "$CONTAINER_NAME" >/dev/null
    wait_for_restart

    CURRENT_VERSION="$(docker exec "$CONTAINER_NAME" sh -lc 'xray version | head -n 1')"
    if [ "$CURRENT_VERSION" != "$DOWNLOADED_VERSION" ]; then
        printf 'ERROR: upgraded Xray version (%s) does not match downloaded version (%s)\n' "$CURRENT_VERSION" "$DOWNLOADED_VERSION" >&2
        exit 1
    fi

    log "Xray binary upgraded in place:"
    log "  container: $CONTAINER_NAME"
    log "  binary path: $TARGET_BINARY_PATH"
    log "  installed version: $CURRENT_VERSION"
}

main() {
    trap cleanup EXIT

    parse_args "$@"

    require_cmd curl
    require_cmd docker
    require_cmd unzip

    discover_container
    require_running_container
    read_current_version

    case "$ACTION" in
        current)
            print_current_summary
            ;;
        compare)
            download_release_binary
            print_compare_summary
            ;;
        upgrade)
            download_release_binary
            print_compare_summary
            upgrade_container
            ;;
        *)
            printf 'ERROR: unsupported command: %s\n' "$ACTION" >&2
            exit 1
            ;;
    esac
}

main "$@"
