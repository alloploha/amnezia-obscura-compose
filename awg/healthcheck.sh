#!/bin/sh
set -eu

INTERFACE="${AWG_INTERFACE:-awg0}"
CFG="/opt/amnezia/awg/awg0.conf"

[ -s "$CFG" ]
kill -0 1
ip link show dev "$INTERFACE" >/dev/null 2>&1
awg show "$INTERFACE" >/dev/null 2>&1
