#!/usr/bin/env bash
set -euo pipefail

DEFAULT_CONTAINER="obscura-e2e-dns"
DEFAULT_HELPER="obscura-e2e-dns-helper"
DEFAULT_NETWORK="obscura-dns-e2e"
DEFAULT_IPV4_SUBNET="172.30.153.0/26"
DEFAULT_DNS_IPV4="172.30.153.53"

CONTAINER_NAME="$DEFAULT_CONTAINER"
HELPER_NAME="$DEFAULT_HELPER"
NETWORK_NAME="$DEFAULT_NETWORK"
IPV4_SUBNET="$DEFAULT_IPV4_SUBNET"
DNS_IPV4="$DEFAULT_DNS_IPV4"
KEEP_ARTIFACTS=0
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

usage() {
    cat <<'EOF'
Usage: test-dns-smoke.sh [options]

Disposable DNS smoke test for the Obscura Unbound image.

Options:
  --keep-artifacts       Do not remove test container/network
  --network <name>       Test Docker network name
  -h, --help             Show this help
EOF
}

log() { printf '%s\n' "$*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS: %s\n' "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL: %s\n' "$*" >&2; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); printf 'SKIP: %s\n' "$*"; }

cleanup() {
    local exit_code=$?
    if [ "$KEEP_ARTIFACTS" -eq 0 ]; then
        docker rm -f "$HELPER_NAME" "$CONTAINER_NAME" >/dev/null 2>&1 || true
        docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
    fi
    exit "$exit_code"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --keep-artifacts) KEEP_ARTIFACTS=1; shift ;;
            --network) NETWORK_NAME="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage; exit 1 ;;
        esac
    done
}

print_summary() {
    log ""
    log "Summary:"
    log "  pass: $PASS_COUNT"
    log "  fail: $FAIL_COUNT"
    log "  skip: $SKIP_COUNT"
    [ "$FAIL_COUNT" -eq 0 ]
}

main() {
    trap cleanup EXIT
    parse_args "$@"

    command -v docker >/dev/null 2>&1 || {
        printf 'ERROR: required command not found: docker\n' >&2
        exit 1
    }

    docker compose build dns >/dev/null
    pass "built Obscura DNS image"

    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
    if ! docker network create --subnet "$IPV4_SUBNET" "$NETWORK_NAME" >/dev/null 2>&1; then
        skip "DNS smoke skipped because allowed test subnet $IPV4_SUBNET is unavailable"
        print_summary
        return
    fi
    pass "created disposable DNS test network"

    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run -d --name "$CONTAINER_NAME" --network "$NETWORK_NAME" --ip "$DNS_IPV4" obscura-dns >/dev/null
    sleep 3
    pass "started disposable DNS resolver"

    docker run --rm --name "$HELPER_NAME" --network "$NETWORK_NAME" alpine:3.20 \
        nslookup example.com "$DNS_IPV4" >/dev/null
    pass "resolved public domain through Obscura DNS"

    print_summary
}

main "$@"
