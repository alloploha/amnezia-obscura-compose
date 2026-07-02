#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/migration.sh
. "$SCRIPT_DIR/lib/migration.sh"

DEFAULT_SNAPSHOT_DIR="/srv/obscura/backups/amnezia-migration"
DEFAULT_AMNEZIA_DIR="/srv/amnezia"

COMMAND_GROUP=""
ACTION=""
SERVICE="all"
SOURCE_CONTAINER=""
TARGET_CONTAINER=""
SNAPSHOT_DIR="$DEFAULT_SNAPSHOT_DIR"
SNAPSHOT_PATH=""
AMNEZIA_DIR="$DEFAULT_AMNEZIA_DIR"
DRY_RUN=0
YES=0
JSON_OUTPUT=0
VERBOSE=0
WITH_FLOW=0
WITH_TUNNEL=0

usage() {
    cat <<'EOF'
Usage:
  obscura.sh migrate audit --service xray|awg|socks5proxy|all [options]
  obscura.sh migrate snapshot --service xray|awg|socks5proxy|all [options]
  obscura.sh migrate migrate --service xray|awg|socks5proxy [options]
  obscura.sh migrate verify --service xray|awg|socks5proxy [options]
  obscura.sh migrate rollback --service xray|awg|socks5proxy --snapshot <path> [options]

Common options:
  --source-container <name>  Override source Amnezia container name
  --target-container <name>  Override target Obscura container name
  --snapshot-dir <path>      Snapshot root, default /srv/obscura/backups/amnezia-migration
  --snapshot <path>          Existing snapshot path for verify or rollback
  --amnezia-dir <path>       Externalized Amnezia state root, default /srv/amnezia
  --dry-run                  Print planned actions without mutating state
  --yes                      Skip interactive confirmation for mutating actions
  --json                     Emit JSON for audit or verify
  --flow                     Run optional Xray flow verification
  --tunnel                   Run optional AWG tunnel verification
  --verbose                  Include extra non-secret metadata
  -h, --help                 Show this help
EOF
}

parse_args() {
    [ "$#" -ge 1 ] || { usage; exit 64; }
    COMMAND_GROUP="$1"
    shift
    [ "$COMMAND_GROUP" = "migrate" ] || die "unknown command group: $COMMAND_GROUP"

    [ "$#" -ge 1 ] || die "missing migrate action"
    ACTION="$1"
    shift

    case "$ACTION" in
        audit|snapshot|migrate|verify|rollback) ;;
        *) die "unknown migrate action: $ACTION" ;;
    esac

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --service)
                [ "$#" -ge 2 ] || die "missing value for --service"
                SERVICE="$2"
                shift 2
                ;;
            --source-container)
                [ "$#" -ge 2 ] || die "missing value for --source-container"
                SOURCE_CONTAINER="$2"
                shift 2
                ;;
            --target-container)
                [ "$#" -ge 2 ] || die "missing value for --target-container"
                TARGET_CONTAINER="$2"
                shift 2
                ;;
            --snapshot-dir)
                [ "$#" -ge 2 ] || die "missing value for --snapshot-dir"
                SNAPSHOT_DIR="${2%/}"
                shift 2
                ;;
            --snapshot)
                [ "$#" -ge 2 ] || die "missing value for --snapshot"
                SNAPSHOT_PATH="${2%/}"
                shift 2
                ;;
            --amnezia-dir)
                [ "$#" -ge 2 ] || die "missing value for --amnezia-dir"
                AMNEZIA_DIR="${2%/}"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --yes)
                YES=1
                shift
                ;;
            --json)
                JSON_OUTPUT=1
                shift
                ;;
            --flow)
                WITH_FLOW=1
                shift
                ;;
            --tunnel)
                WITH_TUNNEL=1
                shift
                ;;
            --verbose)
                VERBOSE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done

    safe_service_name "$SERVICE" || die "unsupported service: $SERVICE"

    if [ "$ACTION" = "migrate" ] || [ "$ACTION" = "verify" ] || [ "$ACTION" = "rollback" ]; then
        [ "$SERVICE" != "all" ] || die "$ACTION supports one service at a time"
    fi
}

service_list() {
    if [ "$SERVICE" = "all" ]; then
        printf '%s\n' xray awg socks5proxy
    else
        printf '%s\n' "$SERVICE"
    fi
}

effective_source_container() {
    local service="$1"
    if [ -n "$SOURCE_CONTAINER" ]; then
        printf '%s\n' "$SOURCE_CONTAINER"
    else
        service_source_container "$service"
    fi
}

effective_target_container() {
    local service="$1"
    if [ -n "$TARGET_CONTAINER" ]; then
        printf '%s\n' "$TARGET_CONTAINER"
        return
    fi

    if docker_available; then
        detect_obscura_container "$service"
    fi
}

audit_required_files() {
    local service="$1"
    local external_dir="$2"
    local source_container="$3"
    local container_path
    local missing=""
    local file_name

    container_path="$(service_container_path "$service")"
    for file_name in $(service_required_files "$service"); do
        if [ -s "$external_dir/$file_name" ]; then
            continue
        fi

        if docker_available && container_exists "$source_container"; then
            if docker exec "$source_container" sh -lc "test -s '$container_path/$file_name'" >/dev/null 2>&1; then
                continue
            fi
        fi

        missing="${missing}${missing:+ }$file_name"
    done

    printf '%s\n' "$missing"
}

audit_service_text() {
    local service="$1"
    local source_container external_dir target_container missing_files
    local source_exists=0 target_exists=0 source_status="" target_status="" target_health=""

    source_container="$(effective_source_container "$service")"
    external_dir="$(service_external_dir "$service" "$AMNEZIA_DIR")"
    target_container="$(effective_target_container "$service")"

    if docker_available && container_exists "$source_container"; then
        source_exists=1
        source_status="$(container_summary_value "$source_container" status)"
    fi
    if [ -n "$target_container" ] && docker_available && container_exists "$target_container"; then
        target_exists=1
        target_status="$(container_summary_value "$target_container" status)"
        target_health="$(container_health "$target_container")"
    fi

    missing_files="$(audit_required_files "$service" "$external_dir" "$source_container")"

    log "Service: $service"
    log "  source container: $source_container exists=$(json_bool "$source_exists") status=${source_status:-unknown}"
    log "  target container: ${target_container:-auto-not-found} exists=$(json_bool "$target_exists") status=${target_status:-unknown} health=${target_health:-unknown}"
    log "  externalized dir: $external_dir exists=$(json_bool "$([ -d "$external_dir" ] && printf 1 || printf 0)")"
    log "  missing required state: ${missing_files:-none}"

    if [ "$VERBOSE" -eq 1 ] && [ "$source_exists" -eq 1 ]; then
        log "  image: $(container_summary_value "$source_container" image)"
        log "  ports: $(container_summary_value "$source_container" ports)"
        log "  networks: $(container_summary_value "$source_container" networks)"
        log "  restart: $(container_summary_value "$source_container" restart)"
        log "  privileged: $(container_summary_value "$source_container" privileged)"
        log "  cap_add: $(container_summary_value "$source_container" capadd)"
    fi
}

audit_service_json() {
    local service="$1"
    local source_container external_dir target_container missing_files
    local source_exists=0 target_exists=0 external_exists=0
    local source_status="" target_status="" target_health=""
    local tun_exists=0 amnezia_net_exists=0 docker_ok=0

    source_container="$(effective_source_container "$service")"
    external_dir="$(service_external_dir "$service" "$AMNEZIA_DIR")"
    target_container="$(effective_target_container "$service")"

    docker_available && docker_ok=1
    [ -e /dev/net/tun ] && tun_exists=1
    [ -d "$external_dir" ] && external_exists=1

    if [ "$docker_ok" -eq 1 ] && container_exists "$source_container"; then
        source_exists=1
        source_status="$(container_summary_value "$source_container" status)"
    fi
    if [ -n "$target_container" ] && [ "$docker_ok" -eq 1 ] && container_exists "$target_container"; then
        target_exists=1
        target_status="$(container_summary_value "$target_container" status)"
        target_health="$(container_health "$target_container")"
    fi
    if [ "$docker_ok" -eq 1 ] && docker network inspect amnezia-dns-net >/dev/null 2>&1; then
        amnezia_net_exists=1
    fi

    missing_files="$(audit_required_files "$service" "$external_dir" "$source_container")"

    printf '{'
    printf '"service":"%s",' "$(json_escape "$service")"
    printf '"docker_available":%s,' "$(json_bool "$docker_ok")"
    printf '"source_container":{"name":"%s","exists":%s,"status":"%s"},' \
        "$(json_escape "$source_container")" "$(json_bool "$source_exists")" "$(json_escape "$source_status")"
    printf '"target_container":{"name":"%s","exists":%s,"status":"%s","health":"%s"},' \
        "$(json_escape "$target_container")" "$(json_bool "$target_exists")" "$(json_escape "$target_status")" "$(json_escape "$target_health")"
    printf '"externalized_dir":{"path":"%s","exists":%s},' "$(json_escape "$external_dir")" "$(json_bool "$external_exists")"
    printf '"missing_required_state":"%s",' "$(json_escape "$missing_files")"
    printf '"host":{"tun_visible":%s,"amnezia_dns_net_exists":%s}' "$(json_bool "$tun_exists")" "$(json_bool "$amnezia_net_exists")"
    printf '}'
}

audit_action() {
    local service first=1

    if [ "$JSON_OUTPUT" -eq 1 ]; then
        printf '{"services":['
        while IFS= read -r service; do
            [ "$first" -eq 1 ] || printf ','
            audit_service_json "$service"
            first=0
        done < <(service_list)
        printf ']}\n'
        return
    fi

    if ! docker_available; then
        warn "Docker daemon is not reachable; audit will report filesystem/default checks only."
    fi

    while IFS= read -r service; do
        audit_service_text "$service"
    done < <(service_list)
}

timestamp_utc() {
    date -u +%Y%m%dT%H%M%SZ
}

prepare_snapshot_path() {
    local ts
    ts="$(timestamp_utc)"
    SNAPSHOT_PATH="$SNAPSHOT_DIR/$ts"
}

snapshot_tar_dir() {
    local source_dir="$1"
    local archive="$2"
    local parent base

    parent="$(dirname -- "$source_dir")"
    base="$(basename -- "$source_dir")"
    tar -C "$parent" -cf "$archive" "$base"
}

snapshot_container_path() {
    local container="$1"
    local container_path="$2"
    local archive="$3"
    local archive_name="$4"
    local tmpdir

    tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir"
    if docker cp "$container:$container_path/." "$tmpdir/$archive_name" >/dev/null 2>&1; then
        tar -C "$tmpdir" -cf "$archive" "$archive_name"
    fi
    rm -rf "$tmpdir"
}

write_snapshot_manifest() {
    local services="$1"
    local manifest="$SNAPSHOT_PATH/manifest.json"

    {
        printf '{\n'
        printf '  "created_at": "%s",\n' "$(timestamp_utc)"
        printf '  "version": 1,\n'
        printf '  "amnezia_dir": "%s",\n' "$(json_escape "$AMNEZIA_DIR")"
        printf '  "services": "%s"\n' "$(json_escape "$services")"
        printf '}\n'
    } >"$manifest"
}

snapshot_service() {
    local service="$1"
    local service_dir="$SNAPSHOT_PATH/$service"
    local source_container target_container external_dir source_path target_state_dir
    local escaped_repo_root escaped_snapshot_path

    source_container="$(effective_source_container "$service")"
    target_container="$(effective_target_container "$service")"
    external_dir="$(service_external_dir "$service" "$AMNEZIA_DIR")"
    source_path="$(service_container_path "$service")"
    target_state_dir="$(service_obscura_state_dir "$service")"

    mkdir -p "$service_dir"
    chmod 0700 "$service_dir"

    if docker_available && container_exists "$source_container"; then
        docker inspect "$source_container" >"$service_dir/source-container.inspect.json"
    fi
    if [ -n "$target_container" ] && docker_available && container_exists "$target_container"; then
        docker inspect "$target_container" >"$service_dir/target-container.inspect.json"
    fi

    if [ -d "$external_dir" ]; then
        snapshot_tar_dir "$external_dir" "$service_dir/source-state.tar"
    elif docker_available && container_exists "$source_container"; then
        snapshot_container_path "$source_container" "$source_path" "$service_dir/source-state.tar" "$(service_external_subdir "$service")"
    fi

    if [ -n "$target_container" ] && docker_available && container_exists "$target_container"; then
        snapshot_container_path "$target_container" "$target_state_dir" "$service_dir/target-state.tar" "target-state"
    fi

    escaped_repo_root="$(printf '%q' "$REPO_ROOT")"
    escaped_snapshot_path="$(printf '%q' "$SNAPSHOT_PATH")"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -euo pipefail\n'
        printf 'bash %s/scripts/obscura.sh migrate rollback --service %s --snapshot %s\n' "$escaped_repo_root" "$service" "$escaped_snapshot_path"
    } >"$service_dir/restore.sh"
    chmod 0700 "$service_dir/restore.sh"

    : >"$service_dir/sha256sums.txt"
    while IFS= read -r checksum_file; do
        sha256_file "$checksum_file" >>"$service_dir/sha256sums.txt"
    done < <(find "$service_dir" -type f ! -name sha256sums.txt)
}

snapshot_action() {
    local services=""
    local service

    if [ "$DRY_RUN" -eq 1 ]; then
        prepare_snapshot_path
        log "DRY-RUN: would create snapshot: $SNAPSHOT_PATH"
        while IFS= read -r service; do
            log "DRY-RUN: would snapshot service: $service"
        done < <(service_list)
        return
    fi

    require_root_or_allowed
    require_cmd tar
    prepare_snapshot_path
    mkdir -p "$SNAPSHOT_PATH"
    chmod 0700 "$SNAPSHOT_PATH"

    while IFS= read -r service; do
        services="${services}${services:+ }$service"
        snapshot_service "$service"
    done < <(service_list)

    write_snapshot_manifest "$services"
    log "Snapshot created: $SNAPSHOT_PATH"
}

migrate_action() {
    local service="$SERVICE"
    local source_container target_container external_dir snapshot_path_for_run
    local externalize_script import_script

    source_container="$(effective_source_container "$service")"
    target_container="$(effective_target_container "$service")"
    external_dir="$(service_external_dir "$service" "$AMNEZIA_DIR")"

    if [ "$DRY_RUN" -eq 1 ]; then
        audit_action
        log "DRY-RUN: would snapshot $service"
        log "DRY-RUN: would externalize $source_container into $external_dir"
        if [ "$service" = "xray" ] || [ "$service" = "awg" ]; then
            log "DRY-RUN: would import $external_dir and apply to ${target_container:-auto-detected target}"
        else
            log "DRY-RUN: would verify SOCKS5 compatibility render from $external_dir/conf/3proxy.cfg"
        fi
        return
    fi

    require_root_or_allowed
    confirm_or_die "$YES" "Migrate $service from $source_container to Obscura-compatible state?"

    audit_action
    snapshot_action
    snapshot_path_for_run="$SNAPSHOT_PATH"

    externalize_script="$(service_externalize_script "$service")"
    bash "$externalize_script" --container "$source_container" --data-dir "$external_dir" --force

    if [ "$service" = "xray" ] || [ "$service" = "awg" ]; then
        import_script="$(service_import_script "$service")"
        if [ -n "$target_container" ]; then
            bash "$import_script" --source-dir "$external_dir" --state-dir "$external_dir" --target-container "$target_container" --apply-live --force
        else
            warn "No running Obscura $service target container found; importing to $external_dir without live apply."
            bash "$import_script" --source-dir "$external_dir" --state-dir "$external_dir" --force
        fi
    else
        [ -s "$external_dir/conf/3proxy.cfg" ] || die "SOCKS5 externalized config missing: $external_dir/conf/3proxy.cfg"
    fi

    SNAPSHOT_PATH="$snapshot_path_for_run"
    verify_action
}

verify_xray() {
    local target_container="$1"
    local external_dir="$2"
    local metadata="$external_dir/import-metadata.json"
    local expected="" live="" bootstrap_id="" tmpdir=""

    for file_name in server.json xray_uuid.key xray_short_id.key xray_public.key xray_private.key; do
        [ -s "$external_dir/$file_name" ] || die "missing Xray state file: $external_dir/$file_name"
    done

    if [ -z "$target_container" ]; then
        [ "$JSON_OUTPUT" -eq 1 ] || log "Xray state files verified; no running target container found."
        return
    fi

    container_running "$target_container" || die "target Xray container is not running: $target_container"
    case "$(container_health "$target_container")" in
        healthy|none) ;;
        *) die "target Xray container is not healthy: $target_container" ;;
    esac

    if [ -s "$metadata" ]; then
        expected="$("${PYTHON_BIN:-python3}" -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("client_count",""))' "$metadata" 2>/dev/null || true)"
        live="$(docker exec "$target_container" sh -lc "grep -c '\"id\"[[:space:]]*:' /opt/amnezia/xray/clients.json" 2>/dev/null || true)"
        [ -z "$expected" ] || [ "$expected" = "$live" ] || die "target Xray client count ($live) does not match imported count ($expected)"
    fi

    bootstrap_id="$(docker exec "$target_container" sh -lc 'cat /opt/amnezia/xray/xray_uuid.key')"
    tmpdir="$(mktemp -d)"
    bash scripts/manage-xray-clients.sh export --container "$target_container" --client-id "$bootstrap_id" --server-host 127.0.0.1 --output "$tmpdir/xray-client.json" >/dev/null
    rm -rf "$tmpdir"

    if [ "$WITH_FLOW" -eq 1 ]; then
        bash scripts/test-xray-host.sh --container "$target_container"
    fi

    [ "$JSON_OUTPUT" -eq 1 ] || log "Xray verification passed."
}

verify_awg() {
    local target_container="$1"
    local external_dir="$2"
    local metadata="$external_dir/import-metadata.json"
    local expected="" live="" interface="awg0" tmpdir=""

    for file_name in awg0.conf wireguard_server_private_key.key wireguard_server_public_key.key wireguard_psk.key; do
        [ -s "$external_dir/$file_name" ] || die "missing AWG state file: $external_dir/$file_name"
    done

    if [ -z "$target_container" ]; then
        [ "$JSON_OUTPUT" -eq 1 ] || log "AWG state files verified; no running target container found."
        return
    fi

    container_running "$target_container" || die "target AWG container is not running: $target_container"
    case "$(container_health "$target_container")" in
        healthy|none) ;;
        *) die "target AWG container is not healthy: $target_container" ;;
    esac

    if [ -s "$metadata" ]; then
        expected="$("${PYTHON_BIN:-python3}" -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("client_count",""))' "$metadata" 2>/dev/null || true)"
        interface="$(docker exec "$target_container" sh -lc 'python3 -c "import json; print(json.load(open(\"/opt/amnezia/awg/settings.json\", encoding=\"utf-8\")).get(\"interface\", \"awg0\"))"' 2>/dev/null || printf awg0)"
        live="$(docker exec "$target_container" sh -lc "awg show '$interface' peers | wc -l | tr -d '[:space:]'" 2>/dev/null || true)"
        [ -z "$expected" ] || [ "$expected" = "$live" ] || die "target AWG peer count ($live) does not match imported count ($expected)"
    fi

    tmpdir="$(mktemp -d)"
    if bash scripts/manage-awg-clients.sh export --container "$target_container" --name imported-1 --server-host 127.0.0.1 --output "$tmpdir/imported-client.conf" >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        die "imported AWG peer without private key was exportable"
    fi
    rm -rf "$tmpdir"

    if [ "$WITH_TUNNEL" -eq 1 ]; then
        bash scripts/test-awg-host.sh --container "$target_container"
    fi

    [ "$JSON_OUTPUT" -eq 1 ] || log "AWG verification passed."
}

verify_socks5proxy() {
    local external_dir="$1"
    local tmp_container="obscura-socks5-verify-$$"
    local config_dir="$external_dir/conf"

    [ -s "$config_dir/3proxy.cfg" ] || die "missing SOCKS5 config: $config_dir/3proxy.cfg"

    if docker_available && [ "${OBSCURA_SKIP_DOCKER_VERIFY:-0}" != "1" ]; then
        if ! docker image inspect obscura-socks5proxy >/dev/null 2>&1; then
            docker compose --profile socks5proxy build socks5proxy >/dev/null
        fi
        docker rm -f "$tmp_container" >/dev/null 2>&1 || true
        if ! {
            MSYS_NO_PATHCONV=1 docker run -d --name "$tmp_container" \
                -e SOCKS5_COMPAT_CONFIG=/compat/3proxy.cfg \
                -e SOCKS5_DNS_SERVERS=1.1.1.1 \
                -v "$(host_path_for_docker "$config_dir"):/compat:ro" \
                obscura-socks5proxy >/dev/null
            sleep 2
            MSYS_NO_PATHCONV=1 docker exec "$tmp_container" sh -lc "
                grep -q '^auth ' /usr/local/3proxy/conf/3proxy.cfg
                grep -q '^socks .* -p1080 ' /usr/local/3proxy/conf/3proxy.cfg || grep -q '^socks -p1080 ' /usr/local/3proxy/conf/3proxy.cfg
            "
        }; then
            docker rm -f "$tmp_container" >/dev/null 2>&1 || true
            die "SOCKS5 compatibility render verification failed"
        fi
        docker rm -f "$tmp_container" >/dev/null 2>&1 || true
    fi

    [ "$JSON_OUTPUT" -eq 1 ] || log "SOCKS5 compatibility verification passed."
}

verify_action() {
    local service="$SERVICE"
    local target_container external_dir

    target_container="$(effective_target_container "$service")"
    external_dir="$(service_external_dir "$service" "$AMNEZIA_DIR")"

    case "$service" in
        xray) verify_xray "$target_container" "$external_dir" ;;
        awg) verify_awg "$target_container" "$external_dir" ;;
        socks5proxy) verify_socks5proxy "$external_dir" ;;
        *) die "unsupported service for verify: $service" ;;
    esac

    if [ "$JSON_OUTPUT" -eq 1 ]; then
        printf '{"service":"%s","ok":true}\n' "$(json_escape "$service")"
    fi
}

restore_source_state() {
    local service="$1"
    local archive="$SNAPSHOT_PATH/$service/source-state.tar"
    local external_dir
    local parent backup_current

    [ -s "$archive" ] || return 0
    external_dir="$(service_external_dir "$service" "$AMNEZIA_DIR")"
    safe_restore_path "$external_dir" || die "refusing to restore unsafe path: $external_dir"
    parent="$(dirname -- "$external_dir")"
    mkdir -p "$parent"

    if [ -e "$external_dir" ]; then
        backup_current="${external_dir}.pre-rollback-$(timestamp_utc)"
        mv "$external_dir" "$backup_current"
        warn "Moved current state aside: $backup_current"
    fi

    tar -C "$parent" -xf "$archive"
}

restore_target_state() {
    local service="$1"
    local target_container="$2"
    local archive="$SNAPSHOT_PATH/$service/target-state.tar"
    local state_dir tmpdir

    [ -n "$target_container" ] || return 0
    [ -s "$archive" ] || return 0
    container_exists "$target_container" || return 0

    state_dir="$(service_obscura_state_dir "$service")"
    tmpdir="$(mktemp -d)"
    tar -C "$tmpdir" -xf "$archive"
    docker exec "$target_container" sh -lc "mkdir -p '$state_dir' && find '$state_dir' -mindepth 1 -maxdepth 1 -exec rm -rf {} +"
    docker cp "$(host_path_for_docker "$tmpdir/target-state")/." "$target_container:$state_dir/"
    docker restart "$target_container" >/dev/null
    rm -rf "$tmpdir"
}

restore_source_container() {
    local source_container="$1"
    local backup_container

    docker_available || return 0
    backup_container="$(latest_backup_container "$source_container")"
    if [ -z "$backup_container" ]; then
        warn "No preserved backup container found for $source_container. Recreate manually from snapshot inspect JSON if needed."
        return 0
    fi

    if container_exists "$source_container"; then
        docker rm -f "$source_container" >/dev/null
    fi
    docker rename "$backup_container" "$source_container"
    docker start "$source_container" >/dev/null || true
    log "Restored source container from preserved backup: $backup_container -> $source_container"
}

rollback_action() {
    local service="$SERVICE"
    local source_container target_container

    [ -n "$SNAPSHOT_PATH" ] || die "rollback requires --snapshot <path>"
    [ -d "$SNAPSHOT_PATH" ] || die "snapshot not found: $SNAPSHOT_PATH"

    source_container="$(effective_source_container "$service")"
    target_container="$(effective_target_container "$service")"

    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN: would restore $service from snapshot: $SNAPSHOT_PATH"
        log "DRY-RUN: would restore source state under $(service_external_dir "$service" "$AMNEZIA_DIR")"
        log "DRY-RUN: would restore source container $source_container from latest preserved backup if present"
        [ -n "$target_container" ] && log "DRY-RUN: would restore target state in $target_container"
        return 0
    fi

    require_root_or_allowed
    confirm_or_die "$YES" "Rollback $service using snapshot $SNAPSHOT_PATH?"

    restore_target_state "$service" "$target_container"
    restore_source_state "$service"
    restore_source_container "$source_container"

    log "Rollback completed for $service. Running post-rollback audit."
    audit_service_text "$service"
}

main() {
    cd "$REPO_ROOT"
    parse_args "$@"

    case "$ACTION" in
        audit) audit_action ;;
        snapshot) snapshot_action ;;
        migrate) migrate_action ;;
        verify) verify_action ;;
        rollback) rollback_action ;;
    esac
}

main "$@"
