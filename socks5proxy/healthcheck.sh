#!/bin/sh
set -eu

CFG=/usr/local/3proxy/conf/3proxy.cfg

[ -s "$CFG" ]
kill -0 1

PORT="$(sed -n 's/.*-p\([0-9][0-9]*\).*/\1/p' "$CFG" | tail -n 1)"

case "$PORT" in
    ''|*[!0-9]*)
        exit 1
        ;;
esac

PORT_HEX="$(printf '%04X' "$PORT")"

is_listening() {
    awk -v port="$PORT_HEX" '
        NR > 1 {
            split($2, local, ":")
            if (toupper(local[2]) == port && $4 == "0A") {
                found = 1
            }
        }
        END {
            exit(found ? 0 : 1)
        }
    ' "$1"
}

is_listening /proc/net/tcp || is_listening /proc/net/tcp6
