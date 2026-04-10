#!/usr/bin/env bash
set -euo pipefail

DEFAULT_SERVICE_LABEL="com.docker.compose.service=xray"
DEFAULT_PROJECT_LABEL="com.docker.compose.project=obscura"
DEFAULT_CONTAINER_NUMBER_LABEL="com.docker.compose.container-number=1"
DEFAULT_LOCAL_SOCKS_PORT="10808"
DEFAULT_CLIENT_FLOW="xtls-rprx-vision"
DEFAULT_RESTART_TIMEOUT="${XRAY_CLIENTS_RESTART_TIMEOUT:-30}"

COMMAND=""
CONTAINER_NAME=""
CLIENT_ID=""
CLIENT_FLOW=""
SERVER_HOST=""
OUTPUT_PATH="-"
LOCAL_SOCKS_PORT="$DEFAULT_LOCAL_SOCKS_PORT"
INCLUDE_BOOTSTRAP="false"
ALLOW_BOOTSTRAP_REMOVAL="false"
RESTART_TIMEOUT="$DEFAULT_RESTART_TIMEOUT"

TMPDIR=""
BOOTSTRAP_ID=""
SERVER_PORT=""
PUBLIC_KEY=""
SHORT_ID=""
SITE_NAME=""
CLIENT_TEMPLATE_PATH=""
CLIENTS_JSON_PATH=""
REGISTRY_MODE="local"
REGISTRY_SERVER_JSON_PATH=""

usage() {
    cat <<'EOF'
Usage: manage-xray-clients.sh <command> [options]

Manage the Obscura Xray client registry and export client configs.

Commands:
  list                      List configured clients
  add                       Add a client to the registry and restart Xray
  remove                    Remove a client from the registry and restart Xray
  export                    Export a concrete client config for one client

Options:
  --container <name>                Explicit xray container name
  --client-id <uuid|bootstrap>      Client UUID or the special bootstrap alias
  --flow <value>                    Client flow for add
  --server-host <host>              Server address for export
  --output <path|->                 Export destination, default stdout
  --local-socks-port <port>         Exported client local SOCKS port, default 10808
  --include-bootstrap               Include the bootstrap client in list output
  --allow-bootstrap-removal         Allow removing the bootstrap client
  -h, --help                        Show this help

Examples:
  sudo bash scripts/manage-xray-clients.sh list
  sudo bash scripts/manage-xray-clients.sh list --include-bootstrap
  sudo bash scripts/manage-xray-clients.sh add
  sudo bash scripts/manage-xray-clients.sh remove --client-id <uuid>
  sudo bash scripts/manage-xray-clients.sh export --client-id <uuid> --server-host vpn.example.com --output client.json
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

parse_args() {
    [ "$#" -gt 0 ] || {
        usage
        exit 1
    }

    case "$1" in
        list|add|remove|export)
            COMMAND="$1"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'ERROR: unknown command: %s\n' "$1" >&2
            usage
            exit 1
            ;;
    esac

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
            --client-id)
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --client-id\n' >&2
                    exit 1
                }
                CLIENT_ID="$2"
                shift 2
                ;;
            --flow)
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --flow\n' >&2
                    exit 1
                }
                CLIENT_FLOW="$2"
                shift 2
                ;;
            --server-host)
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --server-host\n' >&2
                    exit 1
                }
                SERVER_HOST="$2"
                shift 2
                ;;
            --output)
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --output\n' >&2
                    exit 1
                }
                OUTPUT_PATH="$2"
                shift 2
                ;;
            --local-socks-port)
                [ "$#" -ge 2 ] || {
                    printf 'ERROR: missing value for --local-socks-port\n' >&2
                    exit 1
                }
                LOCAL_SOCKS_PORT="$2"
                shift 2
                ;;
            --include-bootstrap)
                INCLUDE_BOOTSTRAP="true"
                shift
                ;;
            --allow-bootstrap-removal)
                ALLOW_BOOTSTRAP_REMOVAL="true"
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

validate_numeric_port() {
    case "$1" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
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
        printf 'ERROR: no running xray container found\n' >&2
        exit 1
    fi
}

require_running_server() {
    local state

    state="$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")"
    if [ "$state" != "running" ]; then
        printf 'ERROR: container %s is not running (state=%s)\n' "$CONTAINER_NAME" "$state" >&2
        exit 1
    fi
}

discover_paths() {
    CLIENTS_JSON_PATH="/var/lib/obscura/xray/clients.json"
    CLIENT_TEMPLATE_PATH="/var/lib/obscura/xray/client.template.json"

    REGISTRY_MODE="$(
        docker exec "$CONTAINER_NAME" sh -lc '
            if [ -n "${XRAY_COMPAT_STATE_DIR:-}" ] && [ -s "${XRAY_COMPAT_STATE_DIR}/server.json" ]; then
                printf compat
            else
                printf local
            fi
        '
    )"

    if [ "$REGISTRY_MODE" = "compat" ]; then
        REGISTRY_SERVER_JSON_PATH="$(
            docker exec "$CONTAINER_NAME" sh -lc 'printf "%s/server.json" "$XRAY_COMPAT_STATE_DIR"'
        )"
    fi
}

discover_server_port() {
    local port_lines

    port_lines="$(docker port "$CONTAINER_NAME" 443/tcp 2>/dev/null || true)"
    if [ -z "$port_lines" ]; then
        port_lines="$(docker port "$CONTAINER_NAME" 2>/dev/null || true)"
    fi

    SERVER_PORT="$(printf '%s\n' "$port_lines" | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -n 1)"
    if ! validate_numeric_port "$SERVER_PORT"; then
        printf 'ERROR: could not determine published Xray port for %s\n' "$CONTAINER_NAME" >&2
        exit 1
    fi
}

read_live_state() {
    BOOTSTRAP_ID="$(docker exec "$CONTAINER_NAME" sh -lc 'cat /opt/amnezia/xray/xray_uuid.key')"
    PUBLIC_KEY="$(docker exec "$CONTAINER_NAME" sh -lc 'cat /opt/amnezia/xray/xray_public.key')"
    SHORT_ID="$(docker exec "$CONTAINER_NAME" sh -lc 'cat /opt/amnezia/xray/xray_short_id.key')"
    SITE_NAME="$(
        docker exec "$CONTAINER_NAME" sh -lc \
            "awk '/\"serverNames\"[[:space:]]*:/ {getline; if (match(\$0, /\"[^\"]+\"/)) { value = substr(\$0, RSTART + 1, RLENGTH - 2); print value; exit }}' /opt/amnezia/xray/server.json"
    )"

    if [ -z "$BOOTSTRAP_ID" ] || [ -z "$PUBLIC_KEY" ] || [ -z "$SHORT_ID" ] || [ -z "$SITE_NAME" ]; then
        printf 'ERROR: failed to extract required live Xray state from %s\n' "$CONTAINER_NAME" >&2
        exit 1
    fi
}

resolve_client_ref() {
    if [ "$CLIENT_ID" = "bootstrap" ]; then
        CLIENT_ID="$BOOTSTRAP_ID"
    fi
}

prepare_tmpdir() {
    if [ -z "$TMPDIR" ]; then
        TMPDIR="$(mktemp -d)"
    fi
}

fetch_clients_registry() {
    prepare_tmpdir

    if [ "$REGISTRY_MODE" = "compat" ]; then
        docker exec "$CONTAINER_NAME" sh -lc "cat '$REGISTRY_SERVER_JSON_PATH'" >"$TMPDIR/server.json"

        python3 - "$TMPDIR/server.json" "$TMPDIR/clients.json" <<'EOF'
import json
import sys

server_path, clients_path = sys.argv[1:3]

with open(server_path, "r", encoding="utf-8") as fh:
    server = json.load(fh)

clients = (
    server.get("inbounds", [{}])[0]
    .get("settings", {})
    .get("clients", [])
)

with open(clients_path, "w", encoding="utf-8") as fh:
    json.dump(clients, fh, indent=2)
    fh.write("\n")
EOF
        return
    fi

    docker exec "$CONTAINER_NAME" sh -lc "cat '$CLIENTS_JSON_PATH'" >"$TMPDIR/clients.json"
}

write_clients_registry() {
    local source_path="$1"

    if [ "$REGISTRY_MODE" = "compat" ]; then
        prepare_tmpdir
        docker exec "$CONTAINER_NAME" sh -lc "cat '$REGISTRY_SERVER_JSON_PATH'" >"$TMPDIR/server.json"

        python3 - "$TMPDIR/server.json" "$source_path" <<'EOF'
import json
import sys

server_path, clients_path = sys.argv[1:3]

with open(server_path, "r", encoding="utf-8") as fh:
    server = json.load(fh)

with open(clients_path, "r", encoding="utf-8") as fh:
    clients = json.load(fh)

try:
    server["inbounds"][0]["settings"]["clients"] = clients
except (KeyError, IndexError, TypeError) as exc:
    raise SystemExit(f"ERROR: unsupported Xray server.json structure: {exc}")

with open(server_path, "w", encoding="utf-8") as fh:
    json.dump(server, fh, indent=4)
    fh.write("\n")
EOF

        docker exec -i "$CONTAINER_NAME" sh -lc "umask 077 && cat > '$REGISTRY_SERVER_JSON_PATH'" <"$TMPDIR/server.json"
        return
    fi

    docker exec -i "$CONTAINER_NAME" sh -lc "umask 077 && cat > '$CLIENTS_JSON_PATH'" <"$source_path"
}

wait_for_healthy() {
    local attempt
    local state
    local health

    for attempt in $(seq 1 "$RESTART_TIMEOUT"); do
        state="$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")"
        health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME")"

        if [ "$state" = "running" ] && { [ "$health" = "healthy" ] || [ "$health" = "none" ]; }; then
            return 0
        fi

        sleep 1
    done

    printf 'ERROR: container %s did not become healthy after restart\n' "$CONTAINER_NAME" >&2
    return 1
}

restart_xray() {
    docker restart "$CONTAINER_NAME" >/dev/null
    wait_for_healthy
}

list_clients() {
    fetch_clients_registry

    python3 - "$TMPDIR/clients.json" "$BOOTSTRAP_ID" "$INCLUDE_BOOTSTRAP" <<'EOF'
import json
import sys

path, bootstrap_id, include_bootstrap = sys.argv[1:4]
include_bootstrap = include_bootstrap.lower() == "true"

with open(path, "r", encoding="utf-8") as fh:
    clients = json.load(fh)

print("ROLE\tCLIENT_ID\tFLOW")
for client in clients:
    client_id = client.get("id", "")
    flow = client.get("flow", "")
    role = "bootstrap" if client_id == bootstrap_id else "client"

    if role == "bootstrap" and not include_bootstrap:
        continue

    print(f"{role}\t{client_id}\t{flow}")
EOF
}

add_client() {
    local effective_flow
    local new_client_id

    fetch_clients_registry

    if [ -z "$CLIENT_ID" ]; then
        CLIENT_ID="$(python3 - <<'EOF'
import uuid
print(uuid.uuid4())
EOF
)"
    fi

    resolve_client_ref

    if [ -n "$CLIENT_FLOW" ]; then
        effective_flow="$CLIENT_FLOW"
    else
        effective_flow="$(python3 - "$TMPDIR/clients.json" "$BOOTSTRAP_ID" "$DEFAULT_CLIENT_FLOW" <<'EOF'
import json
import sys

path, bootstrap_id, default_flow = sys.argv[1:4]

with open(path, "r", encoding="utf-8") as fh:
    clients = json.load(fh)

for client in clients:
    if client.get("id") == bootstrap_id and client.get("flow"):
        print(client["flow"])
        break
else:
    print(default_flow)
EOF
)"
    fi

    python3 - "$TMPDIR/clients.json" "$CLIENT_ID" "$effective_flow" <<'EOF'
import json
import sys

path, client_id, flow = sys.argv[1:4]

with open(path, "r", encoding="utf-8") as fh:
    clients = json.load(fh)

for client in clients:
    if client.get("id") == client_id:
        raise SystemExit(f"ERROR: client already exists: {client_id}")

clients.append({
    "id": client_id,
    "flow": flow,
})

with open(path, "w", encoding="utf-8") as fh:
    json.dump(clients, fh, indent=2)
    fh.write("\n")
EOF

    write_clients_registry "$TMPDIR/clients.json"
    restart_xray

    new_client_id="$CLIENT_ID"
    log "Added Xray client:"
    log "  client id: $new_client_id"
    log "  flow: $effective_flow"
}

remove_client() {
    [ -n "$CLIENT_ID" ] || {
        printf 'ERROR: remove requires --client-id\n' >&2
        exit 1
    }

    fetch_clients_registry
    resolve_client_ref

    python3 - "$TMPDIR/clients.json" "$CLIENT_ID" "$BOOTSTRAP_ID" "$ALLOW_BOOTSTRAP_REMOVAL" <<'EOF'
import json
import sys

path, client_id, bootstrap_id, allow_bootstrap = sys.argv[1:5]
allow_bootstrap = allow_bootstrap.lower() == "true"

with open(path, "r", encoding="utf-8") as fh:
    clients = json.load(fh)

if client_id == bootstrap_id and not allow_bootstrap:
    raise SystemExit("ERROR: refusing to remove bootstrap client without --allow-bootstrap-removal")

filtered = [client for client in clients if client.get("id") != client_id]

if len(filtered) == len(clients):
    raise SystemExit(f"ERROR: client not found: {client_id}")

with open(path, "w", encoding="utf-8") as fh:
    json.dump(filtered, fh, indent=2)
    fh.write("\n")
EOF

    write_clients_registry "$TMPDIR/clients.json"
    restart_xray

    log "Removed Xray client:"
    log "  client id: $CLIENT_ID"
}

export_client() {
    local selected_flow

    [ -n "$CLIENT_ID" ] || {
        printf 'ERROR: export requires --client-id\n' >&2
        exit 1
    }
    [ -n "$SERVER_HOST" ] || {
        printf 'ERROR: export requires --server-host\n' >&2
        exit 1
    }
    if ! validate_numeric_port "$LOCAL_SOCKS_PORT"; then
        printf 'ERROR: invalid --local-socks-port value: %s\n' "$LOCAL_SOCKS_PORT" >&2
        exit 1
    fi

    fetch_clients_registry
    resolve_client_ref
    prepare_tmpdir

    docker exec "$CONTAINER_NAME" sh -lc "cat '$CLIENT_TEMPLATE_PATH'" >"$TMPDIR/client.template.json"

    selected_flow="$(python3 - "$TMPDIR/clients.json" "$CLIENT_ID" <<'EOF'
import json
import sys

path, client_id = sys.argv[1:3]

with open(path, "r", encoding="utf-8") as fh:
    clients = json.load(fh)

for client in clients:
    if client.get("id") == client_id:
        print(client.get("flow", ""))
        break
else:
    raise SystemExit(f"ERROR: client not found: {client_id}")
EOF
)"

    python3 - \
        "$TMPDIR/client.template.json" \
        "$CLIENT_ID" \
        "$selected_flow" \
        "$SERVER_HOST" \
        "$SERVER_PORT" \
        "$SITE_NAME" \
        "$PUBLIC_KEY" \
        "$SHORT_ID" \
        "$LOCAL_SOCKS_PORT" \
        "$OUTPUT_PATH" <<'EOF'
import json
import sys

(
    template_path,
    client_id,
    flow,
    server_host,
    server_port,
    site_name,
    public_key,
    short_id,
    local_socks_port,
    output_path,
) = sys.argv[1:11]

with open(template_path, "r", encoding="utf-8") as fh:
    content = fh.read()

replacements = {
    "$SERVER_IP_ADDRESS": server_host,
    "$XRAY_SERVER_PORT": server_port,
    "$XRAY_CLIENT_ID": client_id,
    "$XRAY_SITE_NAME": site_name,
    "$XRAY_PUBLIC_KEY": public_key,
    "$XRAY_SHORT_ID": short_id,
    "__XRAY_CLIENT_FLOW__": flow,
}

for key, value in replacements.items():
    content = content.replace(key, value)

data = json.loads(content)
data["inbounds"][0]["port"] = int(local_socks_port)

rendered = json.dumps(data, indent=4) + "\n"

if output_path == "-":
    sys.stdout.write(rendered)
else:
    with open(output_path, "w", encoding="utf-8") as fh:
        fh.write(rendered)
EOF

    if [ "$OUTPUT_PATH" != "-" ]; then
        log "Exported Xray client config:"
        log "  client id: $CLIENT_ID"
        log "  output: $OUTPUT_PATH"
    fi
}

main() {
    trap cleanup EXIT

    parse_args "$@"

    require_cmd docker
    require_cmd python3

    discover_container
    require_running_server
    discover_paths
    discover_server_port
    read_live_state

    case "$COMMAND" in
        list)
            list_clients
            ;;
        add)
            add_client
            ;;
        remove)
            remove_client
            ;;
        export)
            export_client
            ;;
        *)
            printf 'ERROR: unsupported command: %s\n' "$COMMAND" >&2
            exit 1
            ;;
    esac
}

main "$@"
