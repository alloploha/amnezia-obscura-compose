#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${AWG_STATE_DIR:-/var/lib/obscura/awg}"
COMPAT_STATE_DIR="${AWG_COMPAT_STATE_DIR:-}"
AMNEZIA_DIR="/opt/amnezia/awg"
SERVER_TEMPLATE="/opt/obscura/awg0.template.conf"
CLIENT_TEMPLATE="/opt/obscura/client.template.conf"

INTERFACE="${AWG_INTERFACE:-awg0}"
LISTEN_PORT="${AWG_LISTEN_PORT:-55424}"
PUBLISHED_PORT="${AWG_PUBLISHED_PORT:-55424}"
SUBNET_ADDRESS="${AWG_SUBNET_ADDRESS:-10.8.1.0}"
SUBNET_CIDR="${AWG_SUBNET_CIDR:-24}"
SERVER_ADDRESS="${AWG_SERVER_ADDRESS:-}"
PRIMARY_DNS="${AWG_PRIMARY_DNS:-172.30.153.53}"
SECONDARY_DNS="${AWG_SECONDARY_DNS:-fd30:153::53}"
MTU="${AWG_MTU:-1376}"
NAT_ENABLED="${AWG_NAT_ENABLED:-true}"
JUNK_PACKET_COUNT="${AWG_JUNK_PACKET_COUNT:-3}"
JUNK_PACKET_MIN_SIZE="${AWG_JUNK_PACKET_MIN_SIZE:-10}"
JUNK_PACKET_MAX_SIZE="${AWG_JUNK_PACKET_MAX_SIZE:-30}"
INIT_PACKET_JUNK_SIZE="${AWG_INIT_PACKET_JUNK_SIZE:-15}"
RESPONSE_PACKET_JUNK_SIZE="${AWG_RESPONSE_PACKET_JUNK_SIZE:-18}"
COOKIE_REPLY_PACKET_JUNK_SIZE="${AWG_COOKIE_REPLY_PACKET_JUNK_SIZE:-20}"
TRANSPORT_PACKET_JUNK_SIZE="${AWG_TRANSPORT_PACKET_JUNK_SIZE:-23}"
INIT_PACKET_MAGIC_HEADER="${AWG_INIT_PACKET_MAGIC_HEADER:-1020325451}"
RESPONSE_PACKET_MAGIC_HEADER="${AWG_RESPONSE_PACKET_MAGIC_HEADER:-3288052141}"
UNDERLOAD_PACKET_MAGIC_HEADER="${AWG_UNDERLOAD_PACKET_MAGIC_HEADER:-1766607858}"
TRANSPORT_PACKET_MAGIC_HEADER="${AWG_TRANSPORT_PACKET_MAGIC_HEADER:-2528465083}"
SPECIAL_JUNK_1="${AWG_SPECIAL_JUNK_1:-<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>}"
SPECIAL_JUNK_2="${AWG_SPECIAL_JUNK_2:-}"
SPECIAL_JUNK_3="${AWG_SPECIAL_JUNK_3:-}"
SPECIAL_JUNK_4="${AWG_SPECIAL_JUNK_4:-}"
SPECIAL_JUNK_5="${AWG_SPECIAL_JUNK_5:-}"

SERVER_PRIVATE_KEY_FILE="$STATE_DIR/wireguard_server_private_key.key"
SERVER_PUBLIC_KEY_FILE="$STATE_DIR/wireguard_server_public_key.key"
PRESHARED_KEY_FILE="$STATE_DIR/wireguard_psk.key"
CLIENTS_JSON="$STATE_DIR/clients.json"
SETTINGS_JSON="$STATE_DIR/settings.json"
SERVER_CONF="$STATE_DIR/awg0.conf"
SETCONF="$STATE_DIR/awg0.setconf"
EXPORTED_CLIENT_TEMPLATE="$STATE_DIR/client.template.conf"

is_true() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

validate_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

require_file() {
    if [ ! -s "$1" ]; then
        echo "Missing required AWG compatibility state: $1" >&2
        exit 1
    fi
}

derive_server_address() {
    if [ -n "$SERVER_ADDRESS" ]; then
        return
    fi

    SERVER_ADDRESS="$(
        python3 - "$SUBNET_ADDRESS" "$SUBNET_CIDR" <<'PY'
import ipaddress
import sys

network = ipaddress.ip_network(f"{sys.argv[1]}/{sys.argv[2]}", strict=False)
hosts = network.hosts()
try:
    address = next(hosts)
except StopIteration:
    raise SystemExit("subnet has no usable host address")
print(f"{address}/{network.prefixlen}")
PY
    )"
}

generate_keys() {
    if [ ! -s "$SERVER_PRIVATE_KEY_FILE" ]; then
        awg genkey >"$SERVER_PRIVATE_KEY_FILE"
        chmod 0600 "$SERVER_PRIVATE_KEY_FILE"
    fi

    if [ ! -s "$SERVER_PUBLIC_KEY_FILE" ]; then
        awg pubkey <"$SERVER_PRIVATE_KEY_FILE" >"$SERVER_PUBLIC_KEY_FILE"
        chmod 0600 "$SERVER_PUBLIC_KEY_FILE"
    fi

    if [ ! -s "$PRESHARED_KEY_FILE" ]; then
        awg genpsk >"$PRESHARED_KEY_FILE"
        chmod 0600 "$PRESHARED_KEY_FILE"
    fi
}

link_or_copy_compat_keys() {
    require_file "$COMPAT_STATE_DIR/wireguard_server_private_key.key"
    require_file "$COMPAT_STATE_DIR/wireguard_server_public_key.key"
    require_file "$COMPAT_STATE_DIR/wireguard_psk.key"
    require_file "$COMPAT_STATE_DIR/awg0.conf"

    SERVER_PRIVATE_KEY_FILE="$COMPAT_STATE_DIR/wireguard_server_private_key.key"
    SERVER_PUBLIC_KEY_FILE="$COMPAT_STATE_DIR/wireguard_server_public_key.key"
    PRESHARED_KEY_FILE="$COMPAT_STATE_DIR/wireguard_psk.key"
}

ensure_clients_json() {
    if [ -s "$CLIENTS_JSON" ]; then
        return
    fi

    if [ -n "$COMPAT_STATE_DIR" ]; then
        python3 - "$COMPAT_STATE_DIR/awg0.conf" "$CLIENTS_JSON" <<'PY'
import json
import sys

source, target = sys.argv[1:3]
clients = []
current = None

def finish():
    if not current:
        return
    public_key = current.get("PublicKey", "").strip()
    if public_key:
        clients.append({
            "name": f"imported-{len(clients) + 1}",
            "public_key": public_key,
            "private_key": "",
            "address": "",
            "allowed_ips": current.get("AllowedIPs", "").strip() or "",
            "preshared_key": current.get("PresharedKey", "").strip() or "",
            "persistent_keepalive": current.get("PersistentKeepalive", "").strip() or "25",
            "enabled": True,
            "exportable": False,
            "source": "amnezia-import",
        })

with open(source, "r", encoding="utf-8") as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.lower() == "[peer]":
            finish()
            current = {}
            continue
        if line.startswith("["):
            finish()
            current = None
            continue
        if current is not None and "=" in line:
            key, value = line.split("=", 1)
            current[key.strip()] = value.strip()
finish()

with open(target, "w", encoding="utf-8") as fh:
    json.dump(clients, fh, indent=2)
    fh.write("\n")
PY
    else
        printf '[]\n' >"$CLIENTS_JSON"
    fi
    chmod 0600 "$CLIENTS_JSON"
}

write_settings_json() {
    python3 - "$SETTINGS_JSON" <<PY
import json

settings = {
    "interface": "$INTERFACE",
    "listen_port": int("$LISTEN_PORT"),
    "published_port": int("$PUBLISHED_PORT"),
    "subnet_address": "$SUBNET_ADDRESS",
    "subnet_cidr": int("$SUBNET_CIDR"),
    "server_address": "$SERVER_ADDRESS",
    "primary_dns": "$PRIMARY_DNS",
    "secondary_dns": "$SECONDARY_DNS",
    "mtu": int("$MTU"),
    "nat_enabled": "$(is_true "$NAT_ENABLED" && printf true || printf false)" == "true",
    "junk": {
        "Jc": "$JUNK_PACKET_COUNT",
        "Jmin": "$JUNK_PACKET_MIN_SIZE",
        "Jmax": "$JUNK_PACKET_MAX_SIZE",
        "S1": "$INIT_PACKET_JUNK_SIZE",
        "S2": "$RESPONSE_PACKET_JUNK_SIZE",
        "S3": "$COOKIE_REPLY_PACKET_JUNK_SIZE",
        "S4": "$TRANSPORT_PACKET_JUNK_SIZE",
        "H1": "$INIT_PACKET_MAGIC_HEADER",
        "H2": "$RESPONSE_PACKET_MAGIC_HEADER",
        "H3": "$UNDERLOAD_PACKET_MAGIC_HEADER",
        "H4": "$TRANSPORT_PACKET_MAGIC_HEADER",
        "I1": "$SPECIAL_JUNK_1",
        "I2": "$SPECIAL_JUNK_2",
        "I3": "$SPECIAL_JUNK_3",
        "I4": "$SPECIAL_JUNK_4",
        "I5": "$SPECIAL_JUNK_5",
    },
}

with open("$SETTINGS_JSON", "w", encoding="utf-8") as fh:
    json.dump(settings, fh, indent=2)
    fh.write("\\n")
PY
    chmod 0600 "$SETTINGS_JSON"
}

render_configs() {
    python3 - \
        "$SERVER_TEMPLATE" \
        "$CLIENT_TEMPLATE" \
        "$SERVER_CONF" \
        "$SETCONF" \
        "$EXPORTED_CLIENT_TEMPLATE" \
        "$CLIENTS_JSON" \
        "$SERVER_PRIVATE_KEY_FILE" \
        "$SERVER_PUBLIC_KEY_FILE" \
        "$PRESHARED_KEY_FILE" \
        "$SERVER_ADDRESS" \
        "$LISTEN_PORT" \
        "$PUBLISHED_PORT" \
        "$PRIMARY_DNS" \
        "$SECONDARY_DNS" \
        "$JUNK_PACKET_COUNT" \
        "$JUNK_PACKET_MIN_SIZE" \
        "$JUNK_PACKET_MAX_SIZE" \
        "$INIT_PACKET_JUNK_SIZE" \
        "$RESPONSE_PACKET_JUNK_SIZE" \
        "$COOKIE_REPLY_PACKET_JUNK_SIZE" \
        "$TRANSPORT_PACKET_JUNK_SIZE" \
        "$INIT_PACKET_MAGIC_HEADER" \
        "$RESPONSE_PACKET_MAGIC_HEADER" \
        "$UNDERLOAD_PACKET_MAGIC_HEADER" \
        "$TRANSPORT_PACKET_MAGIC_HEADER" \
        "$SPECIAL_JUNK_1" \
        "$SPECIAL_JUNK_2" \
        "$SPECIAL_JUNK_3" \
        "$SPECIAL_JUNK_4" \
        "$SPECIAL_JUNK_5" <<'PY'
import json
import sys

(
    server_template,
    client_template,
    server_conf,
    setconf,
    exported_client_template,
    clients_json,
    private_key_file,
    public_key_file,
    psk_file,
    server_address,
    listen_port,
    published_port,
    primary_dns,
    secondary_dns,
    jc,
    jmin,
    jmax,
    s1,
    s2,
    s3,
    s4,
    h1,
    h2,
    h3,
    h4,
    i1,
    i2,
    i3,
    i4,
    i5,
) = sys.argv[1:31]

def read(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read().strip()

private_key = read(private_key_file)
public_key = read(public_key_file)
psk = read(psk_file)
with open(clients_json, "r", encoding="utf-8") as fh:
    clients = json.load(fh)

peer_blocks = []
for client in clients:
    if client.get("enabled") is False:
        continue
    client_public_key = (client.get("public_key") or "").strip()
    if not client_public_key:
        continue
    allowed_ips = (client.get("allowed_ips") or client.get("address") or "").strip()
    if not allowed_ips:
        continue
    peer_psk = (client.get("preshared_key") or psk).strip()
    keepalive = str(client.get("persistent_keepalive") or "25").strip()
    block = [
        "[Peer]",
        f"PublicKey = {client_public_key}",
        f"PresharedKey = {peer_psk}",
        f"AllowedIPs = {allowed_ips}",
    ]
    if keepalive:
        block.append(f"PersistentKeepalive = {keepalive}")
    peer_blocks.append("\n".join(block))

replacements = {
    "__AWG_SERVER_PRIVATE_KEY__": private_key,
    "__AWG_SERVER_PUBLIC_KEY__": public_key,
    "__AWG_PRESHARED_KEY__": psk,
    "__AWG_SERVER_ADDRESS__": server_address,
    "__AWG_LISTEN_PORT__": listen_port,
    "__AWG_PUBLISHED_PORT__": published_port,
    "__AWG_PRIMARY_DNS__": primary_dns,
    "__AWG_SECONDARY_DNS__": secondary_dns,
    "__AWG_JUNK_PACKET_COUNT__": jc,
    "__AWG_JUNK_PACKET_MIN_SIZE__": jmin,
    "__AWG_JUNK_PACKET_MAX_SIZE__": jmax,
    "__AWG_INIT_PACKET_JUNK_SIZE__": s1,
    "__AWG_RESPONSE_PACKET_JUNK_SIZE__": s2,
    "__AWG_COOKIE_REPLY_PACKET_JUNK_SIZE__": s3,
    "__AWG_TRANSPORT_PACKET_JUNK_SIZE__": s4,
    "__AWG_INIT_PACKET_MAGIC_HEADER__": h1,
    "__AWG_RESPONSE_PACKET_MAGIC_HEADER__": h2,
    "__AWG_UNDERLOAD_PACKET_MAGIC_HEADER__": h3,
    "__AWG_TRANSPORT_PACKET_MAGIC_HEADER__": h4,
    "__AWG_SPECIAL_JUNK_1__": i1,
    "__AWG_SPECIAL_JUNK_2__": i2,
    "__AWG_SPECIAL_JUNK_3__": i3,
    "__AWG_SPECIAL_JUNK_4__": i4,
    "__AWG_SPECIAL_JUNK_5__": i5,
    "__AWG_PEERS_BLOCK__": "\n\n".join(peer_blocks),
}

with open(server_template, "r", encoding="utf-8") as fh:
    server = fh.read()
for key, value in replacements.items():
    server = server.replace(key, value)

with open(server_conf, "w", encoding="utf-8") as fh:
    fh.write(server.rstrip() + "\n")

setconf_lines = []
for line in server.splitlines():
    key = line.split("=", 1)[0].strip().lower() if "=" in line else ""
    if key in {"address", "dns", "mtu", "table", "preup", "postup", "predown", "postdown", "saveconfig"}:
        continue
    setconf_lines.append(line)
with open(setconf, "w", encoding="utf-8") as fh:
    fh.write("\n".join(setconf_lines).rstrip() + "\n")

with open(client_template, "r", encoding="utf-8") as fh:
    client = fh.read()
for key, value in replacements.items():
    client = client.replace(key, value)
client_lines = []
for line in client.splitlines():
    if "=" in line:
        key, value = line.split("=", 1)
        if key.strip() in {"I1", "I2", "I3", "I4", "I5"} and not value.strip():
            continue
    client_lines.append(line)
with open(exported_client_template, "w", encoding="utf-8") as fh:
    fh.write("\n".join(client_lines).rstrip() + "\n")
PY
    chmod 0600 "$SERVER_CONF" "$SETCONF"
    chmod 0644 "$EXPORTED_CLIENT_TEMPLATE"
}

publish_compatibility_view() {
    rm -f "$AMNEZIA_DIR/awg0.conf" \
        "$AMNEZIA_DIR/clients.json" \
        "$AMNEZIA_DIR/settings.json" \
        "$AMNEZIA_DIR/client.template.conf" \
        "$AMNEZIA_DIR/wireguard_server_private_key.key" \
        "$AMNEZIA_DIR/wireguard_server_public_key.key" \
        "$AMNEZIA_DIR/wireguard_psk.key"

    ln -s "$SERVER_CONF" "$AMNEZIA_DIR/awg0.conf"
    ln -s "$CLIENTS_JSON" "$AMNEZIA_DIR/clients.json"
    ln -s "$SETTINGS_JSON" "$AMNEZIA_DIR/settings.json"
    ln -s "$EXPORTED_CLIENT_TEMPLATE" "$AMNEZIA_DIR/client.template.conf"
    ln -s "$SERVER_PRIVATE_KEY_FILE" "$AMNEZIA_DIR/wireguard_server_private_key.key"
    ln -s "$SERVER_PUBLIC_KEY_FILE" "$AMNEZIA_DIR/wireguard_server_public_key.key"
    ln -s "$PRESHARED_KEY_FILE" "$AMNEZIA_DIR/wireguard_psk.key"
}

wait_for_interface() {
    local attempt

    for attempt in $(seq 1 30); do
        if ip link show dev "$INTERFACE" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    echo "AWG interface did not appear: $INTERFACE" >&2
    return 1
}

setup_interface() {
    ip link delete dev "$INTERFACE" >/dev/null 2>&1 || true

    amneziawg-go "$INTERFACE"
    wait_for_interface
    awg setconf "$INTERFACE" "$SETCONF"
    ip address add "$SERVER_ADDRESS" dev "$INTERFACE"
    ip link set dev "$INTERFACE" mtu "$MTU" up
}

setup_firewall() {
    if ! is_true "$NAT_ENABLED"; then
        return
    fi

    iptables -C INPUT -i "$INTERFACE" -j ACCEPT 2>/dev/null || iptables -A INPUT -i "$INTERFACE" -j ACCEPT
    iptables -C FORWARD -i "$INTERFACE" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$INTERFACE" -j ACCEPT
    iptables -C OUTPUT -o "$INTERFACE" -j ACCEPT 2>/dev/null || iptables -A OUTPUT -o "$INTERFACE" -j ACCEPT
    iptables -C FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

    for outgoing in eth0 eth1; do
        if ip link show dev "$outgoing" >/dev/null 2>&1; then
            iptables -C FORWARD -i "$INTERFACE" -o "$outgoing" -s "$SUBNET_ADDRESS/$SUBNET_CIDR" -j ACCEPT 2>/dev/null \
                || iptables -A FORWARD -i "$INTERFACE" -o "$outgoing" -s "$SUBNET_ADDRESS/$SUBNET_CIDR" -j ACCEPT
            iptables -t nat -C POSTROUTING -s "$SUBNET_ADDRESS/$SUBNET_CIDR" -o "$outgoing" -j MASQUERADE 2>/dev/null \
                || iptables -t nat -A POSTROUTING -s "$SUBNET_ADDRESS/$SUBNET_CIDR" -o "$outgoing" -j MASQUERADE
        fi
    done
}

cleanup() {
    ip link delete dev "$INTERFACE" >/dev/null 2>&1 || true
}

if ! validate_port "$LISTEN_PORT"; then
    echo "Invalid AWG_LISTEN_PORT: $LISTEN_PORT" >&2
    exit 1
fi
if ! validate_port "$PUBLISHED_PORT"; then
    echo "Invalid AWG_PUBLISHED_PORT: $PUBLISHED_PORT" >&2
    exit 1
fi

mkdir -p "$STATE_DIR" "$AMNEZIA_DIR"
derive_server_address

if [ -n "$COMPAT_STATE_DIR" ]; then
    link_or_copy_compat_keys
else
    generate_keys
fi

ensure_clients_json
write_settings_json
render_configs
publish_compatibility_view

trap cleanup INT TERM EXIT
setup_interface
setup_firewall

echo "awg state dir: $STATE_DIR"
if [ -n "$COMPAT_STATE_DIR" ]; then
    echo "awg compatibility state dir: $COMPAT_STATE_DIR"
else
    echo "awg compatibility state dir: none"
fi
echo "awg interface: $INTERFACE"
echo "awg listen port: $LISTEN_PORT"
echo "awg published port: $PUBLISHED_PORT"
echo "awg server address: $SERVER_ADDRESS"

"$@" &
wait "$!"
