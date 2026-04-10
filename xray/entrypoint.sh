#!/bin/sh
set -eu

STATE_DIR=${XRAY_STATE_DIR:-/var/lib/obscura/xray}
COMPAT_STATE_DIR=${XRAY_COMPAT_STATE_DIR:-}
AMNEZIA_DIR=/opt/amnezia/xray
SERVER_TEMPLATE=/opt/obscura/server.template.json
CLIENT_TEMPLATE=/opt/obscura/client.template.json
SERVER_JSON="$STATE_DIR/server.json"
CLIENTS_JSON="$STATE_DIR/clients.json"
EXPORTED_CLIENT_TEMPLATE="$STATE_DIR/client.template.json"

LISTEN_ADDR=${XRAY_LISTEN_ADDR:-::}
LISTEN_PORT=${XRAY_LISTEN_PORT:-443}
PUBLISHED_PORT=${XRAY_PUBLISHED_PORT:-443}
SITE_NAME=${XRAY_SITE_NAME:-www.googletagmanager.com}
LOG_LEVEL=${XRAY_LOG_LEVEL:-warning}
BOOTSTRAP_CLIENT_FLOW=${XRAY_BOOTSTRAP_CLIENT_FLOW:-xtls-rprx-vision}
COMPAT_MODE=false
COMPAT_SERVER_JSON=
SHARED_BOOTSTRAP_UUID_FILE="$STATE_DIR/xray_uuid.key"
SHARED_SHORT_ID_FILE="$STATE_DIR/xray_short_id.key"
SHARED_PUBLIC_KEY_FILE="$STATE_DIR/xray_public.key"
SHARED_PRIVATE_KEY_FILE="$STATE_DIR/xray_private.key"

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

enable_compat_mode() {
    if [ -z "$COMPAT_STATE_DIR" ]; then
        return
    fi

    COMPAT_MODE=true
    COMPAT_SERVER_JSON="$COMPAT_STATE_DIR/server.json"
    SHARED_BOOTSTRAP_UUID_FILE="$COMPAT_STATE_DIR/xray_uuid.key"
    SHARED_SHORT_ID_FILE="$COMPAT_STATE_DIR/xray_short_id.key"
    SHARED_PUBLIC_KEY_FILE="$COMPAT_STATE_DIR/xray_public.key"
    SHARED_PRIVATE_KEY_FILE="$COMPAT_STATE_DIR/xray_private.key"
}

require_compat_state() {
    local missing_path

    for missing_path in \
        "$COMPAT_SERVER_JSON" \
        "$SHARED_BOOTSTRAP_UUID_FILE" \
        "$SHARED_SHORT_ID_FILE" \
        "$SHARED_PUBLIC_KEY_FILE" \
        "$SHARED_PRIVATE_KEY_FILE"
    do
        if [ ! -s "$missing_path" ]; then
            echo "Missing required Xray compatibility state: $missing_path" >&2
            exit 1
        fi
    done
}

generate_key_material() {
    if [ ! -s "$SHARED_BOOTSTRAP_UUID_FILE" ]; then
        xray uuid >"$SHARED_BOOTSTRAP_UUID_FILE"
        chmod 0600 "$SHARED_BOOTSTRAP_UUID_FILE"
    fi

    if [ ! -s "$SHARED_SHORT_ID_FILE" ]; then
        openssl rand -hex 8 >"$SHARED_SHORT_ID_FILE"
        chmod 0600 "$SHARED_SHORT_ID_FILE"
    fi

    if [ ! -s "$SHARED_PUBLIC_KEY_FILE" ] || [ ! -s "$SHARED_PRIVATE_KEY_FILE" ]; then
        KEYPAIR="$(xray x25519)"
        XRAY_PRIVATE_KEY="$(printf '%s\n' "$KEYPAIR" | sed -n 's/^Private key:[[:space:]]*//p' | head -n 1)"
        XRAY_PUBLIC_KEY="$(printf '%s\n' "$KEYPAIR" | sed -n 's/^Public key:[[:space:]]*//p' | head -n 1)"

        XRAY_PRIVATE_KEY="$(trim "$XRAY_PRIVATE_KEY")"
        XRAY_PUBLIC_KEY="$(trim "$XRAY_PUBLIC_KEY")"

        if [ -z "$XRAY_PRIVATE_KEY" ] || [ -z "$XRAY_PUBLIC_KEY" ]; then
            echo "Failed to generate Xray Reality keypair" >&2
            exit 1
        fi

        printf '%s\n' "$XRAY_PRIVATE_KEY" >"$SHARED_PRIVATE_KEY_FILE"
        printf '%s\n' "$XRAY_PUBLIC_KEY" >"$SHARED_PUBLIC_KEY_FILE"
        chmod 0600 "$SHARED_PRIVATE_KEY_FILE" "$SHARED_PUBLIC_KEY_FILE"
    fi
}

sync_clients_registry_from_compat_server() {
    tmp_clients_json="$CLIENTS_JSON.tmp"

    if ! awk '
        BEGIN {
            capture = 0
            found = 0
        }

        /"clients"[[:space:]]*:[[:space:]]*\[/ && !found {
            found = 1
            capture = 1
            print "["
            next
        }

        capture {
            if ($0 ~ /^[[:space:]]*\][[:space:]]*,?[[:space:]]*$/) {
                print "]"
                exit
            }

            print $0
        }

        END {
            if (!found) {
                exit 2
            }
        }
    ' "$COMPAT_SERVER_JSON" >"$tmp_clients_json"; then
        echo "Failed to extract Xray clients from compatibility state: $COMPAT_SERVER_JSON" >&2
        rm -f "$tmp_clients_json"
        exit 1
    fi

    mv "$tmp_clients_json" "$CLIENTS_JSON"
    chmod 0600 "$CLIENTS_JSON"
}

ensure_clients_registry() {
    if [ "$COMPAT_MODE" = true ]; then
        sync_clients_registry_from_compat_server
        return
    fi

    if [ -s "$CLIENTS_JSON" ]; then
        return
    fi

    BOOTSTRAP_UUID="$(trim "$(cat "$SHARED_BOOTSTRAP_UUID_FILE")")"

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
    PRIVATE_KEY="$(trim "$(cat "$SHARED_PRIVATE_KEY_FILE")")"
    SHORT_ID="$(trim "$(cat "$SHARED_SHORT_ID_FILE")")"

    awk \
        -v listen_addr="$LISTEN_ADDR" \
        -v log_level="$LOG_LEVEL" \
        -v private_key="$PRIVATE_KEY" \
        -v listen_port="$LISTEN_PORT" \
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
            gsub("__XRAY_LISTEN_PORT__", listen_port, line)
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
    ensure_symlink "$SHARED_BOOTSTRAP_UUID_FILE" "$AMNEZIA_DIR/xray_uuid.key"
    ensure_symlink "$SHARED_SHORT_ID_FILE" "$AMNEZIA_DIR/xray_short_id.key"
    ensure_symlink "$SHARED_PUBLIC_KEY_FILE" "$AMNEZIA_DIR/xray_public.key"
    ensure_symlink "$SHARED_PRIVATE_KEY_FILE" "$AMNEZIA_DIR/xray_private.key"
    ensure_symlink "$EXPORTED_CLIENT_TEMPLATE" "$AMNEZIA_DIR/client.template.json"
}

if ! validate_port "$LISTEN_PORT"; then
    echo "Invalid XRAY_LISTEN_PORT: $LISTEN_PORT" >&2
    exit 1
fi

if ! validate_port "$PUBLISHED_PORT"; then
    echo "Invalid XRAY_PUBLISHED_PORT: $PUBLISHED_PORT" >&2
    exit 1
fi

enable_compat_mode
ensure_parent_dirs
if [ "$COMPAT_MODE" = true ]; then
    require_compat_state
else
    generate_key_material
fi
ensure_clients_registry
render_client_template
render_server_config
publish_compatibility_view

echo "xray state dir: $STATE_DIR"
if [ "$COMPAT_MODE" = true ]; then
    echo "xray compatibility state dir: $COMPAT_STATE_DIR"
else
    echo "xray compatibility state dir: none"
fi
echo "xray listen addr: $LISTEN_ADDR"
echo "xray listen port: $LISTEN_PORT"
echo "xray published port: $PUBLISHED_PORT"
echo "xray site name: $SITE_NAME"

exec "$@"
