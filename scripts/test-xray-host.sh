#!/usr/bin/env bash
set -euo pipefail

DEFAULT_SERVICE_LABEL="com.docker.compose.service=xray"
DEFAULT_PROJECT_LABEL="com.docker.compose.project=obscura"
DEFAULT_CONTAINER_NUMBER_LABEL="com.docker.compose.container-number=1"
DEFAULT_TEST_URL="http://example.com/"
DEFAULT_EXPECTED_TEXT="Example Domain"
DEFAULT_SERVER_HOST="127.0.0.1"
DEFAULT_LOCAL_SOCKS_PORT="10808"
DEFAULT_CLIENT_CONTAINER_NAME="obscura-xray-host-test"

CONTAINER_NAME=""
TEST_URL="$DEFAULT_TEST_URL"
EXPECTED_TEXT="$DEFAULT_EXPECTED_TEXT"
SERVER_HOST="$DEFAULT_SERVER_HOST"
LOCAL_SOCKS_PORT="$DEFAULT_LOCAL_SOCKS_PORT"
CLIENT_CONTAINER_NAME="$DEFAULT_CLIENT_CONTAINER_NAME"
TIMEOUT="${XRAY_TEST_TIMEOUT:-20}"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

TMPDIR=""
SERVER_PORT=""
CLIENT_ID=""
CLIENT_FLOW=""
PUBLIC_KEY=""
SHORT_ID=""
SITE_NAME=""
RENDERED_CLIENT_CONFIG=""

usage() {
    cat <<'EOF'
Usage: test-xray-host.sh [options]

Host-side validation for the running Obscura Xray service.

The script discovers the running xray container via Docker, extracts the live
bootstrap client parameters, renders a temporary Xray client config, starts a
short-lived Xray client container on host networking, and verifies HTTP data
flow to a known web site through the local SOCKS listener.

Options:
  --container <name>           Explicit container name
  --server-host <host>         Server address for the temporary client
  --local-socks-port <port>    Local SOCKS port for the temporary client
  --test-url <url>             URL to fetch through the Xray client
  --expected-text <text>       Text expected in the HTTP response body
  -h, --help                   Show this help

Examples:
  sudo bash scripts/test-xray-host.sh
  sudo bash scripts/test-xray-host.sh --container obscura-xray-1
  sudo bash scripts/test-xray-host.sh --test-url http://example.com/
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

cleanup() {
    local exit_code=$?

    docker rm -f "$CLIENT_CONTAINER_NAME" >/dev/null 2>&1 || true

    if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
        rm -rf "$TMPDIR"
    fi

    exit "$exit_code"
}

parse_args() {
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
            --server-host)
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --server-host\n' >&2
                    exit 1
                }
                SERVER_HOST="$2"
                shift 2
                ;;
            --local-socks-port)
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --local-socks-port\n' >&2
                    exit 1
                }
                LOCAL_SOCKS_PORT="$2"
                shift 2
                ;;
            --test-url)
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --test-url\n' >&2
                    exit 1
                }
                TEST_URL="$2"
                shift 2
                ;;
            --expected-text)
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --expected-text\n' >&2
                    exit 1
                }
                EXPECTED_TEXT="$2"
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

validate_numeric_port() {
    case "$1" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

discover_container() {
    if [ -n "$CONTAINER_NAME" ]; then
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
        printf 'ERROR: no running xray container found\n' >&2
        exit 1
    fi
}

require_healthy_server() {
    local state
    local health

    state="$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")"
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME")"

    if [ "$state" != "running" ]; then
        printf 'ERROR: container %s is not running (state=%s)\n' "$CONTAINER_NAME" "$state" >&2
        exit 1
    fi

    if [ "$health" != "healthy" ]; then
        printf 'ERROR: container %s is not healthy (health=%s)\n' "$CONTAINER_NAME" "$health" >&2
        exit 1
    fi
}

discover_server_port() {
    local port_lines

    port_lines="$(docker port "$CONTAINER_NAME" 443/tcp 2>/dev/null || true)"
    if [ -z "$port_lines" ]; then
        port_lines="$(docker port "$CONTAINER_NAME" 2>/dev/null || true)"
    fi

    SERVER_PORT="$(printf '%s\n' "$port_lines" | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -n 1)"
    if ! validate_numeric_port "$SERVER_PORT"; then
        printf 'ERROR: could not determine published Xray port for %s\n' "$CONTAINER_NAME" >&2
        exit 1
    fi
}

read_live_state() {
    CLIENT_ID="$(
        docker exec "$CONTAINER_NAME" sh -lc \
            "sed -n 's/.*\"id\":[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' /var/lib/obscura/xray/clients.json | head -n 1"
    )"

    CLIENT_FLOW="$(
        docker exec "$CONTAINER_NAME" sh -lc \
            "sed -n 's/.*\"flow\":[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' /var/lib/obscura/xray/clients.json | head -n 1"
    )"

    PUBLIC_KEY="$(docker exec "$CONTAINER_NAME" sh -lc 'cat /var/lib/obscura/xray/xray_public.key')"
    SHORT_ID="$(docker exec "$CONTAINER_NAME" sh -lc 'cat /var/lib/obscura/xray/xray_short_id.key')"
    SITE_NAME="$(
        docker exec "$CONTAINER_NAME" sh -lc \
            "awk '/\"serverNames\"[[:space:]]*:/ {getline; if (match(\$0, /\"[^\"]+\"/)) { value = substr(\$0, RSTART + 1, RLENGTH - 2); print value; exit }}' /var/lib/obscura/xray/server.json"
    )"

    if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_FLOW" ] || [ -z "$PUBLIC_KEY" ] || [ -z "$SHORT_ID" ] || [ -z "$SITE_NAME" ]; then
        printf 'ERROR: failed to extract required live Xray state from %s\n' "$CONTAINER_NAME" >&2
        exit 1
    fi
}

render_client_config() {
    TMPDIR="$(mktemp -d)"
    RENDERED_CLIENT_CONFIG="$TMPDIR/xray-client.json"

    docker exec "$CONTAINER_NAME" sh -lc 'cat /var/lib/obscura/xray/client.template.json' \
        >"$TMPDIR/client.template.json"

    sed \
        -e "s|\\\$SERVER_IP_ADDRESS|$SERVER_HOST|g" \
        -e "s|\\\$XRAY_SERVER_PORT|$SERVER_PORT|g" \
        -e "s|\\\$XRAY_CLIENT_ID|$CLIENT_ID|g" \
        -e "s|\\\$XRAY_SITE_NAME|$SITE_NAME|g" \
        -e "s|\\\$XRAY_PUBLIC_KEY|$PUBLIC_KEY|g" \
        -e "s|\\\$XRAY_SHORT_ID|$SHORT_ID|g" \
        "$TMPDIR/client.template.json" >"$RENDERED_CLIENT_CONFIG"

    sed -i "0,/\"port\": 10808,/s//\"port\": $LOCAL_SOCKS_PORT,/" "$RENDERED_CLIENT_CONFIG"
}

wait_for_local_socks() {
    local attempt

    for attempt in $(seq 1 "$TIMEOUT"); do
        if docker exec "$CLIENT_CONTAINER_NAME" sh -lc \
            "awk 'NR > 1 { split(\$2, local, \":\"); if (toupper(local[2]) == toupper(sprintf(\"%04X\", $LOCAL_SOCKS_PORT)) && \$4 == \"0A\") { found = 1 } } END { exit(found ? 0 : 1) }' /proc/net/tcp /proc/net/tcp6"; then
            return 0
        fi

        if ! verify_temp_client_running; then
            return 1
        fi

        sleep 1
    done

    return 1
}

start_temp_client() {
    docker rm -f "$CLIENT_CONTAINER_NAME" >/dev/null 2>&1 || true

    docker run \
        --rm \
        --detach \
        --name "$CLIENT_CONTAINER_NAME" \
        --network host \
        --entrypoint xray \
        -v "$RENDERED_CLIENT_CONFIG:/tmp/xray-client.json:ro" \
        obscura-xray \
        run -config /tmp/xray-client.json >/dev/null
}

verify_temp_client_running() {
    local state

    state="$(docker inspect --format '{{.State.Status}}' "$CLIENT_CONTAINER_NAME" 2>/dev/null || true)"
    [ "$state" = "running" ]
}

run_http_probe() {
    local response_file
    local error_file

    response_file="$TMPDIR/response.txt"
    error_file="$TMPDIR/curl.stderr"

    if docker exec \
        -e TEST_URL="$TEST_URL" \
        -e TEST_TIMEOUT="$TIMEOUT" \
        -e XRAY_TEST_LOCAL_SOCKS_PORT="$LOCAL_SOCKS_PORT" \
        "$CLIENT_CONTAINER_NAME" \
        sh -lc '
            if ! command -v curl >/dev/null 2>&1; then
                apk add --no-cache curl ca-certificates >/dev/null 2>&1
            fi
            update-ca-certificates >/dev/null 2>&1 || true
            curl \
                --silent \
                --show-error \
                --fail \
                --location \
                --max-time "$TEST_TIMEOUT" \
                --socks5-hostname "127.0.0.1:$XRAY_TEST_LOCAL_SOCKS_PORT" \
                "$TEST_URL"
        ' >"$response_file" 2>"$error_file"; then
        if grep -Fq "$EXPECTED_TEXT" "$response_file"; then
            pass "HTTP over Xray reached $TEST_URL and matched expected response text"
        else
            fail "HTTP over Xray reached $TEST_URL but expected text was not found"
            printf '%s\n' '--- response ---' >&2
            sed -n '1,80p' "$response_file" >&2
        fi
    else
        fail "HTTP over Xray failed for $TEST_URL"
        sed -n '1,120p' "$error_file" >&2
    fi
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

    if ! validate_numeric_port "$LOCAL_SOCKS_PORT"; then
        printf 'ERROR: invalid --local-socks-port value: %s\n' "$LOCAL_SOCKS_PORT" >&2
        exit 1
    fi

    discover_container
    require_healthy_server
    discover_server_port
    read_live_state

    log "Discovered Xray container: $CONTAINER_NAME"
    log "Published Xray server port: $SERVER_PORT"
    log "Temporary client server host: $SERVER_HOST"
    log "Temporary local SOCKS port: $LOCAL_SOCKS_PORT"
    log "Bootstrap client id: $CLIENT_ID"
    log "Bootstrap client flow: $CLIENT_FLOW"
    log "Reality site name: $SITE_NAME"

    render_client_config
    start_temp_client

    if verify_temp_client_running; then
        pass "temporary Xray client container started"
    else
        fail "temporary Xray client container failed to start"
        docker logs "$CLIENT_CONTAINER_NAME" >&2 || true
        print_summary
    fi

    if wait_for_local_socks; then
        pass "temporary local SOCKS listener is ready on port $LOCAL_SOCKS_PORT"
    else
        fail "temporary local SOCKS listener did not become ready on port $LOCAL_SOCKS_PORT"
        docker logs "$CLIENT_CONTAINER_NAME" >&2 || true
        print_summary
    fi

    run_http_probe
    print_summary
}

main "$@"
