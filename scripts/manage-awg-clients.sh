#!/usr/bin/env bash
set -euo pipefail

DEFAULT_SERVICE_LABEL="com.docker.compose.service=awg"
DEFAULT_PROJECT_LABEL="com.docker.compose.project=obscura"
DEFAULT_CONTAINER_NUMBER_LABEL="com.docker.compose.container-number=1"
DEFAULT_RESTART_TIMEOUT="${AWG_CLIENTS_RESTART_TIMEOUT:-30}"
DEFAULT_TARGET_STATE_DIR="/var/lib/obscura/awg"
PYTHON_BIN="${PYTHON_BIN:-python3}"

COMMAND=""
CONTAINER_NAME=""
CLIENT_NAME=""
PUBLIC_KEY=""
SERVER_HOST=""
OUTPUT_PATH="-"
RESTART_TIMEOUT="$DEFAULT_RESTART_TIMEOUT"
TARGET_STATE_DIR="$DEFAULT_TARGET_STATE_DIR"
SKIP_RESTART=0

TMPDIR=""
LISTEN_PORT=""
PUBLISHED_PORT=""
EXPECTED_ENABLED_PEERS=""

usage() {
    cat <<'EOF'
Usage: manage-awg-clients.sh <command> [options]

Manage the Obscura AWG client registry and export client configs.

Commands:
  list                       List configured clients
  add                        Add a generated client and restart AWG
  remove                     Remove a client and restart AWG
  export                     Export one concrete client config

Options:
  --container <name>         Explicit awg container name
  --target-state-dir <path>  State dir inside container, default /var/lib/obscura/awg
  --name <value>             Client name for add/remove/export
  --public-key <key>         Client public key for remove/export
  --server-host <host>       Server address for export
  --output <path|->          Export destination, default stdout
  --restart-timeout <sec>    Restart health timeout, default 30
  --skip-restart             Update registry without restarting AWG
  -h, --help                 Show this help

Examples:
  sudo bash scripts/manage-awg-clients.sh list
  sudo bash scripts/manage-awg-clients.sh add --name phone
  sudo bash scripts/manage-awg-clients.sh export --name phone --server-host vpn.example.com --output phone.conf
  sudo bash scripts/manage-awg-clients.sh remove --name phone
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

validate_numeric() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 0 ]
}

validate_positive_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
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
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --container\n' >&2; exit 1; }
                CONTAINER_NAME="$2"
                shift 2
                ;;
            --target-state-dir)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --target-state-dir\n' >&2; exit 1; }
                TARGET_STATE_DIR="$2"
                shift 2
                ;;
            --name)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --name\n' >&2; exit 1; }
                CLIENT_NAME="$2"
                shift 2
                ;;
            --public-key)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --public-key\n' >&2; exit 1; }
                PUBLIC_KEY="$2"
                shift 2
                ;;
            --server-host)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --server-host\n' >&2; exit 1; }
                SERVER_HOST="$2"
                shift 2
                ;;
            --output)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --output\n' >&2; exit 1; }
                OUTPUT_PATH="$2"
                shift 2
                ;;
            --restart-timeout)
                [ "$#" -ge 2 ] || { printf 'ERROR: missing value for --restart-timeout\n' >&2; exit 1; }
                RESTART_TIMEOUT="$2"
                shift 2
                ;;
            --skip-restart)
                SKIP_RESTART=1
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

    if ! validate_numeric "$RESTART_TIMEOUT"; then
        printf 'ERROR: invalid --restart-timeout value: %s\n' "$RESTART_TIMEOUT" >&2
        exit 1
    fi
}

prepare_tmpdir() {
    if [ -z "$TMPDIR" ]; then
        TMPDIR="$(mktemp -d)"
    fi
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
        printf 'ERROR: no running awg container found\n' >&2
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

read_state_file() {
    local source_path="$1"
    local target_path="$2"

    docker exec "$CONTAINER_NAME" sh -lc "cat '$source_path'" >"$target_path"
}

read_clients_registry() {
    prepare_tmpdir
    read_state_file "$TARGET_STATE_DIR/clients.json" "$TMPDIR/clients.json"
    read_state_file "$TARGET_STATE_DIR/settings.json" "$TMPDIR/settings.json"
}

write_clients_registry() {
    docker exec -i "$CONTAINER_NAME" sh -lc "umask 077 && cat > '$TARGET_STATE_DIR/clients.json'" <"$TMPDIR/clients.json"
}

generate_client_keypair() {
    docker exec "$CONTAINER_NAME" sh -lc '
        private_key="$(awg genkey)"
        public_key="$(printf "%s\n" "$private_key" | awg pubkey)"
        printf "%s\n%s\n" "$private_key" "$public_key"
    ' >"$TMPDIR/keypair.txt"
}

discover_server_port() {
    local port_lines

    LISTEN_PORT="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" | sed -n 's/^AWG_LISTEN_PORT=//p' | head -n 1)"
    if ! validate_positive_port "$LISTEN_PORT"; then
        LISTEN_PORT="55424"
    fi

    port_lines="$(docker port "$CONTAINER_NAME" "${LISTEN_PORT}/udp" 2>/dev/null || true)"
    if [ -z "$port_lines" ]; then
        port_lines="$(docker port "$CONTAINER_NAME" 2>/dev/null || true)"
    fi

    PUBLISHED_PORT="$(printf '%s\n' "$port_lines" | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -n 1)"
    if ! validate_positive_port "$PUBLISHED_PORT"; then
        PUBLISHED_PORT="$LISTEN_PORT"
    fi
}

count_enabled_registry_peers() {
    "$PYTHON_BIN" - "$TMPDIR/clients.json" <<'PY'
import json
import sys

clients = json.load(open(sys.argv[1], encoding="utf-8"))
count = 0
for client in clients:
    if client.get("enabled") is False:
        continue
    if (client.get("public_key") or "").strip() and (client.get("allowed_ips") or client.get("address") or "").strip():
        count += 1
print(count)
PY
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

verify_live_peer_count() {
    local interface
    local live_count

    interface="$(
        "$PYTHON_BIN" - "$TMPDIR/settings.json" <<'PY'
import json
import sys
settings = json.load(open(sys.argv[1], encoding="utf-8"))
print(settings.get("interface") or "awg0")
PY
    )"

    live_count="$(docker exec "$CONTAINER_NAME" sh -lc "awg show '$interface' peers | wc -l")"
    live_count="$(printf '%s' "$live_count" | tr -d '[:space:]')"

    if [ "$live_count" != "$EXPECTED_ENABLED_PEERS" ]; then
        printf 'ERROR: live AWG peer count (%s) does not match enabled registry peer count (%s)\n' "$live_count" "$EXPECTED_ENABLED_PEERS" >&2
        exit 1
    fi
}

restart_awg() {
    [ "$SKIP_RESTART" -eq 0 ] || return

    EXPECTED_ENABLED_PEERS="$(count_enabled_registry_peers)"
    docker restart "$CONTAINER_NAME" >/dev/null
    wait_for_healthy
    verify_live_peer_count
}

list_clients() {
    read_clients_registry

    "$PYTHON_BIN" - "$TMPDIR/clients.json" <<'PY'
import json
import sys

clients = json.load(open(sys.argv[1], encoding="utf-8"))
print("NAME\tADDRESS\tPUBLIC_KEY\tEXPORTABLE\tENABLED\tSOURCE")
for client in clients:
    print(
        f"{client.get('name', '')}\t"
        f"{client.get('address', '')}\t"
        f"{client.get('public_key', '')}\t"
        f"{client.get('exportable', True)}\t"
        f"{client.get('enabled', True)}\t"
        f"{client.get('source', 'obscura')}"
    )
PY
}

add_client() {
    read_clients_registry
    generate_client_keypair

    "$PYTHON_BIN" - "$TMPDIR/clients.json" "$TMPDIR/settings.json" "$TMPDIR/keypair.txt" "$CLIENT_NAME" "$TMPDIR/add-result.txt" <<'PY'
import ipaddress
import json
import sys

clients_path, settings_path, keypair_path, requested_name, result_path = sys.argv[1:6]

clients = json.load(open(clients_path, encoding="utf-8"))
settings = json.load(open(settings_path, encoding="utf-8"))

with open(keypair_path, "r", encoding="utf-8") as fh:
    private_key, public_key = [line.strip() for line in fh.readlines()[:2]]

if not private_key or not public_key:
    raise SystemExit("ERROR: failed to generate AWG client keypair")

names = {client.get("name") for client in clients}
public_keys = {client.get("public_key") for client in clients}

if public_key in public_keys:
    raise SystemExit("ERROR: generated duplicate client public key")

if requested_name:
    name = requested_name
    if name in names:
        raise SystemExit(f"ERROR: client already exists: {name}")
else:
    index = len(clients) + 1
    while True:
        name = f"client-{index}"
        if name not in names:
            break
        index += 1

server_address = ipaddress.ip_interface(settings.get("server_address", "10.8.1.1/24"))
network = server_address.network
used_addresses = {client.get("address", "").split("/", 1)[0] for client in clients}
used_addresses.update(
    value.strip().split("/", 1)[0]
    for client in clients
    for value in (client.get("allowed_ips") or "").split(",")
    if value.strip()
)
used_addresses.add(str(server_address.ip))

for host in network.hosts():
    address = str(host)
    if address not in used_addresses:
        break
else:
    raise SystemExit("ERROR: no free address left in configured AWG subnet")

host_prefix = 32 if network.version == 4 else 128
client_address = f"{address}/{host_prefix}"

clients.append({
    "name": name,
    "address": client_address,
    "allowed_ips": client_address,
    "private_key": private_key,
    "public_key": public_key,
    "preshared_key": "",
    "persistent_keepalive": "25",
    "enabled": True,
    "exportable": True,
    "source": "obscura",
})

with open(clients_path, "w", encoding="utf-8") as fh:
    json.dump(clients, fh, indent=2)
    fh.write("\n")

with open(result_path, "w", encoding="utf-8") as fh:
    fh.write(f"{name}\n{client_address}\n{public_key}\n")
PY

    write_clients_registry
    restart_awg

    log "Added AWG client:"
    log "  name: $(sed -n '1p' "$TMPDIR/add-result.txt")"
    log "  address: $(sed -n '2p' "$TMPDIR/add-result.txt")"
    log "  public key: $(sed -n '3p' "$TMPDIR/add-result.txt")"
}

remove_client() {
    if [ -z "$CLIENT_NAME" ] && [ -z "$PUBLIC_KEY" ]; then
        printf 'ERROR: remove requires --name or --public-key\n' >&2
        exit 1
    fi

    read_clients_registry

    "$PYTHON_BIN" - "$TMPDIR/clients.json" "$CLIENT_NAME" "$PUBLIC_KEY" <<'PY'
import json
import sys

path, name, public_key = sys.argv[1:4]
clients = json.load(open(path, encoding="utf-8"))

def match(client):
    return bool(
        (name and client.get("name") == name)
        or (public_key and client.get("public_key") == public_key)
    )

filtered = [client for client in clients if not match(client)]
if len(filtered) == len(clients):
    raise SystemExit("ERROR: client not found")

with open(path, "w", encoding="utf-8") as fh:
    json.dump(filtered, fh, indent=2)
    fh.write("\n")
PY

    write_clients_registry
    restart_awg
    log "Removed AWG client."
}

export_client() {
    if [ -z "$CLIENT_NAME" ] && [ -z "$PUBLIC_KEY" ]; then
        printf 'ERROR: export requires --name or --public-key\n' >&2
        exit 1
    fi
    [ -n "$SERVER_HOST" ] || {
        printf 'ERROR: export requires --server-host\n' >&2
        exit 1
    }

    discover_server_port
    read_clients_registry
    prepare_tmpdir
    read_state_file "$TARGET_STATE_DIR/client.template.conf" "$TMPDIR/client.template.conf"

    "$PYTHON_BIN" - \
        "$TMPDIR/clients.json" \
        "$TMPDIR/client.template.conf" \
        "$CLIENT_NAME" \
        "$PUBLIC_KEY" \
        "$SERVER_HOST" \
        "$PUBLISHED_PORT" \
        "$OUTPUT_PATH" <<'PY'
import json
import sys

clients_path, template_path, name, public_key, server_host, published_port, output_path = sys.argv[1:8]
clients = json.load(open(clients_path, encoding="utf-8"))

selected = None
for client in clients:
    if name and client.get("name") == name:
        selected = client
        break
    if public_key and client.get("public_key") == public_key:
        selected = client
        break

if selected is None:
    raise SystemExit("ERROR: client not found")
if not selected.get("exportable", True) or not selected.get("private_key"):
    raise SystemExit("ERROR: selected client is not exportable because private key is not available")

content = open(template_path, encoding="utf-8").read()
for key, value in {
    "__AWG_CLIENT_ADDRESS__": selected.get("address", ""),
    "__AWG_CLIENT_PRIVATE_KEY__": selected.get("private_key", ""),
    "__AWG_SERVER_HOST__": server_host,
    "__AWG_PUBLISHED_PORT__": published_port,
}.items():
    content = content.replace(key, value)

if "__AWG_" in content:
    raise SystemExit("ERROR: rendered client config still contains unresolved AWG placeholders")

if output_path == "-":
    sys.stdout.write(content)
else:
    with open(output_path, "w", encoding="utf-8") as fh:
        fh.write(content)
PY

    if [ "$OUTPUT_PATH" != "-" ]; then
        log "Exported AWG client config:"
        log "  output: $OUTPUT_PATH"
    fi
}

main() {
    trap cleanup EXIT

    parse_args "$@"
    require_cmd docker
    require_cmd "$PYTHON_BIN"
    discover_container
    require_running_server

    case "$COMMAND" in
        list) list_clients ;;
        add) add_client ;;
        remove) remove_client ;;
        export) export_client ;;
        *) printf 'ERROR: unsupported command: %s\n' "$COMMAND" >&2; exit 1 ;;
    esac
}

main "$@"
