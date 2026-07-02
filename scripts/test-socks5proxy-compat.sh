#!/usr/bin/env bash
set -euo pipefail

DEFAULT_SOURCE_IMAGE="3proxy/3proxy:busybox"
DEFAULT_SOURCE_CONTAINER="obscura-e2e-amnezia-socks5proxy"
DEFAULT_TARGET_CONTAINER="obscura-e2e-obscura-socks5proxy"
DEFAULT_NETWORK="obscura-socks5-e2e"
DEFAULT_SOURCE_PORT="19080"
DEFAULT_USER="e2e_user"
DEFAULT_PASSWORD="e2e_password"

SOURCE_IMAGE="$DEFAULT_SOURCE_IMAGE"
SOURCE_CONTAINER="$DEFAULT_SOURCE_CONTAINER"
TARGET_CONTAINER="$DEFAULT_TARGET_CONTAINER"
NETWORK_NAME="$DEFAULT_NETWORK"
SOURCE_PORT="$DEFAULT_SOURCE_PORT"
PROXY_USER="$DEFAULT_USER"
PROXY_PASSWORD="$DEFAULT_PASSWORD"
KEEP_ARTIFACTS=0

TMPDIR=""
EXTERNALIZED_DIR=""
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

usage() {
    cat <<'EOF'
Usage: test-socks5proxy-compat.sh [options]

End-to-end SOCKS5 compatibility test using a throwaway Amnezia-style 3proxy
container and an Obscura SOCKS5 compatibility-mode target.

Options:
  --keep-artifacts           Do not remove test containers/network/temp dirs
  --source-image <name>      Source Amnezia SOCKS5 image name
  --source-container <name>  Source container name
  --target-container <name>  Target Obscura SOCKS5 container name
  --network <name>           Test Docker network name
  --source-port <port>       Amnezia-style source config port
  -h, --help                 Show this help
EOF
}

log() { printf '%s\n' "$*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS: %s\n' "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL: %s\n' "$*" >&2; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'ERROR: required command not found: %s\n' "$1" >&2
        exit 1
    }
}

host_path_for_docker() {
    local path="$1"

    case "$(uname -s 2>/dev/null || true)" in
        MINGW*|MSYS*|CYGWIN*)
            if command -v cygpath >/dev/null 2>&1; then
                cygpath -w "$path"
                return
            fi
            ;;
    esac

    printf '%s\n' "$path"
}

cleanup_old_source_backups() {
    local old_container_ids

    old_container_ids="$(
        docker ps -a \
            --filter "name=${SOURCE_CONTAINER}-old-" \
            --format '{{.ID}} {{.Names}}' 2>/dev/null \
            | awk -v prefix="${SOURCE_CONTAINER}-old-" '$2 ~ "^" prefix { print $1 }'
    )"
    if [ -n "$old_container_ids" ]; then
        docker rm -f $old_container_ids >/dev/null 2>&1 || true
    fi
}

cleanup() {
    local exit_code=$?

    if [ "$KEEP_ARTIFACTS" -eq 0 ]; then
        docker rm -f "$TARGET_CONTAINER" "$SOURCE_CONTAINER" >/dev/null 2>&1 || true
        cleanup_old_source_backups
        docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
        if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
            rm -rf "$TMPDIR"
        fi
    fi

    exit "$exit_code"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --keep-artifacts) KEEP_ARTIFACTS=1; shift ;;
            --source-image) SOURCE_IMAGE="$2"; shift 2 ;;
            --source-container) SOURCE_CONTAINER="$2"; shift 2 ;;
            --target-container) TARGET_CONTAINER="$2"; shift 2 ;;
            --network) NETWORK_NAME="$2"; shift 2 ;;
            --source-port) SOURCE_PORT="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage; exit 1 ;;
        esac
    done
}

prepare_workspace() {
    TMPDIR="$(mktemp -d)"
    EXTERNALIZED_DIR="$TMPDIR/externalized-socks5"
    mkdir -p "$EXTERNALIZED_DIR"
}

build_images() {
    docker pull "$SOURCE_IMAGE" >/dev/null
    pass "prepared upstream-compatible 3proxy source image"

    docker compose --profile socks5proxy build socks5proxy >/dev/null
    pass "built Obscura SOCKS5 image"
}

prepare_network() {
    docker rm -f "$TARGET_CONTAINER" "$SOURCE_CONTAINER" >/dev/null 2>&1 || true
    cleanup_old_source_backups
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
    docker network create "$NETWORK_NAME" >/dev/null
    pass "created E2E Docker network"
}

start_source_container() {
    docker rm -f "$SOURCE_CONTAINER" >/dev/null 2>&1 || true
    MSYS_NO_PATHCONV=1 docker run -d --name "$SOURCE_CONTAINER" --network "$NETWORK_NAME" --entrypoint /bin/sh "$SOURCE_IMAGE" -c 'sleep 3600' >/dev/null

    MSYS_NO_PATHCONV=1 docker exec "$SOURCE_CONTAINER" sh -lc 'mkdir -p /opt/amnezia /usr/local/3proxy/conf /usr/local/3proxy/logs'
    MSYS_NO_PATHCONV=1 docker cp \
        amnezia-client/client/server_scripts/socks5_proxy/configure_container.sh \
        "$SOURCE_CONTAINER:/opt/amnezia/configure_container.sh"
    MSYS_NO_PATHCONV=1 docker exec "$SOURCE_CONTAINER" sh -lc "sed -i 's/\r$//' /opt/amnezia/configure_container.sh"
    MSYS_NO_PATHCONV=1 docker exec \
        -e SOCKS5_USER="users ${PROXY_USER}:CL:${PROXY_PASSWORD}" \
        -e SOCKS5_AUTH_TYPE="strong" \
        -e SOCKS5_PROXY_PORT="$SOURCE_PORT" \
        "$SOURCE_CONTAINER" \
        sh /opt/amnezia/configure_container.sh >/dev/null

    pass "configured upstream Amnezia SOCKS5 source container"
}

externalize_source() {
    OBSCURA_ALLOW_NON_ROOT=1 bash scripts/externalize-amnezia-socks5proxy.sh \
        --container "$SOURCE_CONTAINER" \
        --data-dir "$EXTERNALIZED_DIR" \
        --force >/dev/null

    test -s "$EXTERNALIZED_DIR/conf/3proxy.cfg"
    pass "externalized upstream Amnezia SOCKS5 config"
}

start_target_container() {
    docker rm -f "$TARGET_CONTAINER" >/dev/null 2>&1 || true
    MSYS_NO_PATHCONV=1 docker run \
        -d \
        --name "$TARGET_CONTAINER" \
        --network "$NETWORK_NAME" \
        -e SOCKS5_COMPAT_CONFIG=/compat/3proxy.cfg \
        -e SOCKS5_DNS_SERVERS=1.1.1.1 \
        -v "$(host_path_for_docker "$EXTERNALIZED_DIR/conf"):/compat:ro" \
        obscura-socks5proxy >/dev/null

    sleep 3
    pass "started throwaway Obscura SOCKS5 compatibility target"
}

verify_target_config() {
    MSYS_NO_PATHCONV=1 docker exec "$TARGET_CONTAINER" sh -lc "
        grep -q '^users ${PROXY_USER}:CL:${PROXY_PASSWORD}' /usr/local/3proxy/conf/3proxy.cfg
        grep -q '^auth strong' /usr/local/3proxy/conf/3proxy.cfg
        grep -q '^socks .* -p1080 ' /usr/local/3proxy/conf/3proxy.cfg || grep -q '^socks -p1080 ' /usr/local/3proxy/conf/3proxy.cfg
        ! grep -q -- '-p${SOURCE_PORT}' /usr/local/3proxy/conf/3proxy.cfg
    "
    pass "Obscura imported SOCKS5 credentials while keeping internal port 1080"
}

print_summary() {
    log ""
    log "Summary:"
    log "  pass: $PASS_COUNT"
    log "  fail: $FAIL_COUNT"
    log "  skip: $SKIP_COUNT"

    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main() {
    trap cleanup EXIT

    parse_args "$@"
    require_cmd docker
    require_cmd bash

    prepare_workspace
    build_images
    prepare_network
    start_source_container
    externalize_source
    start_target_container
    verify_target_config
    print_summary
}

main "$@"
