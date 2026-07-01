#!/usr/bin/env bash
set -euo pipefail

DEFAULT_SOURCE_CONTAINER="amnezia-awg"
DEFAULT_SOURCE_CONTAINER_PATH="/opt/amnezia/awg"
DEFAULT_STATE_DIR="/srv/amnezia/awg"
DEFAULT_SERVICE_LABEL="com.docker.compose.service=awg"
DEFAULT_PROJECT_LABEL="com.docker.compose.project=obscura"
DEFAULT_CONTAINER_NUMBER_LABEL="com.docker.compose.container-number=1"
DEFAULT_TARGET_STATE_DIR="/var/lib/obscura/awg"
DEFAULT_RESTART_TIMEOUT="${AWG_IMPORT_RESTART_TIMEOUT:-30}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

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
Usage: import-amnezia-awg.sh [options]

Import an existing Amnezia-style AWG state layout into Obscura's structured
state model.

The script can import from:
  - a running container that exposes /opt/amnezia/awg
  - an existing host directory with the same file layout

It normalizes the source into:
  - preserved AWG key files
  - imported source awg0.conf
  - clients.json derived from [Peer] blocks
  - import-metadata.json

Options:
  --source-container <name>        Import from a container, default amnezia-awg
  --source-dir <path>              Import from an existing host directory
  --source-container-path <path>   Path inside source container, default /opt/amnezia/awg
  --state-dir <path>               Host output directory, default /srv/amnezia/awg
  --target-container <name>        Explicit Obscura awg container for --apply-live
  --target-state-dir <path>        Target state dir inside Obscura awg container
  --apply-live                     Copy imported state into the live Obscura awg container and restart it
  --force                          Allow overwriting a non-empty output directory
  --restart-timeout <sec>          Live apply health timeout, default 30
  -h, --help                       Show this help

Examples:
  sudo bash scripts/import-amnezia-awg.sh
  sudo bash scripts/import-amnezia-awg.sh --source-dir /srv/amnezia/awg --force
  sudo bash scripts/import-amnezia-awg.sh --source-container amnezia-awg --apply-live
EOF
}

log() {
    printf '%s\n' "$*"
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

validate_numeric() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 0 ]
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --source-container)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --source-container\n' >&2; exit 1; }
                SOURCE_CONTAINER="$2"
                shift 2
                ;;
            --source-dir)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --source-dir\n' >&2; exit 1; }
                SOURCE_DIR="$2"
                shift 2
                ;;
            --source-container-path)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --source-container-path\n' >&2; exit 1; }
                SOURCE_CONTAINER_PATH="$2"
                shift 2
                ;;
            --state-dir)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --state-dir\n' >&2; exit 1; }
                STATE_DIR="$2"
                shift 2
                ;;
            --target-container)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --target-container\n' >&2; exit 1; }
                TARGET_CONTAINER="$2"
                shift 2
                ;;
            --target-state-dir)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --target-state-dir\n' >&2; exit 1; }
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
            --restart-timeout)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --restart-timeout\n' >&2; exit 1; }
                RESTART_TIMEOUT="$2"
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

    if ! validate_numeric "$RESTART_TIMEOUT"; then
        printf 'ERROR: invalid --restart-timeout value: %s\n' "$RESTART_TIMEOUT" >&2
        exit 1
    fi
}

prepare_tmpdir() {
    TMPDIR="$(mktemp -d)"
    STAGE_DIR="$TMPDIR/stage"
    IMPORT_METADATA_JSON="$STAGE_DIR/import-metadata.json"
    mkdir -p "$STAGE_DIR"
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
        log "Importing AWG state from host directory: $SOURCE_DIR"
    else
        copy_func="copy_required_file_from_container"
        log "Importing AWG state from container: $SOURCE_CONTAINER:$SOURCE_CONTAINER_PATH"
    fi

    for file_name in awg0.conf wireguard_server_private_key.key wireguard_server_public_key.key wireguard_psk.key; do
        "$copy_func" "$file_name" "$file_name" || {
            printf 'ERROR: failed to copy required source file: %s\n' "$file_name" >&2
            exit 1
        }

        if [ ! -s "$STAGE_DIR/$file_name" ]; then
            printf 'ERROR: copied source file is empty: %s\n' "$file_name" >&2
            exit 1
        fi
    done
}

normalize_imported_state() {
    "$PYTHON_BIN" - \
        "$STAGE_DIR/awg0.conf" \
        "$STAGE_DIR/wireguard_server_public_key.key" \
        "$STAGE_DIR/clients.json" \
        "$IMPORT_METADATA_JSON" <<'PY'
import json
import re
import sys

server_conf, public_key_path, clients_out, metadata_out = sys.argv[1:5]

interface = {}
clients = []
current_section = None
current_peer = None

def finish_peer():
    global current_peer
    if not current_peer:
        return
    public_key = current_peer.get("PublicKey", "").strip()
    if public_key:
        allowed_ips = current_peer.get("AllowedIPs", "").strip()
        first_address = allowed_ips.split(",", 1)[0].strip() if allowed_ips else ""
        clients.append({
            "name": f"imported-{len(clients) + 1}",
            "public_key": public_key,
            "private_key": "",
            "address": first_address,
            "allowed_ips": allowed_ips,
            "preshared_key": current_peer.get("PresharedKey", "").strip(),
            "persistent_keepalive": current_peer.get("PersistentKeepalive", "").strip() or "25",
            "enabled": True,
            "exportable": False,
            "source": "amnezia-import",
        })
    current_peer = None

with open(server_conf, "r", encoding="utf-8") as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            finish_peer()
            current_section = line[1:-1].strip().lower()
            current_peer = {} if current_section == "peer" else None
            continue
        if "=" not in line:
            continue
        key, value = [part.strip() for part in line.split("=", 1)]
        if current_section == "interface":
            interface[key] = value
        elif current_section == "peer" and current_peer is not None:
            current_peer[key] = value
finish_peer()

if "PrivateKey" not in interface:
    raise SystemExit("ERROR: source awg0.conf does not contain Interface PrivateKey")
if "Address" not in interface:
    raise SystemExit("ERROR: source awg0.conf does not contain Interface Address")

with open(public_key_path, "r", encoding="utf-8") as fh:
    server_public_key = fh.read().strip()

metadata = {
    "source_server_address": interface.get("Address", ""),
    "source_server_port": interface.get("ListenPort", ""),
    "source_server_public_key_present": bool(server_public_key),
    "client_count": len(clients),
    "awg_obfuscation": {
        key: interface.get(key, "")
        for key in ("Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4", "I1", "I2", "I3", "I4", "I5")
    },
}

with open(clients_out, "w", encoding="utf-8") as fh:
    json.dump(clients, fh, indent=2)
    fh.write("\n")

with open(metadata_out, "w", encoding="utf-8") as fh:
    json.dump(metadata, fh, indent=2)
    fh.write("\n")
PY
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
        awg0.conf \
        clients.json \
        import-metadata.json \
        wireguard_server_private_key.key \
        wireguard_server_public_key.key \
        wireguard_psk.key; do
        cp "$STAGE_DIR/$file_name" "$STATE_DIR/$file_name"
    done

    chmod 0600 \
        "$STATE_DIR/awg0.conf" \
        "$STATE_DIR/clients.json" \
        "$STATE_DIR/import-metadata.json" \
        "$STATE_DIR/wireguard_server_private_key.key" \
        "$STATE_DIR/wireguard_server_public_key.key" \
        "$STATE_DIR/wireguard_psk.key"
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
        printf 'ERROR: no running Obscura awg container found for --apply-live\n' >&2
        exit 1
    fi
}

write_live_target_state() {
    local file_name

    for file_name in \
        awg0.conf \
        clients.json \
        import-metadata.json \
        wireguard_server_private_key.key \
        wireguard_server_public_key.key \
        wireguard_psk.key; do
        docker exec -i "$TARGET_CONTAINER" sh -lc "umask 077 && cat > '$TARGET_STATE_DIR/$file_name'" <"$STAGE_DIR/$file_name"
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

verify_live_peer_count() {
    local expected_count
    local interface
    local live_count

    expected_count="$("$PYTHON_BIN" -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("client_count", 0))' "$IMPORT_METADATA_JSON")"
    interface="$(docker exec "$TARGET_CONTAINER" sh -lc 'python3 -c "import json; print(json.load(open(\"/opt/amnezia/awg/settings.json\", encoding=\"utf-8\")).get(\"interface\", \"awg0\"))"')"
    live_count="$(docker exec "$TARGET_CONTAINER" sh -lc "awg show '$interface' peers | wc -l" | tr -d '[:space:]')"

    if [ "$live_count" != "$expected_count" ]; then
        printf 'ERROR: live AWG peer count (%s) does not match imported peer count (%s)\n' "$live_count" "$expected_count" >&2
        exit 1
    fi
}

apply_live_target() {
    discover_target_container
    write_live_target_state
    docker restart "$TARGET_CONTAINER" >/dev/null
    wait_for_healthy_target
    verify_live_peer_count
}

print_summary() {
    local source_desc

    if [ -n "$SOURCE_DIR" ]; then
        source_desc="$SOURCE_DIR"
    else
        source_desc="$SOURCE_CONTAINER:$SOURCE_CONTAINER_PATH"
    fi

    log "Imported Amnezia-style AWG state:"
    log "  source: $source_desc"
    log "  output dir: $STATE_DIR"

    "$PYTHON_BIN" - "$IMPORT_METADATA_JSON" <<'PY'
import json
import sys

metadata = json.load(open(sys.argv[1], encoding="utf-8"))
print(f"  imported server address: {metadata.get('source_server_address', '')}")
print(f"  imported server port: {metadata.get('source_server_port', '')}")
print(f"  imported client count: {metadata.get('client_count', '')}")
PY

    if [ "$APPLY_LIVE" -eq 1 ]; then
        log "  live apply target: $TARGET_CONTAINER"
    fi
}

main() {
    trap cleanup EXIT

    parse_args "$@"
    require_cmd docker
    require_cmd "$PYTHON_BIN"

    prepare_tmpdir
    validate_source_selection
    require_source
    copy_source_state
    normalize_imported_state
    prepare_output_dir
    write_output_dir

    if [ "$APPLY_LIVE" -eq 1 ]; then
        apply_live_target
    fi

    print_summary
}

main "$@"
