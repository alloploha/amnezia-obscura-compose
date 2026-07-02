#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

TMPDIR=""
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
    if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
        rm -rf "$TMPDIR"
    fi
}
trap cleanup EXIT

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS: %s\n' "$*"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL: %s\n' "$*" >&2
}

run() {
    local name="$1"
    shift
    if "$@"; then
        pass "$name"
    else
        fail "$name"
        return 1
    fi
}

prepare_fixtures() {
    TMPDIR="$(mktemp -d)"

    mkdir -p "$TMPDIR/amnezia/xray" "$TMPDIR/amnezia/awg" "$TMPDIR/amnezia/socks5proxy/conf"
    printf '{}\n' >"$TMPDIR/amnezia/xray/server.json"
    printf 'uuid\n' >"$TMPDIR/amnezia/xray/xray_uuid.key"
    printf 'short\n' >"$TMPDIR/amnezia/xray/xray_short_id.key"
    printf 'public\n' >"$TMPDIR/amnezia/xray/xray_public.key"
    printf 'private\n' >"$TMPDIR/amnezia/xray/xray_private.key"

    printf '[Interface]\nPrivateKey = test\n' >"$TMPDIR/amnezia/awg/awg0.conf"
    printf 'private\n' >"$TMPDIR/amnezia/awg/wireguard_server_private_key.key"
    printf 'public\n' >"$TMPDIR/amnezia/awg/wireguard_server_public_key.key"
    printf 'psk\n' >"$TMPDIR/amnezia/awg/wireguard_psk.key"

    printf 'users test:CL:test\n' >"$TMPDIR/amnezia/socks5proxy/conf/3proxy.cfg"
}

assert_no_snapshot_created_by_dry_run() {
    local dry_dir="$TMPDIR/dry-snapshots"

    bash scripts/obscura.sh migrate snapshot --service all --snapshot-dir "$dry_dir" --amnezia-dir "$TMPDIR/amnezia" --dry-run >/dev/null
    [ ! -e "$dry_dir" ]
}

audit_json_has_services() {
    local output

    output="$(bash scripts/obscura.sh migrate audit --service all --amnezia-dir "$TMPDIR/amnezia" --json)"
    printf '%s' "$output" | grep -q '"services":\['
    printf '%s' "$output" | grep -q '"service":"xray"'
    printf '%s' "$output" | grep -q '"service":"awg"'
    printf '%s' "$output" | grep -q '"service":"socks5proxy"'
}

verify_fixture_state() {
    bash scripts/obscura.sh migrate verify --service xray --amnezia-dir "$TMPDIR/amnezia" >/dev/null
    bash scripts/obscura.sh migrate verify --service awg --amnezia-dir "$TMPDIR/amnezia" >/dev/null
    OBSCURA_SKIP_DOCKER_VERIFY=1 bash scripts/obscura.sh migrate verify --service socks5proxy --amnezia-dir "$TMPDIR/amnezia" >/dev/null
}

rollback_dry_run_accepts_snapshot_path() {
    local snapshot="$TMPDIR/snapshot"

    mkdir -p "$snapshot/xray"
    bash scripts/obscura.sh migrate rollback --service xray --snapshot "$snapshot" --amnezia-dir "$TMPDIR/amnezia" --dry-run >/dev/null
}

main() {
    prepare_fixtures

    run "Bash syntax: scripts/obscura.sh" bash -n scripts/obscura.sh
    run "Bash syntax: scripts/lib/migration.sh" bash -n scripts/lib/migration.sh
    run "Audit JSON includes supported services" audit_json_has_services
    run "Snapshot dry-run does not create target directory" assert_no_snapshot_created_by_dry_run
    run "Fixture state verifies without target containers" verify_fixture_state
    run "Rollback dry-run accepts snapshot path" rollback_dry_run_accepts_snapshot_path

    printf '\nSummary:\n'
    printf '  pass: %s\n' "$PASS_COUNT"
    printf '  fail: %s\n' "$FAIL_COUNT"
    [ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
