#!/usr/bin/env bash
set -euo pipefail

DEFAULT_PUBLIC_IPV4_URL="https://api.ipify.org?format=text"
DEFAULT_PUBLIC_IPV6_URL="https://api6.ipify.org?format=text"
DEFAULT_SERVICE_LABEL="com.docker.compose.service=socks5proxy"
DEFAULT_LOOPBACK_PROXY_HOST="127.0.0.1"

CONTAINER_NAME=""
PUBLIC_IPV4_URL="$DEFAULT_PUBLIC_IPV4_URL"
PUBLIC_IPV6_URL="$DEFAULT_PUBLIC_IPV6_URL"
TIMEOUT="${SOCKS5_TEST_TIMEOUT:-15}"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

TMPDIR=""

usage() {
    cat <<'EOF'
Usage: test-socks5proxy-host.sh [options]

Host-side validation for the running Obscura SOCKS5 proxy.

The script discovers the running socks5proxy container via Docker, extracts the
effective published port and first configured credential, then runs:
  - loopback ingress test via 127.0.0.1
  - IPv4 ingress test via the host primary IPv4
  - IPv6 ingress test via the host primary IPv6 or ::1
  - public IPv4 egress test
  - public IPv6 egress test

Options:
  --container <name>         Explicit container name
  --public-ipv4-url <url>    Override the public IPv4 test URL
  --public-ipv6-url <url>    Override the public IPv6 test URL
  -h, --help                 Show this help

Examples:
  sudo bash scripts/test-socks5proxy-host.sh
  sudo bash scripts/test-socks5proxy-host.sh --container obscura-socks5proxy-1
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
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --container\n' >&2
                    exit 1
                }
                CONTAINER_NAME="$2"
                shift 2
                ;;
            --public-ipv4-url)
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --public-ipv4-url\n' >&2
                    exit 1
                }
                PUBLIC_IPV4_URL="$2"
                shift 2
                ;;
            --public-ipv6-url)
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --public-ipv6-url\n' >&2
                    exit 1
                }
                PUBLIC_IPV6_URL="$2"
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

discover_container() {
    if [ -n "$CONTAINER_NAME" ]; then
        return
    fi

    CONTAINER_NAME="$(
        docker ps \
            --filter "label=$DEFAULT_SERVICE_LABEL" \
            --format '{{.Names}}' \
            | head -n 1
    )"

    if [ -z "$CONTAINER_NAME" ]; then
        printf 'ERROR: no running socks5proxy container found\n' >&2
        exit 1
    fi
}

discover_port() {
    local port_lines
    local host_port

    port_lines="$(docker port "$CONTAINER_NAME" 1080/tcp 2>/dev/null || true)"
    if [ -z "$port_lines" ]; then
        port_lines="$(docker port "$CONTAINER_NAME" 2>/dev/null || true)"
    fi

    host_port="$(printf '%s\n' "$port_lines" | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -n 1)"
    if [ -z "$host_port" ]; then
        printf 'ERROR: could not determine published SOCKS5 port for %s\n' "$CONTAINER_NAME" >&2
        exit 1
    fi

    PROXY_PORT="$host_port"
}

discover_auth() {
    local auth_line
    local user_record

    auth_line="$(
        docker exec "$CONTAINER_NAME" sh -lc \
            "awk '\$1==\"auth\"{sub(/^auth[[:space:]]+/,\"\"); print; exit}' /usr/local/3proxy/conf/3proxy.cfg"
    )"

    user_record="$(
        docker exec "$CONTAINER_NAME" sh -lc \
            "sed -n 's/^users[[:space:]]\\+//p' /usr/local/3proxy/conf/3proxy.cfg | awk '{print \$1; exit}'"
    )"

    PROXY_AUTH_MODE="${auth_line:-none}"
    PROXY_USERNAME=""
    PROXY_PASSWORD=""

    if [ -n "$user_record" ]; then
        PROXY_USERNAME="${user_record%%:*}"
        PROXY_PASSWORD="${user_record##*:}"
    fi

    if [ "$PROXY_AUTH_MODE" != "none" ] && { [ -z "$PROXY_USERNAME" ] || [ -z "$PROXY_PASSWORD" ]; }; then
        printf 'ERROR: auth mode is %s but no proxy user/password could be extracted\n' "$PROXY_AUTH_MODE" >&2
        exit 1
    fi
}

discover_host_ips() {
    HOST_IPV4="$(
        { ip route get 1.1.1.1 2>/dev/null || true; } \
            | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}'
    )"

    HOST_IPV6="$(
        { ip -6 route get 2606:4700:4700::1111 2>/dev/null || true; } \
            | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}'
    )"
}

format_proxy_host() {
    case "$1" in
        *:*)
            printf '[%s]' "$1"
            ;;
        *)
            printf '%s' "$1"
            ;;
    esac
}

curl_via_proxy() {
    local proxy_host="$1"
    local url="$2"
    shift 2

    local formatted_host
    formatted_host="$(format_proxy_host "$proxy_host")"

    local -a curl_args
    curl_args=(
        --silent
        --show-error
        --fail
        --max-time "$TIMEOUT"
        --connect-timeout "$TIMEOUT"
        --proxy "socks5h://${formatted_host}:${PROXY_PORT}"
    )

    if [ -n "$PROXY_USERNAME" ] || [ -n "$PROXY_PASSWORD" ]; then
        curl_args+=(--proxy-user "${PROXY_USERNAME}:${PROXY_PASSWORD}")
    fi

    curl_args+=("$@" "$url")
    curl "${curl_args[@]}"
}

run_test() {
    local name="$1"
    local cmd="$2"

    if output="$(eval "$cmd" 2>&1)"; then
        pass "$name${output:+ -> $output}"
    else
        fail "$name${output:+ -> $output}"
    fi
}

run_skip_or_test() {
    local requirement="$1"
    local skip_reason="$2"
    local name="$3"
    local cmd="$4"

    if [ -z "$requirement" ]; then
        skip "$skip_reason"
        return
    fi

    run_test "$name" "$cmd"
}

main() {
    trap cleanup EXIT

    parse_args "$@"

    require_cmd docker
    require_cmd curl
    require_cmd ip
    discover_container
    discover_port
    discover_auth
    discover_host_ips

    log "Container: $CONTAINER_NAME"
    log "Published port: $PROXY_PORT"
    if [ -n "$PROXY_USERNAME" ]; then
        log "Proxy user: $PROXY_USERNAME"
    else
        log "Proxy auth: none"
    fi
    log "Host IPv4: ${HOST_IPV4:-unavailable}"
    log "Host IPv6: ${HOST_IPV6:-unavailable}"
    log ""

    run_test \
        "Loopback ingress via 127.0.0.1" \
        "curl_via_proxy '$DEFAULT_LOOPBACK_PROXY_HOST' '$PUBLIC_IPV4_URL' -4"

    run_skip_or_test \
        "$HOST_IPV4" \
        "Primary host IPv4 is unavailable; skipping IPv4 ingress test" \
        "IPv4 ingress via $HOST_IPV4" \
        "curl_via_proxy '$HOST_IPV4' '$PUBLIC_IPV4_URL' -4"

    run_test \
        "IPv6 ingress via ::1" \
        "curl_via_proxy '::1' '$PUBLIC_IPV4_URL' -4"

    run_skip_or_test \
        "$HOST_IPV6" \
        "Primary host IPv6 is unavailable; skipping global IPv6 ingress test" \
        "IPv6 ingress via $HOST_IPV6" \
        "curl_via_proxy '$HOST_IPV6' '$PUBLIC_IPV4_URL' -4"

    run_test \
        "Public IPv4 egress" \
        "curl_via_proxy '$DEFAULT_LOOPBACK_PROXY_HOST' '$PUBLIC_IPV4_URL' -4"

    run_test \
        "Public IPv6 egress" \
        "curl_via_proxy '$DEFAULT_LOOPBACK_PROXY_HOST' '$PUBLIC_IPV6_URL' -6"

    log ""
    log "Summary: pass=$PASS_COUNT fail=$FAIL_COUNT skip=$SKIP_COUNT"

    if [ "$FAIL_COUNT" -ne 0 ]; then
        exit 1
    fi
}

main "$@"
