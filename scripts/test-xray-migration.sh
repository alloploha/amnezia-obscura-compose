#!/usr/bin/env bash
set -euo pipefail

DEFAULT_SOURCE_IMAGE="obscura-e2e-amnezia-xray"
DEFAULT_SOURCE_CONTAINER="obscura-e2e-amnezia-xray"
DEFAULT_TARGET_CONTAINER="obscura-e2e-obscura-xray"
DEFAULT_CLIENT_CONTAINER="obscura-e2e-xray-client"
DEFAULT_NETWORK="obscura-xray-e2e"
DEFAULT_XRAY_PORT="18443"
DEFAULT_SITE_NAME="www.googletagmanager.com"
DEFAULT_LOCAL_SOCKS_PORT="10808"
PYTHON_BIN="${PYTHON_BIN:-python3}"

SOURCE_IMAGE="$DEFAULT_SOURCE_IMAGE"
SOURCE_CONTAINER="$DEFAULT_SOURCE_CONTAINER"
TARGET_CONTAINER="$DEFAULT_TARGET_CONTAINER"
CLIENT_CONTAINER="$DEFAULT_CLIENT_CONTAINER"
NETWORK_NAME="$DEFAULT_NETWORK"
XRAY_PORT="$DEFAULT_XRAY_PORT"
SITE_NAME="$DEFAULT_SITE_NAME"
LOCAL_SOCKS_PORT="$DEFAULT_LOCAL_SOCKS_PORT"
WITH_FLOW=0
KEEP_ARTIFACTS=0

TMPDIR=""
EXTERNALIZED_DIR=""
IMPORTED_DIR=""
TARGET_STATE_VOLUME=""
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

usage() {
    cat <<'EOF'
Usage: test-xray-migration.sh [options]

End-to-end Xray migration test using a real Amnezia Xray source container built
from the checked-out upstream amnezia-client submodule scripts.

Options:
  --with-flow                Also test HTTP flow through an exported Xray client
  --keep-artifacts           Do not remove test containers/volumes/network/temp dirs
  --source-image <name>      Source Amnezia Xray image name
  --source-container <name>  Source container name
  --target-container <name>  Target Obscura Xray container name
  --client-container <name>  Optional flow client container name
  --network <name>           Test Docker network name
  --xray-port <port>         Xray listen/published port used in the fixture
  --site-name <name>         Reality site name used in the fixture
  -h, --help                 Show this help
EOF
}

log() { printf '%s\n' "$*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS: %s\n' "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL: %s\n' "$*" >&2; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); printf 'SKIP: %s\n' "$*"; }

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
        docker rm -f "$CLIENT_CONTAINER" "$TARGET_CONTAINER" "$SOURCE_CONTAINER" >/dev/null 2>&1 || true
        cleanup_old_source_backups
        if [ -n "$TARGET_STATE_VOLUME" ]; then
            docker volume rm "$TARGET_STATE_VOLUME" >/dev/null 2>&1 || true
        fi
        docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
        if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
            rm -rf "$TMPDIR"
        fi
    else
        log "Keeping E2E artifacts:"
        log "  temp dir: $TMPDIR"
        log "  network: $NETWORK_NAME"
        log "  source container: $SOURCE_CONTAINER"
        log "  target container: $TARGET_CONTAINER"
        log "  target volume: $TARGET_STATE_VOLUME"
    fi

    exit "$exit_code"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --with-flow) WITH_FLOW=1; shift ;;
            --keep-artifacts) KEEP_ARTIFACTS=1; shift ;;
            --source-image) SOURCE_IMAGE="$2"; shift 2 ;;
            --source-container) SOURCE_CONTAINER="$2"; shift 2 ;;
            --target-container) TARGET_CONTAINER="$2"; shift 2 ;;
            --client-container) CLIENT_CONTAINER="$2"; shift 2 ;;
            --network) NETWORK_NAME="$2"; shift 2 ;;
            --xray-port) XRAY_PORT="$2"; shift 2 ;;
            --site-name) SITE_NAME="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage; exit 1 ;;
        esac
    done
}

prepare_workspace() {
    TMPDIR="$(mktemp -d)"
    EXTERNALIZED_DIR="$TMPDIR/externalized-xray"
    IMPORTED_DIR="$TMPDIR/imported-xray"
    TARGET_STATE_VOLUME="${TARGET_CONTAINER}-state"
    mkdir -p "$EXTERNALIZED_DIR" "$IMPORTED_DIR"
}

build_images() {
    docker build -t "$SOURCE_IMAGE" amnezia-client/client/server_scripts/xray >/dev/null
    pass "built upstream Amnezia Xray source image"

    docker compose --profile xray build xray >/dev/null
    pass "built Obscura Xray image"
}

prepare_network() {
    docker rm -f "$CLIENT_CONTAINER" "$TARGET_CONTAINER" "$SOURCE_CONTAINER" >/dev/null 2>&1 || true
    cleanup_old_source_backups
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
    docker network create "$NETWORK_NAME" >/dev/null
    pass "created E2E Docker network"
}

start_source_container() {
    docker rm -f "$SOURCE_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$SOURCE_CONTAINER" --network "$NETWORK_NAME" "$SOURCE_IMAGE" >/dev/null

    MSYS_NO_PATHCONV=1 docker cp \
        amnezia-client/client/server_scripts/xray/configure_container.sh \
        "$SOURCE_CONTAINER:/opt/amnezia/configure_container.sh"
    MSYS_NO_PATHCONV=1 docker exec "$SOURCE_CONTAINER" sh -lc "sed -i 's/\r$//' /opt/amnezia/configure_container.sh"
    MSYS_NO_PATHCONV=1 docker exec \
        -e XRAY_SERVER_PORT="$XRAY_PORT" \
        -e XRAY_SITE_NAME="$SITE_NAME" \
        "$SOURCE_CONTAINER" \
        bash /opt/amnezia/configure_container.sh >/dev/null

    MSYS_NO_PATHCONV=1 docker cp "$SOURCE_CONTAINER:/opt/amnezia/xray/server.json" "$(host_path_for_docker "$TMPDIR/source-server.json")"
    "$PYTHON_BIN" - "$TMPDIR/source-server.json" <<'PY'
import json
import sys
import uuid

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    server = json.load(fh)
clients = server["inbounds"][0]["settings"]["clients"]
clients.append({"id": str(uuid.uuid4()), "flow": "xtls-rprx-vision"})
with open(path, "w", encoding="utf-8") as fh:
    json.dump(server, fh, indent=4)
    fh.write("\n")
PY
    MSYS_NO_PATHCONV=1 docker cp "$(host_path_for_docker "$TMPDIR/source-server.json")" "$SOURCE_CONTAINER:/opt/amnezia/xray/server.json"

    pass "configured upstream Amnezia Xray source container with extra client"
}

externalize_source() {
    OBSCURA_ALLOW_NON_ROOT=1 bash scripts/externalize-amnezia-xray.sh \
        --container "$SOURCE_CONTAINER" \
        --data-dir "$EXTERNALIZED_DIR" \
        --force >/dev/null

    test -s "$EXTERNALIZED_DIR/server.json"
    pass "externalized upstream Amnezia Xray state"
}

import_state() {
    bash scripts/import-amnezia-xray.sh \
        --source-dir "$EXTERNALIZED_DIR" \
        --state-dir "$IMPORTED_DIR" \
        --force >/dev/null

    "$PYTHON_BIN" - "$IMPORTED_DIR/import-metadata.json" <<'PY'
import json
import sys
metadata = json.load(open(sys.argv[1], encoding="utf-8"))
if metadata.get("client_count") != 2:
    raise SystemExit(f"expected exactly two imported clients, got {metadata.get('client_count')}")
PY
    pass "imported externalized Xray state into Obscura format"
}

start_target_container() {
    docker rm -f "$TARGET_CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "$TARGET_STATE_VOLUME" >/dev/null 2>&1 || true
    docker volume create "$TARGET_STATE_VOLUME" >/dev/null

    docker run \
        -d \
        --name "$TARGET_CONTAINER" \
        --network "$NETWORK_NAME" \
        -e XRAY_LISTEN_PORT="$XRAY_PORT" \
        -e XRAY_PUBLISHED_PORT="$XRAY_PORT" \
        -e XRAY_SITE_NAME="$SITE_NAME" \
        -v "$TARGET_STATE_VOLUME:/var/lib/obscura/xray" \
        obscura-xray >/dev/null

    sleep 3
    pass "started throwaway Obscura Xray target container"
}

apply_import_live() {
    bash scripts/import-amnezia-xray.sh \
        --source-dir "$IMPORTED_DIR" \
        --state-dir "$TMPDIR/reimported-xray" \
        --target-container "$TARGET_CONTAINER" \
        --apply-live \
        --force >/dev/null

    MSYS_NO_PATHCONV=1 docker exec "$TARGET_CONTAINER" sh -lc \
        "test \"\$(grep -c '\"id\"[[:space:]]*:' /opt/amnezia/xray/clients.json)\" = \"2\""
    pass "live-applied imported Xray state and verified imported client count"
}

run_optional_flow_test() {
    local target_ip
    local bootstrap_id

    if [ "$WITH_FLOW" -eq 0 ]; then
        skip "optional Xray flow test not requested"
        return
    fi

    target_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$TARGET_CONTAINER" | head -n 1)"
    if [ -z "$target_ip" ]; then
        skip "optional Xray flow test skipped because target container IP could not be determined"
        return
    fi

    bootstrap_id="$(docker exec "$TARGET_CONTAINER" sh -lc 'cat /opt/amnezia/xray/xray_uuid.key')"
    bash scripts/manage-xray-clients.sh export \
        --container "$TARGET_CONTAINER" \
        --client-id "$bootstrap_id" \
        --server-host "$target_ip" \
        --local-socks-port "$LOCAL_SOCKS_PORT" \
        --output "$TMPDIR/xray-client.json" >/dev/null

    docker rm -f "$CLIENT_CONTAINER" >/dev/null 2>&1 || true
    MSYS_NO_PATHCONV=1 docker run \
        -d \
        --name "$CLIENT_CONTAINER" \
        --network "$NETWORK_NAME" \
        --entrypoint xray \
        -v "$(host_path_for_docker "$TMPDIR/xray-client.json"):/tmp/xray-client.json:ro" \
        obscura-xray \
        run -config /tmp/xray-client.json >/dev/null

    for _ in $(seq 1 20); do
        if MSYS_NO_PATHCONV=1 docker exec "$CLIENT_CONTAINER" sh -lc \
            "awk 'NR > 1 { split(\$2, local, \":\"); if (toupper(local[2]) == toupper(sprintf(\"%04X\", $LOCAL_SOCKS_PORT)) && \$4 == \"0A\") { found = 1 } } END { exit(found ? 0 : 1) }' /proc/net/tcp /proc/net/tcp6"; then
            break
        fi
        sleep 1
    done

    MSYS_NO_PATHCONV=1 docker exec \
        -e XRAY_TEST_LOCAL_SOCKS_PORT="$LOCAL_SOCKS_PORT" \
        "$CLIENT_CONTAINER" \
        sh -lc '
            apk add --no-cache curl ca-certificates >/dev/null 2>&1 || true
            curl --silent --show-error --fail --max-time 20 \
                --socks5-hostname "127.0.0.1:$XRAY_TEST_LOCAL_SOCKS_PORT" \
                http://example.com/ | grep -q "Example Domain"
        '

    pass "optional Xray client flow test passed"
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
    require_cmd "$PYTHON_BIN"

    prepare_workspace
    build_images
    prepare_network
    start_source_container
    externalize_source
    import_state
    start_target_container
    apply_import_live
    run_optional_flow_test
    print_summary
}

main "$@"
