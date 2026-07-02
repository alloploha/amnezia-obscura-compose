#!/usr/bin/env bash
set -u

JSON_OUTPUT=0
CHECK_AMNEZIA=0
PYTHON_CHECK="${PYTHON_BIN:-}"
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
RESULTS=""

usage() {
    cat <<'EOF'
Usage: check-host.sh [options]

Host readiness preflight for Obscura.

Options:
  --amnezia         Also check Amnezia compatibility network assumptions
  --json            Emit JSON summary
  -h, --help        Show this help
EOF
}

record() {
    local status="$1"
    local name="$2"
    local detail="$3"

    RESULTS="${RESULTS}${RESULTS:+
}${status}|${name}|${detail}"
    case "$status" in
        pass) PASS_COUNT=$((PASS_COUNT + 1)) ;;
        warn) WARN_COUNT=$((WARN_COUNT + 1)) ;;
        fail) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    esac
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --amnezia) CHECK_AMNEZIA=1; shift ;;
            --json) JSON_OUTPUT=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 64 ;;
        esac
    done
}

check_command() {
    local name="$1"
    local command_name="$2"
    if command -v "$command_name" >/dev/null 2>&1; then
        record pass "$name" "$(command -v "$command_name")"
    else
        record fail "$name" "$command_name not found"
    fi
}

check_python() {
    if [ -n "$PYTHON_CHECK" ]; then
        if "$PYTHON_CHECK" -c 'print("ok")' >/dev/null 2>&1; then
            record pass "Python" "$PYTHON_CHECK"
        else
            record fail "Python" "$PYTHON_CHECK is not executable"
        fi
        return
    fi

    if python3 -c 'print("ok")' >/dev/null 2>&1; then
        record pass "Python" "python3"
    elif python -c 'print("ok")' >/dev/null 2>&1; then
        record pass "Python" "python"
    else
        record fail "Python" "python3/python not executable"
    fi
}

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        record fail "Docker daemon" "docker CLI is unavailable"
        return
    fi

    if docker info >/dev/null 2>&1; then
        record pass "Docker daemon" "reachable"
    else
        record fail "Docker daemon" "docker info failed"
    fi

    if docker compose version >/dev/null 2>&1; then
        record pass "Docker Compose plugin" "$(docker compose version 2>/dev/null | head -n 1)"
    else
        record fail "Docker Compose plugin" "docker compose version failed"
    fi
}

check_tun() {
    if [ -e /dev/net/tun ]; then
        record pass "TUN device" "/dev/net/tun exists"
    else
        record warn "TUN device" "/dev/net/tun is not visible from this shell"
    fi

    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        if docker run --rm --cap-add NET_ADMIN --device /dev/net/tun:/dev/net/tun alpine:3.20 sh -lc 'test -e /dev/net/tun' >/dev/null 2>&1; then
            record pass "Container NET_ADMIN/TUN" "disposable container can access /dev/net/tun"
        else
            record warn "Container NET_ADMIN/TUN" "disposable container could not access /dev/net/tun"
        fi
    fi
}

check_ipv6() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        if docker network create --ipv6 --subnet fd30:153:ffff::/120 obscura-preflight-ipv6 >/dev/null 2>&1; then
            docker network rm obscura-preflight-ipv6 >/dev/null 2>&1 || true
            record pass "Docker IPv6 network" "daemon accepted an IPv6 bridge network"
        else
            record warn "Docker IPv6 network" "daemon did not accept a disposable IPv6 bridge network"
        fi
    fi
}

check_amnezia_network() {
    if [ "$CHECK_AMNEZIA" -ne 1 ]; then
        return
    fi
    if docker network inspect amnezia-dns-net >/dev/null 2>&1; then
        subnet="$(docker network inspect -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' amnezia-dns-net 2>/dev/null | tr '\n' ' ')"
        record pass "Amnezia DNS network" "amnezia-dns-net exists (${subnet:-unknown subnet})"
    else
        record warn "Amnezia DNS network" "amnezia-dns-net is absent"
    fi
}

check_firewall_tools() {
    local iptables_ok=0
    local nft_ok=0
    command -v iptables >/dev/null 2>&1 && command -v ip6tables >/dev/null 2>&1 && command -v ipset >/dev/null 2>&1 && iptables_ok=1
    command -v nft >/dev/null 2>&1 && nft_ok=1

    if [ "$iptables_ok" -eq 1 ] || [ "$nft_ok" -eq 1 ]; then
        record pass "Firewall tools" "iptables_backend=$iptables_ok nftables_backend=$nft_ok"
    else
        record warn "Firewall tools" "no complete iptables/ipset or nft backend found in this shell"
    fi
}

print_text() {
    printf 'Obscura host preflight\n'
    printf '%s\n' "$RESULTS" | while IFS='|' read -r status name detail; do
        [ -n "$status" ] || continue
        printf '%s: %s - %s\n' "$(printf '%s' "$status" | tr '[:lower:]' '[:upper:]')" "$name" "$detail"
    done
    printf '\nSummary: pass=%s warn=%s fail=%s\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

print_json() {
    printf '{\n  "pass": %s,\n  "warn": %s,\n  "fail": %s,\n  "checks": [\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
    first=1
    printf '%s\n' "$RESULTS" | while IFS='|' read -r status name detail; do
        [ -n "$status" ] || continue
        [ "$first" -eq 1 ] || printf ',\n'
        first=0
        printf '    {"status": "%s", "name": "%s", "detail": "%s"}' \
            "$(json_escape "$status")" "$(json_escape "$name")" "$(json_escape "$detail")"
    done
    printf '\n  ]\n}\n'
}

main() {
    parse_args "$@"
    check_command "Bash" bash
    check_python
    check_command "Docker CLI" docker
    check_docker
    check_tun
    check_ipv6
    check_amnezia_network
    check_firewall_tools

    if [ "$JSON_OUTPUT" -eq 1 ]; then
        print_json
    else
        print_text
    fi

    [ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
