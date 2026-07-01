#!/usr/bin/env bash
set -euo pipefail

DEFAULT_SERVICE_LABEL="com.docker.compose.service=awg"
DEFAULT_PROJECT_LABEL="com.docker.compose.project=obscura"
DEFAULT_CONTAINER_NUMBER_LABEL="com.docker.compose.container-number=1"
DEFAULT_SERVER_HOST="127.0.0.1"
DEFAULT_TEST_CLIENT_NAME="obscura-awg-host-test"
PYTHON_BIN="${PYTHON_BIN:-python3}"

CONTAINER_NAME=""
SERVER_HOST="$DEFAULT_SERVER_HOST"
TEST_CLIENT_NAME="$DEFAULT_TEST_CLIENT_NAME"
SKIP_CLIENT_CYCLE=0

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TMPDIR=""

usage() {
    cat <<'EOF'
Usage: test-awg-host.sh [options]

Host-side validation for the running Obscura AWG service.

The script checks runtime health, generated state, live interface/listen status,
and by default runs a client add/export/remove cycle without printing secrets.

Options:
  --container <name>          Explicit container name
  --server-host <host>        Server address used for temporary export
  --client-name <name>        Temporary test client name
  --skip-client-cycle         Only run runtime/status checks
  -h, --help                  Show this help

Examples:
  sudo bash scripts/test-awg-host.sh
  sudo bash scripts/test-awg-host.sh --container obscura-awg-1
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

    if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
        rm -rf "$TMPDIR"
    fi

    exit "$exit_code"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --container)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --container\n' >&2; exit 1; }
                CONTAINER_NAME="$2"
                shift 2
                ;;
            --server-host)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --server-host\n' >&2; exit 1; }
                SERVER_HOST="$2"
                shift 2
                ;;
            --client-name)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --client-name\n' >&2; exit 1; }
                TEST_CLIENT_NAME="$2"
                shift 2
                ;;
            --skip-client-cycle)
                SKIP_CLIENT_CYCLE=1
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

    CONTAINER_NAME="$(
        docker ps \
            --filter "label=$DEFAULT_PROJECT_LABEL" \
            --filter "label=$DEFAULT_SERVICE_LABEL" \
            --filter "label=$DEFAULT_CONTAINER_NUMBER_LABEL" \
            --format '{{.Names}}' \
            | head -n 1
    )"

    if [ -z "$CONTAINER_NAME" ]; then
        printf 'ERROR: no running awg container found\n' >&2
        exit 1
    fi
}

require_healthy_server() {
    local state
    local health

    state="$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")"
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME")"

    if [ "$state" = "running" ]; then
        pass "AWG container is running"
    else
        fail "AWG container is not running (state=$state)"
        return
    fi

    if [ "$health" = "healthy" ] || [ "$health" = "none" ]; then
        pass "AWG container health is acceptable ($health)"
    else
        fail "AWG container is not healthy (health=$health)"
    fi
}

check_runtime_state() {
    if docker exec "$CONTAINER_NAME" sh -lc '
        set -eu
        test -s /opt/amnezia/awg/awg0.conf
        test -s /opt/amnezia/awg/clients.json
        test -s /opt/amnezia/awg/settings.json
        test -s /opt/amnezia/awg/wireguard_server_public_key.key
        interface="$(python3 -c "import json; print(json.load(open(\"/opt/amnezia/awg/settings.json\", encoding=\"utf-8\")).get(\"interface\", \"awg0\"))")"
        ip link show dev "$interface" >/dev/null
        awg show "$interface" listen-port >/dev/null
    '; then
        pass "AWG generated state and interface are present"
    else
        fail "AWG generated state or interface check failed"
    fi
}

check_peer_count_consistency() {
    if docker exec "$CONTAINER_NAME" sh -lc '
        set -eu
        expected="$(python3 -c "import json; clients=json.load(open(\"/opt/amnezia/awg/clients.json\", encoding=\"utf-8\")); print(sum(1 for c in clients if c.get(\"enabled\", True) is not False and (c.get(\"public_key\") or \"\").strip() and (c.get(\"allowed_ips\") or c.get(\"address\") or \"\").strip()))")"
        interface="$(python3 -c "import json; print(json.load(open(\"/opt/amnezia/awg/settings.json\", encoding=\"utf-8\")).get(\"interface\", \"awg0\"))")"
        actual="$(awg show "$interface" peers | wc -l | tr -d "[:space:]")"
        test "$actual" = "$expected"
    '; then
        pass "AWG live peer count matches enabled registry peers"
    else
        fail "AWG live peer count does not match enabled registry peers"
    fi
}

run_client_cycle() {
    TMPDIR="$(mktemp -d)"

    if PYTHON_BIN="$PYTHON_BIN" bash scripts/manage-awg-clients.sh add --container "$CONTAINER_NAME" --name "$TEST_CLIENT_NAME"; then
        pass "AWG helper added temporary client"
    else
        fail "AWG helper failed to add temporary client"
        return
    fi

    if PYTHON_BIN="$PYTHON_BIN" bash scripts/manage-awg-clients.sh export --container "$CONTAINER_NAME" --name "$TEST_CLIENT_NAME" --server-host "$SERVER_HOST" --output "$TMPDIR/client.conf" \
        && test -s "$TMPDIR/client.conf" \
        && ! grep -q '__AWG_' "$TMPDIR/client.conf" \
        && grep -q "Endpoint = $SERVER_HOST:" "$TMPDIR/client.conf"; then
        pass "AWG helper exported temporary client config without unresolved placeholders"
    else
        fail "AWG helper failed to export valid temporary client config"
    fi

    if PYTHON_BIN="$PYTHON_BIN" bash scripts/manage-awg-clients.sh remove --container "$CONTAINER_NAME" --name "$TEST_CLIENT_NAME"; then
        pass "AWG helper removed temporary client"
    else
        fail "AWG helper failed to remove temporary client"
    fi

    check_peer_count_consistency
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
    require_cmd "$PYTHON_BIN"
    require_cmd bash

    discover_container
    log "Discovered AWG container: $CONTAINER_NAME"
    require_healthy_server
    check_runtime_state
    check_peer_count_consistency

    if [ "$SKIP_CLIENT_CYCLE" -eq 1 ]; then
        skip "temporary client add/export/remove cycle skipped"
    else
        run_client_cycle
    fi

    print_summary
}

main "$@"
