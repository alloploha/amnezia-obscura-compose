#!/usr/bin/env bash
set -euo pipefail

DEFAULT_SOURCE_CONTAINER="amnezia-xray"
DEFAULT_SOURCE_CONTAINER_PATH="/opt/amnezia/xray"
DEFAULT_STATE_DIR="/srv/amnezia/xray"
DEFAULT_SERVICE_LABEL="com.docker.compose.service=xray"
DEFAULT_PROJECT_LABEL="com.docker.compose.project=obscura"
DEFAULT_CONTAINER_NUMBER_LABEL="com.docker.compose.container-number=1"
DEFAULT_TARGET_STATE_DIR="/var/lib/obscura/xray"
DEFAULT_CLIENT_FLOW="xtls-rprx-vision"
DEFAULT_RESTART_TIMEOUT="${XRAY_IMPORT_RESTART_TIMEOUT:-30}"

SOURCE_CONTAINER="$DEFAULT_SOURCE_CONTAINER"
SOURCE_CONTAINER_PATH="$DEFAULT_SOURCE_CONTAINER_PATH"
SOURCE_DIR=""
STATE_DIR="$DEFAULT_STATE_DIR"
TARGET_CONTAINER=""
TARGET_STATE_DIR="$DEFAULT_TARGET_STATE_DIR"
APPLY_LIVE=0
FORCE=0
RESTART_TIMEOUT="$DEFAULT_RESTART_TIMEOUT"

TMPDIR=""
STAGE_DIR=""
IMPORT_METADATA_JSON=""

usage() {
    cat <<'EOF'
Usage: import-amnezia-xray.sh [options]

Import an existing Amnezia-style Xray state layout into Obscura's structured
state model.

The script can import from:
  - a running container that exposes /opt/amnezia/xray
  - an existing host directory with the same file layout

Preferred migration flow:
  1. externalize a live vanilla Amnezia Xray container to /srv/amnezia/xray
     with scripts/externalize-amnezia-xray.sh
  2. run this import script against that host directory or the externalized
     container state

It normalizes the source into:
  - clients.json
  - client.template.json
  - import-metadata.json
  - preserved key files and server.json

By default it writes that imported state to:
  /srv/amnezia/xray

With --apply-live it also copies the imported state into the running Obscura
Xray service and restarts that service. Live apply is intentionally strict:
the running Obscura Xray server port and site name must already match the
imported Amnezia state, otherwise the script fails with a clear message.

Options:
  --source-container <name>        Import from a container, default amnezia-xray
  --source-dir <path>              Import from an existing host directory
  --source-container-path <path>   Path inside source container, default /opt/amnezia/xray
  --state-dir <path>               Host output directory, default /srv/amnezia/xray
  --target-container <name>        Explicit Obscura xray container for --apply-live
  --target-state-dir <path>        Target state dir inside Obscura xray container
  --apply-live                     Copy imported state into the live Obscura xray container and restart it
  --force                          Allow overwriting a non-empty output directory
  -h, --help                       Show this help

Examples:
  sudo bash scripts/import-amnezia-xray.sh
  sudo bash scripts/import-amnezia-xray.sh --source-dir /srv/amnezia/xray
  sudo bash scripts/import-amnezia-xray.sh --source-container amnezia-xray --apply-live
EOF
}

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'WARN: %s\n' "$*" >&2
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
            --source-container)
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --source-container\n' >&2
                    exit 1
                }
                SOURCE_CONTAINER="$2"
                shift 2
                ;;
            --source-dir)
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --source-dir\n' >&2
                    exit 1
                }
                SOURCE_DIR="$2"
                shift 2
                ;;
            --source-container-path)
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --source-container-path\n' >&2
                    exit 1
                }
                SOURCE_CONTAINER_PATH="$2"
                shift 2
                ;;
            --state-dir)
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --state-dir\n' >&2
                    exit 1
                }
                STATE_DIR="$2"
                shift 2
                ;;
            --target-container)
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --target-container\n' >&2
                    exit 1
                }
                TARGET_CONTAINER="$2"
                shift 2
                ;;
            --target-state-dir)
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --target-state-dir\n' >&2
                    exit 1
                }
                TARGET_STATE_DIR="$2"
                shift 2
                ;;
            --apply-live)
                APPLY_LIVE=1
                shift
                ;;
            --force)
                FORCE=1
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

prepare_tmpdir() {
    TMPDIR="$(mktemp -d)"
    STAGE_DIR="$TMPDIR/stage"
    mkdir -p "$STAGE_DIR"
    IMPORT_METADATA_JSON="$STAGE_DIR/import-metadata.json"
}

validate_source_selection() {
    if [ -n "$SOURCE_DIR" ] && [ "$SOURCE_CONTAINER" != "$DEFAULT_SOURCE_CONTAINER" ]; then
        printf 'ERROR: use either --source-dir or --source-container, not both\n' >&2
        exit 1
    fi
}

require_source() {
    if [ -n "$SOURCE_DIR" ]; then
        [ -d "$SOURCE_DIR" ] || {
            printf 'ERROR: source directory not found: %s\n' "$SOURCE_DIR" >&2
            exit 1
        }
    else
        docker inspect "$SOURCE_CONTAINER" >/dev/null 2>&1 || {
            printf 'ERROR: source container not found: %s\n' "$SOURCE_CONTAINER" >&2
            exit 1
        }
    fi
}

copy_required_file_from_container() {
    local source_name="$1"
    local target_name="$2"

    docker exec "$SOURCE_CONTAINER" sh -lc "cat '$SOURCE_CONTAINER_PATH/$source_name'" >"$STAGE_DIR/$target_name"
}

copy_required_file_from_dir() {
    local source_name="$1"
    local target_name="$2"

    cp "$SOURCE_DIR/$source_name" "$STAGE_DIR/$target_name"
}

copy_source_state() {
    local copy_func
    local file_name

    if [ -n "$SOURCE_DIR" ]; then
        copy_func="copy_required_file_from_dir"
        log "Importing Xray state from host directory: $SOURCE_DIR"
    else
        copy_func="copy_required_file_from_container"
        log "Importing Xray state from container: $SOURCE_CONTAINER:$SOURCE_CONTAINER_PATH"
    fi

    for file_name in server.json xray_uuid.key xray_short_id.key xray_public.key xray_private.key; do
        "$copy_func" "$file_name" "$file_name" || {
            printf 'ERROR: failed to copy required source file: %s\n' "$file_name" >&2
            exit 1
        }
    done
}

normalize_imported_state() {
    python3 - \
        "$STAGE_DIR/server.json" \
        "$STAGE_DIR/xray_uuid.key" \
        "$STAGE_DIR/clients.json" \
        "$IMPORT_METADATA_JSON" \
        "$DEFAULT_CLIENT_FLOW" <<'EOF'
import json
import sys

server_path, bootstrap_path, clients_out, metadata_out, default_flow = sys.argv[1:6]

with open(server_path, "r", encoding="utf-8") as fh:
    server = json.load(fh)

with open(bootstrap_path, "r", encoding="utf-8") as fh:
    bootstrap_id = fh.read().strip()

inbound = None
for candidate in server.get("inbounds", []):
    if candidate.get("protocol") == "vless":
        inbound = candidate
        break

if inbound is None:
    raise SystemExit("ERROR: could not find a VLESS inbound in source server.json")

settings = inbound.get("settings", {})
clients = []
for client in settings.get("clients", []):
    client_id = (client.get("id") or "").strip()
    if not client_id:
        continue
    flow = (client.get("flow") or default_flow).strip() or default_flow
    clients.append({
        "id": client_id,
        "flow": flow,
    })

if not clients:
    raise SystemExit("ERROR: source server.json did not contain any usable clients")

reality = inbound.get("streamSettings", {}).get("realitySettings", {})
server_names = reality.get("serverNames") or []
site_name = ""
if server_names:
    site_name = (server_names[0] or "").strip()

metadata = {
    "source_server_port": inbound.get("port"),
    "source_listen_addr": inbound.get("listen", ""),
    "source_log_level": server.get("log", {}).get("loglevel", ""),
    "source_site_name": site_name,
    "bootstrap_client_id": bootstrap_id,
    "client_count": len(clients),
}

with open(clients_out, "w", encoding="utf-8") as fh:
    json.dump(clients, fh, indent=2)
    fh.write("\n")

with open(metadata_out, "w", encoding="utf-8") as fh:
    json.dump(metadata, fh, indent=2)
    fh.write("\n")
EOF
}

render_imported_client_template() {
    local bootstrap_flow

    bootstrap_flow="$(
        python3 - "$STAGE_DIR/clients.json" "$STAGE_DIR/xray_uuid.key" "$DEFAULT_CLIENT_FLOW" <<'EOF'
import json
import sys

clients_path, bootstrap_path, default_flow = sys.argv[1:4]

with open(clients_path, "r", encoding="utf-8") as fh:
    clients = json.load(fh)
with open(bootstrap_path, "r", encoding="utf-8") as fh:
    bootstrap_id = fh.read().strip()

for client in clients:
    if client.get("id") == bootstrap_id and client.get("flow"):
        print(client["flow"])
        break
else:
    if clients and clients[0].get("flow"):
        print(clients[0]["flow"])
    else:
        print(default_flow)
EOF
    )"

    sed "s|__XRAY_CLIENT_FLOW__|$bootstrap_flow|g" xray/client.template.json >"$STAGE_DIR/client.template.json"
}

prepare_output_dir() {
    mkdir -p "$STATE_DIR"

    if [ "$FORCE" -eq 0 ] && find "$STATE_DIR" -mindepth 1 -print -quit | grep -q .; then
        printf 'ERROR: output directory is not empty: %s\n' "$STATE_DIR" >&2
        printf 'ERROR: use --force to allow overwriting the imported state files\n' >&2
        exit 1
    fi
}

write_output_dir() {
    local file_name

    for file_name in \
        server.json \
        clients.json \
        client.template.json \
        import-metadata.json \
        xray_uuid.key \
        xray_short_id.key \
        xray_public.key \
        xray_private.key; do
        cp "$STAGE_DIR/$file_name" "$STATE_DIR/$file_name"
    done

    chmod 0600 \
        "$STATE_DIR/server.json" \
        "$STATE_DIR/clients.json" \
        "$STATE_DIR/import-metadata.json" \
        "$STATE_DIR/xray_uuid.key" \
        "$STATE_DIR/xray_short_id.key" \
        "$STATE_DIR/xray_public.key" \
        "$STATE_DIR/xray_private.key"
    chmod 0644 "$STATE_DIR/client.template.json"
}

discover_target_container() {
    if [ -n "$TARGET_CONTAINER" ]; then
        return
    fi

    TARGET_CONTAINER="$(
        docker ps \
            --filter "label=$DEFAULT_PROJECT_LABEL" \
            --filter "label=$DEFAULT_SERVICE_LABEL" \
            --filter "label=$DEFAULT_CONTAINER_NUMBER_LABEL" \
            --format '{{.Names}}' \
            | head -n 1
    )"

    if [ -z "$TARGET_CONTAINER" ]; then
        printf 'ERROR: no running Obscura xray container found for --apply-live\n' >&2
        exit 1
    fi
}

read_target_env_value() {
    local key="$1"

    docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$TARGET_CONTAINER" \
        | sed -n "s/^$key=//p" \
        | head -n 1
}

validate_live_target_settings() {
    local imported_port
    local imported_site
    local target_port
    local target_site

    imported_port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("source_server_port",""))' "$IMPORT_METADATA_JSON")"
    imported_site="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("source_site_name",""))' "$IMPORT_METADATA_JSON")"

    target_port="$(read_target_env_value XRAY_SERVER_PORT)"
    target_site="$(read_target_env_value XRAY_SITE_NAME)"

    if [ -z "$target_port" ]; then
        target_port="$(docker exec "$TARGET_CONTAINER" sh -lc "sed -n 's/.*\"port\":[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p' /opt/amnezia/xray/server.json | head -n 1")"
    fi
    if [ -z "$target_site" ]; then
        target_site="$(docker exec "$TARGET_CONTAINER" sh -lc "awk '/\"serverNames\"[[:space:]]*:/ {getline; if (match(\\$0, /\"[^\"]+\"/)) { value = substr(\\$0, RSTART + 1, RLENGTH - 2); print value; exit }}' /opt/amnezia/xray/server.json")"
    fi

    if [ -n "$imported_port" ] && [ -n "$target_port" ] && [ "$imported_port" != "$target_port" ]; then
        printf 'ERROR: imported Xray port (%s) does not match live Obscura Xray port (%s)\n' "$imported_port" "$target_port" >&2
        printf 'ERROR: recreate the Obscura xray service with XRAY_SERVER_PORT=%s before using --apply-live\n' "$imported_port" >&2
        exit 1
    fi

    if [ -n "$imported_site" ] && [ -n "$target_site" ] && [ "$imported_site" != "$target_site" ]; then
        printf 'ERROR: imported Xray site name (%s) does not match live Obscura Xray site name (%s)\n' "$imported_site" "$target_site" >&2
        printf 'ERROR: recreate the Obscura xray service with XRAY_SITE_NAME=%s before using --apply-live\n' "$imported_site" >&2
        exit 1
    fi
}

write_live_target_state() {
    local file_name

    for file_name in \
        server.json \
        clients.json \
        client.template.json \
        import-metadata.json \
        xray_uuid.key \
        xray_short_id.key \
        xray_public.key \
        xray_private.key; do
        docker exec -i "$TARGET_CONTAINER" sh -lc "umask 077 && cat > '$TARGET_STATE_DIR/$file_name'" <"$STAGE_DIR/$file_name"
        if [ "$file_name" = "client.template.json" ]; then
            docker exec "$TARGET_CONTAINER" sh -lc "chmod 0644 '$TARGET_STATE_DIR/$file_name'"
        fi
    done
}

wait_for_healthy_target() {
    local attempt
    local state
    local health

    for attempt in $(seq 1 "$RESTART_TIMEOUT"); do
        state="$(docker inspect --format '{{.State.Status}}' "$TARGET_CONTAINER")"
        health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$TARGET_CONTAINER")"

        if [ "$state" = "running" ] && { [ "$health" = "healthy" ] || [ "$health" = "none" ]; }; then
            return 0
        fi

        sleep 1
    done

    printf 'ERROR: target container %s did not become healthy after restart\n' "$TARGET_CONTAINER" >&2
    return 1
}

apply_live_target() {
    discover_target_container
    validate_live_target_settings
    write_live_target_state
    docker restart "$TARGET_CONTAINER" >/dev/null
    wait_for_healthy_target
}

print_summary() {
    local source_desc

    if [ -n "$SOURCE_DIR" ]; then
        source_desc="$SOURCE_DIR"
    else
        source_desc="$SOURCE_CONTAINER:$SOURCE_CONTAINER_PATH"
    fi

    log "Imported Amnezia-style Xray state:"
    log "  source: $source_desc"
    log "  output dir: $STATE_DIR"

    python3 - "$IMPORT_METADATA_JSON" <<'EOF'
import json
import sys

metadata = json.load(open(sys.argv[1], encoding="utf-8"))
print(f"  imported port: {metadata.get('source_server_port', '')}")
print(f"  imported site name: {metadata.get('source_site_name', '')}")
print(f"  imported client count: {metadata.get('client_count', '')}")
print(f"  bootstrap client id: {metadata.get('bootstrap_client_id', '')}")
EOF

    if [ "$APPLY_LIVE" -eq 1 ]; then
        log "  live apply target: $TARGET_CONTAINER"
    fi
}

main() {
    trap cleanup EXIT

    parse_args "$@"

    require_cmd docker
    require_cmd python3

    prepare_tmpdir
    validate_source_selection
    require_source
    copy_source_state
    normalize_imported_state
    render_imported_client_template
    prepare_output_dir
    write_output_dir

    if [ "$APPLY_LIVE" -eq 1 ]; then
        apply_live_target
    fi

    print_summary
}

main "$@"
