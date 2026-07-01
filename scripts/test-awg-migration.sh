#!/usr/bin/env bash
set -euo pipefail

DEFAULT_SOURCE_IMAGE="obscura-e2e-amnezia-awg"
DEFAULT_SOURCE_CONTAINER="obscura-e2e-amnezia-awg"
DEFAULT_TARGET_CONTAINER="obscura-e2e-obscura-awg"
DEFAULT_CLIENT_CONTAINER="obscura-e2e-awg-client"
DEFAULT_NETWORK="obscura-awg-e2e"
DEFAULT_AWG_PORT="55424"
PYTHON_BIN="${PYTHON_BIN:-python3}"

SOURCE_IMAGE="$DEFAULT_SOURCE_IMAGE"
SOURCE_CONTAINER="$DEFAULT_SOURCE_CONTAINER"
TARGET_CONTAINER="$DEFAULT_TARGET_CONTAINER"
CLIENT_CONTAINER="$DEFAULT_CLIENT_CONTAINER"
NETWORK_NAME="$DEFAULT_NETWORK"
AWG_PORT="$DEFAULT_AWG_PORT"
WITH_TUNNEL=0
KEEP_ARTIFACTS=0

TMPDIR=""
EXTERNALIZED_DIR=""
IMPORTED_DIR=""
TARGET_STATE_VOLUME=""
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TUN_DEVICE_SOURCE="/dev/net/tun"

usage() {
    cat <<'EOF'
Usage: test-awg-migration.sh [options]

End-to-end AWG migration test using a real Amnezia AWG source container built
from the checked-out upstream amnezia-client submodule scripts.

The default test:
  1. builds an Amnezia AWG source image from upstream scripts
  2. configures a throwaway Amnezia-style AWG container
  3. externalizes its /opt/amnezia/awg state
  4. imports that state into Obscura format
  5. live-applies the import into a throwaway Obscura AWG target
  6. verifies target state, health, and imported peer count

Options:
  --with-tunnel              Also test real AWG client tunnel packet flow
  --keep-artifacts           Do not remove test containers/volumes/network/temp dirs
  --source-image <name>      Source Amnezia AWG image name
  --source-container <name>  Source container name
  --target-container <name>  Target Obscura AWG container name
  --client-container <name>  Optional tunnel client container name
  --network <name>           Test Docker network name
  --awg-port <port>          AWG listen port used in the fixture
  -h, --help                 Show this help
EOF
}

log() {
    printf '%s\n' "$*"
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS: %s\n' "$*"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL: %s\n' "$*" >&2
}

skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    printf 'SKIP: %s\n' "$*"
}

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

cleanup() {
    local exit_code=$?
    local old_container_ids

    if [ "$KEEP_ARTIFACTS" -eq 0 ]; then
        docker rm -f "$CLIENT_CONTAINER" "$TARGET_CONTAINER" "$SOURCE_CONTAINER" >/dev/null 2>&1 || true
        old_container_ids="$(docker ps -aq --filter "name=^/${SOURCE_CONTAINER}-old-" 2>/dev/null || true)"
        if [ -n "$old_container_ids" ]; then
            docker rm -f $old_container_ids >/dev/null 2>&1 || true
        fi
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
            --with-tunnel)
                WITH_TUNNEL=1
                shift
                ;;
            --keep-artifacts)
                KEEP_ARTIFACTS=1
                shift
                ;;
            --source-image)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --source-image\n' >&2; exit 1; }
                SOURCE_IMAGE="$2"
                shift 2
                ;;
            --source-container)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --source-container\n' >&2; exit 1; }
                SOURCE_CONTAINER="$2"
                shift 2
                ;;
            --target-container)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --target-container\n' >&2; exit 1; }
                TARGET_CONTAINER="$2"
                shift 2
                ;;
            --client-container)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --client-container\n' >&2; exit 1; }
                CLIENT_CONTAINER="$2"
                shift 2
                ;;
            --network)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --network\n' >&2; exit 1; }
                NETWORK_NAME="$2"
                shift 2
                ;;
            --awg-port)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --awg-port\n' >&2; exit 1; }
                AWG_PORT="$2"
                shift 2
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

prepare_workspace() {
    TMPDIR="$(mktemp -d)"
    EXTERNALIZED_DIR="$TMPDIR/externalized-awg"
    IMPORTED_DIR="$TMPDIR/imported-awg"
    TARGET_STATE_VOLUME="${TARGET_CONTAINER}-state"
    mkdir -p "$EXTERNALIZED_DIR" "$IMPORTED_DIR"

    case "$(uname -s 2>/dev/null || true)" in
        MINGW*|MSYS*|CYGWIN*)
            TUN_DEVICE_SOURCE="//dev/net/tun"
            ;;
    esac
}

build_images() {
    docker build \
        -t "$SOURCE_IMAGE" \
        amnezia-client/client/server_scripts/awg >/dev/null
    pass "built upstream Amnezia AWG source image"

    docker compose --profile awg build awg >/dev/null
    pass "built Obscura AWG image"
}

prepare_network() {
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
    docker network create "$NETWORK_NAME" >/dev/null
    pass "created E2E Docker network"
}

start_source_container() {
    docker rm -f "$SOURCE_CONTAINER" >/dev/null 2>&1 || true
    docker run \
        -d \
        --name "$SOURCE_CONTAINER" \
        --network "$NETWORK_NAME" \
        --privileged \
        --cap-add NET_ADMIN \
        --cap-add SYS_MODULE \
        --device "$TUN_DEVICE_SOURCE:/dev/net/tun" \
        "$SOURCE_IMAGE" >/dev/null

    MSYS_NO_PATHCONV=1 docker exec \
        -e AWG_SUBNET_IP=10.8.1.1 \
        -e WIREGUARD_SUBNET_CIDR=24 \
        -e AWG_SERVER_PORT="$AWG_PORT" \
        -e JUNK_PACKET_COUNT=3 \
        -e JUNK_PACKET_MIN_SIZE=10 \
        -e JUNK_PACKET_MAX_SIZE=30 \
        -e INIT_PACKET_JUNK_SIZE=15 \
        -e RESPONSE_PACKET_JUNK_SIZE=18 \
        -e COOKIE_REPLY_PACKET_JUNK_SIZE=20 \
        -e TRANSPORT_PACKET_JUNK_SIZE=23 \
        -e INIT_PACKET_MAGIC_HEADER=1020325451 \
        -e RESPONSE_PACKET_MAGIC_HEADER=3288052141 \
        -e UNDERLOAD_PACKET_MAGIC_HEADER=1766607858 \
        -e TRANSPORT_PACKET_MAGIC_HEADER=2528465083 \
        -e SPECIAL_JUNK_1='' \
        -e SPECIAL_JUNK_2='' \
        -e SPECIAL_JUNK_3='' \
        -e SPECIAL_JUNK_4='' \
        -e SPECIAL_JUNK_5='' \
        "$SOURCE_CONTAINER" \
        sh -lc 'bash /opt/amnezia/configure_container.sh' >/dev/null 2>&1 || {
            MSYS_NO_PATHCONV=1 docker cp amnezia-client/client/server_scripts/awg/configure_container.sh "$SOURCE_CONTAINER:/opt/amnezia/configure_container.sh"
            MSYS_NO_PATHCONV=1 docker exec "$SOURCE_CONTAINER" sh -lc "sed -i 's/\r$//' /opt/amnezia/configure_container.sh"
            MSYS_NO_PATHCONV=1 docker exec \
                -e AWG_SUBNET_IP=10.8.1.1 \
                -e WIREGUARD_SUBNET_CIDR=24 \
                -e AWG_SERVER_PORT="$AWG_PORT" \
                -e JUNK_PACKET_COUNT=3 \
                -e JUNK_PACKET_MIN_SIZE=10 \
                -e JUNK_PACKET_MAX_SIZE=30 \
                -e INIT_PACKET_JUNK_SIZE=15 \
                -e RESPONSE_PACKET_JUNK_SIZE=18 \
                -e COOKIE_REPLY_PACKET_JUNK_SIZE=20 \
                -e TRANSPORT_PACKET_JUNK_SIZE=23 \
                -e INIT_PACKET_MAGIC_HEADER=1020325451 \
                -e RESPONSE_PACKET_MAGIC_HEADER=3288052141 \
                -e UNDERLOAD_PACKET_MAGIC_HEADER=1766607858 \
                -e TRANSPORT_PACKET_MAGIC_HEADER=2528465083 \
                -e SPECIAL_JUNK_1='' \
                -e SPECIAL_JUNK_2='' \
                -e SPECIAL_JUNK_3='' \
                -e SPECIAL_JUNK_4='' \
                -e SPECIAL_JUNK_5='' \
                "$SOURCE_CONTAINER" \
                bash /opt/amnezia/configure_container.sh >/dev/null
        }

    MSYS_NO_PATHCONV=1 docker exec "$SOURCE_CONTAINER" sh -lc '
        peer_private="$(awg genkey)"
        peer_public="$(printf "%s\n" "$peer_private" | awg pubkey)"
        peer_psk="$(awg genpsk)"
        {
            printf "\n[Peer]\n"
            printf "PublicKey = %s\n" "$peer_public"
            printf "PresharedKey = %s\n" "$peer_psk"
            printf "AllowedIPs = 10.8.1.2/32\n"
            printf "PersistentKeepalive = 25\n"
        } >> /opt/amnezia/awg/awg0.conf
    '

    pass "configured upstream Amnezia AWG source container"
}

externalize_source() {
    OBSCURA_ALLOW_NON_ROOT=1 PYTHON_BIN="$PYTHON_BIN" bash scripts/externalize-amnezia-awg.sh \
        --container "$SOURCE_CONTAINER" \
        --data-dir "$EXTERNALIZED_DIR" \
        --force >/dev/null

    test -s "$EXTERNALIZED_DIR/awg0.conf"
    pass "externalized upstream Amnezia AWG state"
}

import_state() {
    PYTHON_BIN="$PYTHON_BIN" bash scripts/import-amnezia-awg.sh \
        --source-dir "$EXTERNALIZED_DIR" \
        --state-dir "$IMPORTED_DIR" \
        --force >/dev/null

    "$PYTHON_BIN" - "$IMPORTED_DIR/import-metadata.json" <<'PY'
import json
import sys
metadata = json.load(open(sys.argv[1], encoding="utf-8"))
if metadata.get("client_count") != 1:
    raise SystemExit(f"expected exactly one imported client, got {metadata.get('client_count')}")
PY
    pass "imported externalized AWG state into Obscura format"
}

start_target_container() {
    docker rm -f "$TARGET_CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "$TARGET_STATE_VOLUME" >/dev/null 2>&1 || true
    docker volume create "$TARGET_STATE_VOLUME" >/dev/null

    docker run \
        -d \
        --name "$TARGET_CONTAINER" \
        --network "$NETWORK_NAME" \
        --cap-add NET_ADMIN \
        --device "$TUN_DEVICE_SOURCE:/dev/net/tun" \
        -e AWG_LISTEN_PORT="$AWG_PORT" \
        -e AWG_PUBLISHED_PORT="$AWG_PORT" \
        -v "$TARGET_STATE_VOLUME:/var/lib/obscura/awg" \
        obscura-awg >/dev/null

    sleep 3
    pass "started throwaway Obscura AWG target container"
}

apply_import_live() {
    PYTHON_BIN="$PYTHON_BIN" bash scripts/import-amnezia-awg.sh \
        --source-dir "$IMPORTED_DIR" \
        --state-dir "$TMPDIR/reimported-awg" \
        --target-container "$TARGET_CONTAINER" \
        --apply-live \
        --force >/dev/null

    MSYS_NO_PATHCONV=1 docker exec "$TARGET_CONTAINER" sh -lc 'test "$(awg show awg0 peers | wc -l | tr -d "[:space:]")" = "1"'
    pass "live-applied imported AWG state and verified imported peer count"
}

verify_imported_peer_is_not_exportable() {
    if PYTHON_BIN="$PYTHON_BIN" bash scripts/manage-awg-clients.sh export \
        --container "$TARGET_CONTAINER" \
        --name imported-1 \
        --server-host 127.0.0.1 \
        --output "$TMPDIR/imported-client.conf" >/dev/null 2>&1; then
        fail "imported peer without private key was exportable"
    else
        pass "imported peer without private key is not exportable"
    fi
}

run_optional_tunnel_test() {
    local target_ip

    if [ "$WITH_TUNNEL" -eq 0 ]; then
        skip "optional AWG tunnel traffic test not requested"
        return
    fi

    if ! docker run --rm --cap-add NET_ADMIN --device "$TUN_DEVICE_SOURCE:/dev/net/tun" alpine:3.20 sh -lc 'test -e /dev/net/tun' >/dev/null 2>&1; then
        skip "optional AWG tunnel traffic test skipped because /dev/net/tun is unavailable"
        return
    fi

    target_ip="$(docker inspect -f "{{range .NetworkSettings.Networks}}{{if eq .NetworkID \"$(docker network inspect -f '{{.ID}}' "$NETWORK_NAME")\"}}{{.IPAddress}}{{end}}{{end}}" "$TARGET_CONTAINER")"
    if [ -z "$target_ip" ]; then
        target_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$TARGET_CONTAINER" | head -n 1)"
    fi
    if [ -z "$target_ip" ]; then
        skip "optional AWG tunnel traffic test skipped because target container IP could not be determined"
        return
    fi

    PYTHON_BIN="$PYTHON_BIN" bash scripts/manage-awg-clients.sh add --container "$TARGET_CONTAINER" --name e2e-tunnel-client >/dev/null
    PYTHON_BIN="$PYTHON_BIN" bash scripts/manage-awg-clients.sh export --container "$TARGET_CONTAINER" --name e2e-tunnel-client --server-host "$target_ip" --output "$TMPDIR/e2e-client.conf" >/dev/null
    sed -i '/^[[:space:]]*DNS[[:space:]]*=/d' "$TMPDIR/e2e-client.conf"
    sed -i 's|^[[:space:]]*AllowedIPs[[:space:]]*=.*|AllowedIPs = 10.8.1.1/32|' "$TMPDIR/e2e-client.conf"

    docker rm -f "$CLIENT_CONTAINER" >/dev/null 2>&1 || true
    docker run \
        -d \
        --name "$CLIENT_CONTAINER" \
        --network "$NETWORK_NAME" \
        --cap-add NET_ADMIN \
        --device "$TUN_DEVICE_SOURCE:/dev/net/tun" \
        --entrypoint sleep \
        obscura-awg \
        3600 >/dev/null

    MSYS_NO_PATHCONV=1 docker cp "$(host_path_for_docker "$TMPDIR/e2e-client.conf")" "$CLIENT_CONTAINER:/tmp/e2e-client.conf"
    MSYS_NO_PATHCONV=1 docker exec "$CLIENT_CONTAINER" chmod 0600 /tmp/e2e-client.conf

    MSYS_NO_PATHCONV=1 docker exec "$CLIENT_CONTAINER" sh -lc '
        apk add --no-cache iputils >/dev/null 2>&1 || true
        awg-quick down /tmp/e2e-client.conf >/dev/null 2>&1 || true
        awg-quick up /tmp/e2e-client.conf >/dev/null
        ping -c 1 -W 5 10.8.1.1 >/dev/null
    '

    PYTHON_BIN="$PYTHON_BIN" bash scripts/manage-awg-clients.sh remove --container "$TARGET_CONTAINER" --name e2e-tunnel-client >/dev/null
    pass "optional AWG tunnel traffic test passed"
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
    verify_imported_peer_is_not_exportable
    run_optional_tunnel_test
    print_summary
}

main "$@"
