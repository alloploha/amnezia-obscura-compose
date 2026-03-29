#!/usr/bin/env bash
set -euo pipefail

DEFAULT_PUBLIC_IPV4_URL="https://api.ipify.org?format=text"
DEFAULT_PUBLIC_IPV6_URL="https://api6.ipify.org?format=text"
DEFAULT_SERVICE_LABEL="com.docker.compose.service=socks5proxy"
DEFAULT_LOOPBACK_PROXY_HOST="127.0.0.1"
DEFAULT_CONNECT_TEST_IPV4="1.1.1.1"
DEFAULT_CONNECT_TEST_IPV6="2606:4700:4700::1111"

CONTAINER_NAME=""
PUBLIC_IPV4_URL="$DEFAULT_PUBLIC_IPV4_URL"
PUBLIC_IPV6_URL="$DEFAULT_PUBLIC_IPV6_URL"
TIMEOUT="${SOCKS5_TEST_TIMEOUT:-15}"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

TMPDIR=""
SOCKS_AUTH_REQUIRED=""

usage() {
    cat <<'EOF'
Usage: test-socks5proxy-host.sh [options]

Host-side validation for the running Obscura SOCKS5 proxy.

The script discovers the running socks5proxy container via Docker, extracts the
effective published port and first configured credential, then runs:
  - raw SOCKS5 auth tests over loopback, host IPv4, and host IPv6
  - raw SOCKS5 CONNECT tests to public IPv4 and IPv6 literals
  - HTTP-over-SOCKS tests against public IPv4 and IPv6 echo services

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

    SOCKS_AUTH_REQUIRED="false"
    if [ "$PROXY_AUTH_MODE" != "none" ]; then
        SOCKS_AUTH_REQUIRED="true"
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

hex_byte() {
    printf '\\x%02x' "$1"
}

build_socks_greeting() {
    if [ "$SOCKS_AUTH_REQUIRED" = "true" ]; then
        printf '\x05\x01\x02'
    else
        printf '\x05\x01\x00'
    fi
}

build_socks_auth_packet() {
    [ "$SOCKS_AUTH_REQUIRED" = "true" ] || return 0

    printf '\x01'
    printf '%b' "$(hex_byte "${#PROXY_USERNAME}")"
    printf '%s' "$PROXY_USERNAME"
    printf '%b' "$(hex_byte "${#PROXY_PASSWORD}")"
    printf '%s' "$PROXY_PASSWORD"
}

build_socks_connect_ipv4_packet() {
    printf '\x05\x01\x00\x01\x01\x01\x01\x01\x01\xbb'
}

build_socks_connect_ipv6_packet() {
    printf '\x05\x01\x00\x04'
    printf '\x26\x06\x47\x00\x47\x00\x00\x00\x00\x00\x00\x00\x00\x00\x11\x11'
    printf '\x01\xbb'
}

normalize_hex_stream() {
    tr '\n' ' ' | tr -s ' ' ' ' | sed 's/^ //; s/ $//'
}

run_socks_exchange() {
    local proxy_host="$1"
    local mode="$2"

    {
        build_socks_greeting
        if [ "$SOCKS_AUTH_REQUIRED" = "true" ]; then
            build_socks_auth_packet
        fi
        case "$mode" in
            auth_only)
                ;;
            connect_ipv4)
                build_socks_connect_ipv4_packet
                ;;
            connect_ipv6)
                build_socks_connect_ipv6_packet
                ;;
            *)
                printf 'ERROR: unknown SOCKS exchange mode: %s\n' "$mode" >&2
                return 1
                ;;
        esac
    } | nc -w "$TIMEOUT" "$proxy_host" "$PROXY_PORT" | od -An -tx1 -v | normalize_hex_stream
}

validate_socks_auth_hex() {
    local hex_stream="$1"

    case "$SOCKS_AUTH_REQUIRED" in
        true)
            case "$hex_stream" in
                "05 02 01 00"|\
                "05 02 01 00 "*)
                    return 0
                    ;;
                *)
                    printf 'unexpected SOCKS auth exchange: %s\n' "$hex_stream" >&2
                    return 1
                    ;;
            esac
            ;;
        false)
            case "$hex_stream" in
                "05 00"|\
                "05 00 "*)
                    return 0
                    ;;
                *)
                    printf 'unexpected SOCKS auth exchange: %s\n' "$hex_stream" >&2
                    return 1
                    ;;
            esac
            ;;
        *)
            printf 'ERROR: invalid SOCKS auth state: %s\n' "$SOCKS_AUTH_REQUIRED" >&2
            return 1
            ;;
    esac
}

validate_socks_connect_hex() {
    local hex_stream="$1"
    local success_prefix=""

    case "$SOCKS_AUTH_REQUIRED" in
        true)
            success_prefix="05 02 01 00 05 00"
            ;;
        false)
            success_prefix="05 00 05 00"
            ;;
        *)
            printf 'ERROR: invalid SOCKS auth state: %s\n' "$SOCKS_AUTH_REQUIRED" >&2
            return 1
            ;;
    esac

    case "$hex_stream" in
        "$success_prefix"|\
        "$success_prefix "*)
            return 0
            ;;
        *)
            printf 'unexpected SOCKS CONNECT exchange: %s\n' "$hex_stream" >&2
            return 1
            ;;
    esac
}

run_socks_auth_test() {
    local proxy_host="$1"
    local response

    response="$(run_socks_exchange "$proxy_host" auth_only)"
    validate_socks_auth_hex "$response"
    printf '%s' "$response"
}

run_socks_connect_test() {
    local proxy_host="$1"
    local mode="$2"
    local response

    response="$(run_socks_exchange "$proxy_host" "$mode")"
    validate_socks_connect_hex "$response"
    printf '%s' "$response"
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
    require_cmd nc
    require_cmd od
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
        "Loopback SOCKS auth via 127.0.0.1" \
        "run_socks_auth_test '$DEFAULT_LOOPBACK_PROXY_HOST'"

    run_skip_or_test \
        "$HOST_IPV4" \
        "Primary host IPv4 is unavailable; skipping IPv4 SOCKS auth test" \
        "IPv4 SOCKS auth via $HOST_IPV4" \
        "run_socks_auth_test '$HOST_IPV4'"

    run_test \
        "IPv6 SOCKS auth via ::1" \
        "run_socks_auth_test '::1'"

    run_skip_or_test \
        "$HOST_IPV6" \
        "Primary host IPv6 is unavailable; skipping host IPv6 SOCKS auth test" \
        "IPv6 SOCKS auth via $HOST_IPV6" \
        "run_socks_auth_test '$HOST_IPV6'"

    run_test \
        "SOCKS IPv4 CONNECT via 127.0.0.1 to $DEFAULT_CONNECT_TEST_IPV4:443" \
        "run_socks_connect_test '$DEFAULT_LOOPBACK_PROXY_HOST' connect_ipv4"

    run_test \
        "SOCKS IPv6 CONNECT via 127.0.0.1 to [$DEFAULT_CONNECT_TEST_IPV6]:443" \
        "run_socks_connect_test '$DEFAULT_LOOPBACK_PROXY_HOST' connect_ipv6"

    run_test \
        "Public IPv4 HTTP egress via 127.0.0.1" \
        "curl_via_proxy '$DEFAULT_LOOPBACK_PROXY_HOST' '$PUBLIC_IPV4_URL' -4"

    run_test \
        "Public IPv6 HTTP egress via 127.0.0.1" \
        "curl_via_proxy '$DEFAULT_LOOPBACK_PROXY_HOST' '$PUBLIC_IPV6_URL' -6"

    log ""
    log "Summary: pass=$PASS_COUNT fail=$FAIL_COUNT skip=$SKIP_COUNT"

    if [ "$FAIL_COUNT" -ne 0 ]; then
        exit 1
    fi
}

main "$@"
