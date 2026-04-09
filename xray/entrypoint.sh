#!/bin/sh
set -eu

STATE_DIR=${XRAY_STATE_DIR:-/var/lib/obscura/xray}
AMNEZIA_DIR=/opt/amnezia/xray
SERVER_TEMPLATE=/opt/obscura/server.template.json
CLIENT_TEMPLATE=/opt/obscura/client.template.json
SERVER_JSON="$STATE_DIR/server.json"
CLIENTS_JSON="$STATE_DIR/clients.json"
BOOTSTRAP_UUID_FILE="$STATE_DIR/xray_uuid.key"
SHORT_ID_FILE="$STATE_DIR/xray_short_id.key"
PUBLIC_KEY_FILE="$STATE_DIR/xray_public.key"
PRIVATE_KEY_FILE="$STATE_DIR/xray_private.key"
EXPORTED_CLIENT_TEMPLATE="$STATE_DIR/client.template.json"

LISTEN_ADDR=${XRAY_LISTEN_ADDR:-::}
SERVER_PORT=${XRAY_SERVER_PORT:-443}
SITE_NAME=${XRAY_SITE_NAME:-www.googletagmanager.com}
LOG_LEVEL=${XRAY_LOG_LEVEL:-warning}
BOOTSTRAP_CLIENT_FLOW=${XRAY_BOOTSTRAP_CLIENT_FLOW:-xtls-rprx-vision}

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

validate_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac

    if [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then
        return 1
    fi
}

ensure_parent_dirs() {
    mkdir -p "$STATE_DIR" "$AMNEZIA_DIR"
}

generate_key_material() {
    if [ ! -s "$BOOTSTRAP_UUID_FILE" ]; then
        xray uuid >"$BOOTSTRAP_UUID_FILE"
        chmod 0600 "$BOOTSTRAP_UUID_FILE"
    fi

    if [ ! -s "$SHORT_ID_FILE" ]; then
        openssl rand -hex 8 >"$SHORT_ID_FILE"
        chmod 0600 "$SHORT_ID_FILE"
    fi

    if [ ! -s "$PUBLIC_KEY_FILE" ] || [ ! -s "$PRIVATE_KEY_FILE" ]; then
        KEYPAIR="$(xray x25519)"
        XRAY_PRIVATE_KEY="$(printf '%s\n' "$KEYPAIR" | sed -n 's/^Private key:[[:space:]]*//p' | head -n 1)"
        XRAY_PUBLIC_KEY="$(printf '%s\n' "$KEYPAIR" | sed -n 's/^Public key:[[:space:]]*//p' | head -n 1)"

        XRAY_PRIVATE_KEY="$(trim "$XRAY_PRIVATE_KEY")"
        XRAY_PUBLIC_KEY="$(trim "$XRAY_PUBLIC_KEY")"

        if [ -z "$XRAY_PRIVATE_KEY" ] || [ -z "$XRAY_PUBLIC_KEY" ]; then
            echo "Failed to generate Xray Reality keypair" >&2
            exit 1
        fi

        printf '%s\n' "$XRAY_PRIVATE_KEY" >"$PRIVATE_KEY_FILE"
        printf '%s\n' "$XRAY_PUBLIC_KEY" >"$PUBLIC_KEY_FILE"
        chmod 0600 "$PRIVATE_KEY_FILE" "$PUBLIC_KEY_FILE"
    fi
}

ensure_clients_registry() {
    if [ -s "$CLIENTS_JSON" ]; then
        return
    fi

    BOOTSTRAP_UUID="$(trim "$(cat "$BOOTSTRAP_UUID_FILE")")"

    cat >"$CLIENTS_JSON" <<EOF
[
  {
    "id": "$BOOTSTRAP_UUID",
    "flow": "$BOOTSTRAP_CLIENT_FLOW"
  }
]
EOF
    chmod 0600 "$CLIENTS_JSON"
}

render_client_template() {
    CLIENT_FLOW="$(sed -n 's/.*"flow":[[:space:]]*"\([^"]*\)".*/\1/p' "$CLIENTS_JSON" | head -n 1)"

    if [ -z "$CLIENT_FLOW" ]; then
        CLIENT_FLOW="$BOOTSTRAP_CLIENT_FLOW"
    fi

    awk \
        -v client_flow="$CLIENT_FLOW" '
        {
            line = $0
            gsub("__XRAY_CLIENT_FLOW__", client_flow, line)
            print line
        }
    ' "$CLIENT_TEMPLATE" >"$EXPORTED_CLIENT_TEMPLATE"

    chmod 0644 "$EXPORTED_CLIENT_TEMPLATE"
}

render_server_config() {
    PRIVATE_KEY="$(trim "$(cat "$PRIVATE_KEY_FILE")")"
    SHORT_ID="$(trim "$(cat "$SHORT_ID_FILE")")"

    awk \
        -v listen_addr="$LISTEN_ADDR" \
        -v log_level="$LOG_LEVEL" \
        -v private_key="$PRIVATE_KEY" \
        -v server_port="$SERVER_PORT" \
        -v site_name="$SITE_NAME" \
        -v short_id="$SHORT_ID" \
        -v clients_file="$CLIENTS_JSON" '
        function emit_clients_block(    client_line) {
            print "                \"clients\": ["

            while ((getline client_line < clients_file) > 0) {
                if (client_line == "[" || client_line == "]") {
                    continue
                }

                print "                " client_line
            }

            close(clients_file)
            print "                ],"
        }

        {
            line = $0
            gsub("__XRAY_LISTEN_ADDR__", listen_addr, line)
            gsub("__XRAY_LOG_LEVEL__", log_level, line)
            gsub("__XRAY_PRIVATE_KEY__", private_key, line)
            gsub("__XRAY_SERVER_PORT__", server_port, line)
            gsub("__XRAY_SITE_NAME__", site_name, line)
            gsub("__XRAY_SHORT_ID__", short_id, line)

            if (line ~ /__XRAY_CLIENTS_BLOCK__/) {
                emit_clients_block()
            } else {
                print line
            }
        }
    ' "$SERVER_TEMPLATE" >"$SERVER_JSON"

    chmod 0600 "$SERVER_JSON"
}

ensure_symlink() {
    source_path="$1"
    target_path="$2"

    rm -f "$target_path"
    ln -s "$source_path" "$target_path"
}

publish_compatibility_view() {
    ensure_symlink "$SERVER_JSON" "$AMNEZIA_DIR/server.json"
    ensure_symlink "$CLIENTS_JSON" "$AMNEZIA_DIR/clients.json"
    ensure_symlink "$BOOTSTRAP_UUID_FILE" "$AMNEZIA_DIR/xray_uuid.key"
    ensure_symlink "$SHORT_ID_FILE" "$AMNEZIA_DIR/xray_short_id.key"
    ensure_symlink "$PUBLIC_KEY_FILE" "$AMNEZIA_DIR/xray_public.key"
    ensure_symlink "$PRIVATE_KEY_FILE" "$AMNEZIA_DIR/xray_private.key"
    ensure_symlink "$EXPORTED_CLIENT_TEMPLATE" "$AMNEZIA_DIR/client.template.json"
}

if ! validate_port "$SERVER_PORT"; then
    echo "Invalid XRAY_SERVER_PORT: $SERVER_PORT" >&2
    exit 1
fi

ensure_parent_dirs
generate_key_material
ensure_clients_registry
render_client_template
render_server_config
publish_compatibility_view

echo "xray state dir: $STATE_DIR"
echo "xray listen addr: $LISTEN_ADDR"
echo "xray server port: $SERVER_PORT"
echo "xray site name: $SITE_NAME"

exec "$@"
