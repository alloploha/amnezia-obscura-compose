#!/usr/bin/env bash
set -u

RUN_DOCKER=0
RUN_E2E=0
RUN_AWG_MIGRATION=0
RUN_AWG_TUNNEL=0
RUN_XRAY_MIGRATION=0
RUN_XRAY_FLOW=0
RUN_SOCKS5_COMPAT=0
RUN_DNS_SMOKE=0
RUN_BLACKLIST_FIXTURES=0
RUN_HOST_PREFLIGHT=0
RUN_MIGRATION_WORKFLOW=0
RUN_MIGRATION_ROLLBACK=0
KEEP_GOING=0
TIMEOUT_SECONDS="${OBSCURA_TEST_TIMEOUT:-}"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_STEPS=""

usage() {
    cat <<'EOF'
Usage: test-all.sh [options]

Repository-level validation gate for Obscura.

Default mode runs non-destructive static checks:
  - git whitespace checks
  - Bash syntax checks for repo-owned scripts and entrypoints
  - Docker Compose config checks for base and Amnezia-overlay files

Options:
  --docker          Include Docker daemon checks and image builds
  --e2e             Run host-side service tests for already-running services
  --awg-migration   Run the AWG migration E2E test
  --awg-tunnel      Run the AWG migration E2E test with real tunnel traffic
  --xray-migration  Run the Xray migration E2E test
  --xray-flow       Run the Xray migration E2E test with client HTTP flow
  --socks5-compat   Run the SOCKS5 Amnezia compatibility E2E test
  --dns-smoke       Run the disposable DNS smoke test
  --blacklist-fixtures
                    Run non-mutating blacklist fixture tests
  --host-preflight  Run host readiness preflight
  --migration-workflow
                    Run non-mutating unified migration workflow tests
  --migration-rollback
                    Run migration rollback fixture tests
  --keep-going      Continue after failures and report every failed step
  -h, --help        Show this help

Environment:
  PYTHON_BIN             Python executable forwarded to AWG helpers
  OBSCURA_TEST_TIMEOUT   Optional timeout in seconds for top-level steps
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
    FAILED_STEPS="${FAILED_STEPS}${FAILED_STEPS:+
}$*"
    printf 'FAIL: %s\n' "$*" >&2
}

skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    printf 'SKIP: %s\n' "$*"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --docker)
                RUN_DOCKER=1
                shift
                ;;
            --e2e)
                RUN_E2E=1
                shift
                ;;
            --awg-migration)
                RUN_AWG_MIGRATION=1
                shift
                ;;
            --awg-tunnel)
                RUN_AWG_TUNNEL=1
                RUN_AWG_MIGRATION=1
                shift
                ;;
            --xray-migration)
                RUN_XRAY_MIGRATION=1
                shift
                ;;
            --xray-flow)
                RUN_XRAY_FLOW=1
                RUN_XRAY_MIGRATION=1
                shift
                ;;
            --socks5-compat)
                RUN_SOCKS5_COMPAT=1
                shift
                ;;
            --dns-smoke)
                RUN_DNS_SMOKE=1
                shift
                ;;
            --blacklist-fixtures)
                RUN_BLACKLIST_FIXTURES=1
                shift
                ;;
            --host-preflight)
                RUN_HOST_PREFLIGHT=1
                shift
                ;;
            --migration-workflow)
                RUN_MIGRATION_WORKFLOW=1
                shift
                ;;
            --migration-rollback)
                RUN_MIGRATION_ROLLBACK=1
                RUN_MIGRATION_WORKFLOW=1
                shift
                ;;
            --keep-going)
                KEEP_GOING=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                printf 'ERROR: unknown argument: %s\n' "$1" >&2
                usage >&2
                exit 64
                ;;
        esac
    done
}

validate_timeout() {
    if [ -z "$TIMEOUT_SECONDS" ]; then
        return
    fi

    case "$TIMEOUT_SECONDS" in
        *[!0-9]*|'')
            printf 'ERROR: OBSCURA_TEST_TIMEOUT must be an integer number of seconds\n' >&2
            exit 64
            ;;
    esac
}

print_summary() {
    log ""
    log "Summary:"
    log "  pass: $PASS_COUNT"
    log "  fail: $FAIL_COUNT"
    log "  skip: $SKIP_COUNT"

    if [ -n "$FAILED_STEPS" ]; then
        log ""
        log "Failed steps:"
        printf '%s\n' "$FAILED_STEPS" | sed 's/^/  - /'
    fi
}

finish_after_failure_if_needed() {
    if [ "$KEEP_GOING" -eq 0 ]; then
        print_summary
        exit 1
    fi
}

run_step() {
    local name="$1"
    shift

    log ""
    log "==> $name"

    if [ -n "$TIMEOUT_SECONDS" ] && command -v timeout >/dev/null 2>&1; then
        if timeout "$TIMEOUT_SECONDS" "$@"; then
            pass "$name"
        else
            fail "$name"
            finish_after_failure_if_needed
        fi
        return
    fi

    if "$@"; then
        pass "$name"
    else
        fail "$name"
        finish_after_failure_if_needed
    fi
}

run_optional_step() {
    local name="$1"
    shift

    log ""
    log "==> $name"

    if "$@"; then
        pass "$name"
    else
        fail "$name"
        finish_after_failure_if_needed
    fi
}

require_cmd_for_step() {
    local command_name="$1"
    local step_name="$2"

    if command -v "$command_name" >/dev/null 2>&1; then
        return 0
    fi

    fail "$step_name (missing command: $command_name)"
    finish_after_failure_if_needed
    return 1
}

ensure_repo_root() {
    local script_dir
    local repo_root

    script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
    repo_root="$(CDPATH= cd -- "$script_dir/.." && pwd)"
    cd "$repo_root" || exit 1
}

docker_daemon_available() {
    docker info >/dev/null 2>&1
}

mode_label() {
    local label="static"

    [ "$RUN_DOCKER" -eq 1 ] && label="$label +docker"
    [ "$RUN_E2E" -eq 1 ] && label="$label +e2e"
    [ "$RUN_AWG_MIGRATION" -eq 1 ] && label="$label +awg-migration"
    [ "$RUN_AWG_TUNNEL" -eq 1 ] && label="$label +awg-tunnel"
    [ "$RUN_XRAY_MIGRATION" -eq 1 ] && label="$label +xray-migration"
    [ "$RUN_XRAY_FLOW" -eq 1 ] && label="$label +xray-flow"
    [ "$RUN_SOCKS5_COMPAT" -eq 1 ] && label="$label +socks5-compat"
    [ "$RUN_DNS_SMOKE" -eq 1 ] && label="$label +dns-smoke"
    [ "$RUN_BLACKLIST_FIXTURES" -eq 1 ] && label="$label +blacklist-fixtures"
    [ "$RUN_HOST_PREFLIGHT" -eq 1 ] && label="$label +host-preflight"
    [ "$RUN_MIGRATION_WORKFLOW" -eq 1 ] && label="$label +migration-workflow"
    [ "$RUN_MIGRATION_ROLLBACK" -eq 1 ] && label="$label +migration-rollback"

    printf '%s\n' "$label"
}

compose_config_checks() {
    run_step "Compose config: base" sh -c 'docker compose -f compose.yaml config >/dev/null'
    run_step "Compose config: Amnezia overlay" sh -c 'docker compose -f compose.yaml -f compose.amnezia.yaml config >/dev/null'
    run_step "Compose config: SOCKS5 profile" sh -c 'docker compose --profile socks5proxy config >/dev/null'
    run_step "Compose config: Xray profile" sh -c 'docker compose --profile xray config >/dev/null'
    run_step "Compose config: AWG profile" sh -c 'docker compose --profile awg config >/dev/null'
}

bash_syntax_checks() {
    local script
    local scripts_found=0

    while IFS= read -r script; do
        scripts_found=1
        run_step "Bash syntax: $script" bash -n "$script"
    done <<'EOF'
scripts/compose-amnezia.sh
scripts/check-host.sh
scripts/enable-docker-ipv6.sh
scripts/obscura.sh
scripts/externalize-amnezia-awg.sh
scripts/externalize-amnezia-socks5proxy.sh
scripts/externalize-amnezia-xray.sh
scripts/import-amnezia-awg.sh
scripts/import-amnezia-xray.sh
scripts/install-blacklist.sh
scripts/install-docker-compose.sh
scripts/manage-awg-clients.sh
scripts/manage-xray-clients.sh
scripts/refresh-blacklist.sh
scripts/test-all.sh
scripts/test-awg-host.sh
scripts/test-awg-migration.sh
scripts/test-blacklist-fixtures.sh
scripts/test-dns-smoke.sh
scripts/test-migration-workflow.sh
scripts/test-socks5proxy-host.sh
scripts/test-socks5proxy-compat.sh
scripts/test-xray-host.sh
scripts/test-xray-migration.sh
scripts/uninstall-blacklist.sh
scripts/upgrade-xray-engine.sh
awg/entrypoint.sh
awg/healthcheck.sh
socks5proxy/entrypoint.sh
socks5proxy/healthcheck.sh
xray/entrypoint.sh
xray/healthcheck.sh
scripts/lib/migration.sh
EOF

    if [ "$scripts_found" -eq 0 ]; then
        fail "Bash syntax checks (no scripts found)"
        finish_after_failure_if_needed
    fi
}

static_checks() {
    require_cmd_for_step git "Static checks" || return
    require_cmd_for_step bash "Static checks" || return
    require_cmd_for_step docker "Compose config checks" || return

    run_step "Git whitespace check" git diff --check
    bash_syntax_checks
    compose_config_checks
}

docker_build_checks() {
    if ! docker_daemon_available; then
        fail "Docker daemon availability"
        finish_after_failure_if_needed
        return
    fi

    run_step "Docker build: dns" docker compose build dns
    run_step "Docker build: socks5proxy" docker compose --profile socks5proxy build socks5proxy
    run_step "Docker build: xray" docker compose --profile xray build xray
    run_step "Docker build: awg" docker compose --profile awg build awg
}

compose_service_container() {
    local service="$1"

    docker ps \
        --filter "label=com.docker.compose.project=obscura" \
        --filter "label=com.docker.compose.service=$service" \
        --filter "label=com.docker.compose.container-number=1" \
        --format '{{.Names}}' \
        | head -n 1
}

missing_commands() {
    local command_name
    local missing=""

    for command_name in "$@"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            missing="${missing}${missing:+, }$command_name"
        fi
    done

    printf '%s\n' "$missing"
}

is_linux_host() {
    [ "$(uname -s 2>/dev/null || printf unknown)" = "Linux" ]
}

host_service_tests() {
    local container
    local missing

    if ! docker_daemon_available; then
        fail "Docker daemon availability for E2E checks"
        finish_after_failure_if_needed
        return
    fi

    container="$(compose_service_container socks5proxy)"
    if [ -n "$container" ]; then
        missing="$(missing_commands curl ip nc od)"
        if [ -n "$missing" ]; then
            skip "SOCKS5 host validation skipped because host commands are missing: $missing"
        else
            run_optional_step "SOCKS5 host validation" bash scripts/test-socks5proxy-host.sh --container "$container"
        fi
    else
        skip "SOCKS5 host validation skipped because the service is not running"
    fi

    container="$(compose_service_container xray)"
    if [ -n "$container" ]; then
        if ! is_linux_host; then
            skip "Xray host validation skipped because the temporary client uses Linux host networking"
        else
            run_optional_step "Xray host validation" bash scripts/test-xray-host.sh --container "$container"
        fi
    else
        skip "Xray host validation skipped because the service is not running"
    fi

    container="$(compose_service_container awg)"
    if [ -n "$container" ]; then
        missing="$(missing_commands bash "${PYTHON_BIN:-python3}")"
        if [ -n "$missing" ]; then
            skip "AWG host validation skipped because host commands are missing: $missing"
        else
            run_optional_step "AWG host validation" bash scripts/test-awg-host.sh --container "$container"
        fi
    else
        skip "AWG host validation skipped because the service is not running"
    fi
}

awg_migration_tests() {
    if ! docker_daemon_available; then
        fail "Docker daemon availability for AWG migration checks"
        finish_after_failure_if_needed
        return
    fi

    if [ "$RUN_AWG_TUNNEL" -eq 1 ]; then
        run_step "AWG migration E2E with tunnel traffic" bash scripts/test-awg-migration.sh --with-tunnel
    else
        run_step "AWG migration E2E" bash scripts/test-awg-migration.sh
    fi
}

xray_migration_tests() {
    if ! docker_daemon_available; then
        fail "Docker daemon availability for Xray migration checks"
        finish_after_failure_if_needed
        return
    fi

    if [ "$RUN_XRAY_FLOW" -eq 1 ]; then
        run_step "Xray migration E2E with client flow" bash scripts/test-xray-migration.sh --with-flow
    else
        run_step "Xray migration E2E" bash scripts/test-xray-migration.sh
    fi
}

socks5_compat_tests() {
    if ! docker_daemon_available; then
        fail "Docker daemon availability for SOCKS5 compatibility checks"
        finish_after_failure_if_needed
        return
    fi

    run_step "SOCKS5 compatibility E2E" bash scripts/test-socks5proxy-compat.sh
}

dns_smoke_tests() {
    if ! docker_daemon_available; then
        fail "Docker daemon availability for DNS smoke checks"
        finish_after_failure_if_needed
        return
    fi

    run_step "DNS smoke test" bash scripts/test-dns-smoke.sh
}

blacklist_fixture_tests() {
    run_step "Blacklist fixture tests" bash scripts/test-blacklist-fixtures.sh
}

host_preflight_test() {
    run_step "Host preflight" bash scripts/check-host.sh
}

migration_workflow_tests() {
    run_step "Migration workflow fixtures" bash scripts/test-migration-workflow.sh
}

main() {
    parse_args "$@"
    validate_timeout
    ensure_repo_root

    log "Obscura validation gate"
    log "Mode: $(mode_label)"

    static_checks

    if [ "$RUN_DOCKER" -eq 1 ]; then
        docker_build_checks
    fi

    if [ "$RUN_E2E" -eq 1 ]; then
        host_service_tests
    fi

    if [ "$RUN_AWG_MIGRATION" -eq 1 ]; then
        awg_migration_tests
    fi

    if [ "$RUN_XRAY_MIGRATION" -eq 1 ]; then
        xray_migration_tests
    fi

    if [ "$RUN_SOCKS5_COMPAT" -eq 1 ]; then
        socks5_compat_tests
    fi

    if [ "$RUN_DNS_SMOKE" -eq 1 ]; then
        dns_smoke_tests
    fi

    if [ "$RUN_BLACKLIST_FIXTURES" -eq 1 ]; then
        blacklist_fixture_tests
    fi

    if [ "$RUN_HOST_PREFLIGHT" -eq 1 ]; then
        host_preflight_test
    fi

    if [ "$RUN_MIGRATION_WORKFLOW" -eq 1 ]; then
        migration_workflow_tests
    fi

    print_summary
    [ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
