#!/bin/sh
set -eu

BASE_CFG=/opt/obscura/3proxy.base.cfg
GENERATED_CFG=/usr/local/3proxy/conf/3proxy.cfg
GENERATED_EXTRA_CFG=/usr/local/3proxy/conf/extra.cfg

STATE_DIR=${SOCKS5_STATE_DIR:-/var/lib/obscura/socks5proxy}
COMPAT_CFG=${SOCKS5_COMPAT_CONFIG:-}
ALLOW_ANONYMOUS=${SOCKS5_ALLOW_ANONYMOUS:-false}
DNS_SERVERS=${SOCKS5_DNS_SERVERS:-172.30.153.53}
LISTEN_ADDR=${SOCKS5_LISTEN_ADDR:-0.0.0.0}
PORT_DEFAULT=${SOCKS5_PORT_DEFAULT:-38080}
PUBLISHED_PORT=${SOCKS5_PUBLISHED_PORT:-38080}
PUBLISH_MODE=${SOCKS5_PUBLISH_MODE:-bridge}
RESOLVE_MODE=${SOCKS5_RESOLVE_MODE:-prefer_ipv6}
BOOTSTRAP_USERNAME=${SOCKS5_BOOTSTRAP_USERNAME:-proxy_user}
BOOTSTRAP_PASSWORD=${SOCKS5_BOOTSTRAP_PASSWORD:-}
BOOTSTRAP_PORT=${SOCKS5_BOOTSTRAP_PORT:-$PUBLISHED_PORT}

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

read_file_trimmed() {
    if [ -f "$1" ]; then
        trim "$(cat "$1")"
    fi
}

is_true() {
    case "$(lower "$1")" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_mode_flag() {
    case "$(lower "$1")" in
        auto|'')
            printf '%s' ''
            ;;
        prefer_ipv6)
            printf '%s' '-64'
            ;;
        ipv6_only)
            printf '%s' '-6'
            ;;
        prefer_ipv4)
            printf '%s' '-46'
            ;;
        ipv4_only)
            printf '%s' '-4'
            ;;
        *)
            echo "Invalid SOCKS5 resolve mode: $1" >&2
            echo "Valid values: auto, prefer_ipv6, ipv6_only, prefer_ipv4, ipv4_only" >&2
            exit 1
            ;;
    esac
}

generate_password() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16
}

validate_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac

    if [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then
        return 1
    fi
}

mkdir -p "$STATE_DIR" /usr/local/3proxy/conf

PORT=""
AUTH_LINE=""
USERS_PAYLOAD=""
EXTRA_CFG_SOURCE=""

if [ -n "$COMPAT_CFG" ] && [ -f "$COMPAT_CFG" ]; then
    PORT="$(sed -n 's/.*socks[[:space:]].*-p\([0-9][0-9]*\).*/\1/p' "$COMPAT_CFG" | tail -n 1)"
    AUTH_LINE="$(awk '$1=="auth"{sub(/^auth[[:space:]]+/,""); auth=$0} END{print auth}' "$COMPAT_CFG")"
    USERS_PAYLOAD="$(awk '$1=="users"{sub(/^users[[:space:]]+/,""); printf "%s ", $0}' "$COMPAT_CFG" | sed 's/[[:space:]]*$//')"

    if [ -f "$(dirname "$COMPAT_CFG")/extra.cfg" ]; then
        EXTRA_CFG_SOURCE="$(dirname "$COMPAT_CFG")/extra.cfg"
    fi
fi

if [ -z "$PORT" ]; then
    PORT="$(read_file_trimmed "$STATE_DIR/port")"
fi

if [ -z "$AUTH_LINE" ]; then
    AUTH_LINE="$(read_file_trimmed "$STATE_DIR/auth_type")"
fi

if [ -z "$USERS_PAYLOAD" ] && [ -f "$STATE_DIR/users.list" ]; then
    USERS_PAYLOAD="$(awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line ~ /^users[[:space:]]+/) {
                sub(/^users[[:space:]]+/, "", line)
            }
            printf "%s ", line
        }
    ' "$STATE_DIR/users.list" | sed 's/[[:space:]]*$//')"
fi

if [ -z "$USERS_PAYLOAD" ]; then
    USERNAME="$(read_file_trimmed "$STATE_DIR/username")"
    PASSWORD="$(read_file_trimmed "$STATE_DIR/password")"
    if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
        USERS_PAYLOAD="${USERNAME}:CL:${PASSWORD}"
    fi
fi

if [ -z "$EXTRA_CFG_SOURCE" ] && [ -f "$STATE_DIR/extra.cfg" ]; then
    EXTRA_CFG_SOURCE="$STATE_DIR/extra.cfg"
fi

if [ -z "$PORT" ]; then
    PORT="$PORT_DEFAULT"
fi

if [ -z "$USERS_PAYLOAD" ] && ! is_true "$ALLOW_ANONYMOUS"; then
    if [ -z "$BOOTSTRAP_PASSWORD" ]; then
        BOOTSTRAP_PASSWORD="$(generate_password)"
    fi

    printf '%s\n' "$BOOTSTRAP_PORT" > "$STATE_DIR/port"
    printf '%s\n' "$BOOTSTRAP_USERNAME:CL:$BOOTSTRAP_PASSWORD" > "$STATE_DIR/users.list"
    chmod 0600 "$STATE_DIR/port" "$STATE_DIR/users.list"

    PORT="$BOOTSTRAP_PORT"
    USERS_PAYLOAD="$BOOTSTRAP_USERNAME:CL:$BOOTSTRAP_PASSWORD"

    echo "socks5proxy bootstrap credentials created in $STATE_DIR/users.list"
fi

if [ -z "$AUTH_LINE" ]; then
    if [ -n "$USERS_PAYLOAD" ]; then
        AUTH_LINE="strong"
    else
        AUTH_LINE="none"
    fi
fi

if ! validate_port "$PORT"; then
    echo "Invalid SOCKS5 port: $PORT" >&2
    exit 1
fi

if [ "$PUBLISH_MODE" = "bridge" ] && [ "$PORT" != "$PUBLISHED_PORT" ]; then
    echo "Configured SOCKS5 port ($PORT) does not match published bridge port ($PUBLISHED_PORT)." >&2
    echo "Either update SOCKS5_PUBLISHED_PORT to match, or switch to host networking for Amnezia compatibility." >&2
    exit 1
fi

if [ -z "$USERS_PAYLOAD" ] && [ "$(lower "$AUTH_LINE")" != "none" ]; then
    echo "Authentication is enabled but no SOCKS5 users were found." >&2
    exit 1
fi

if [ -n "$USERS_PAYLOAD" ]; then
    FIRST_USER="$(printf '%s\n' "$USERS_PAYLOAD" | awk '{print $1}' | cut -d: -f1)"
    echo "socks5proxy effective user: $FIRST_USER"
fi
echo "socks5proxy effective port: $PORT"

cp "$BASE_CFG" "$GENERATED_CFG"

for dns_server in $(printf '%s' "$DNS_SERVERS" | tr ',;' '  '); do
    dns_server="$(trim "$dns_server")"
    [ -n "$dns_server" ] || continue
    printf 'nserver %s\n' "$dns_server" >> "$GENERATED_CFG"
done

if [ -n "$USERS_PAYLOAD" ]; then
    printf 'users %s\n' "$USERS_PAYLOAD" >> "$GENERATED_CFG"
fi
printf 'auth %s\n' "$AUTH_LINE" >> "$GENERATED_CFG"
printf 'flush\n' >> "$GENERATED_CFG"

if [ -n "$EXTRA_CFG_SOURCE" ]; then
    cp "$EXTRA_CFG_SOURCE" "$GENERATED_EXTRA_CFG"
    chmod 0440 "$GENERATED_EXTRA_CFG"
    printf 'include /conf/extra.cfg\n' >> "$GENERATED_CFG"
fi

RESOLVE_FLAG="$(resolve_mode_flag "$RESOLVE_MODE")"
if [ -n "$RESOLVE_FLAG" ]; then
    printf 'socks %s -p%s -i%s\n' "$RESOLVE_FLAG" "$PORT" "$LISTEN_ADDR" >> "$GENERATED_CFG"
else
    printf 'socks -p%s -i%s\n' "$PORT" "$LISTEN_ADDR" >> "$GENERATED_CFG"
fi
chmod 0440 "$GENERATED_CFG"

exec "$@"
