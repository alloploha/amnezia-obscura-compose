#!/usr/bin/env bash
set -euo pipefail

if [ -z "${PYTHON_BIN:-}" ]; then
    if python3 -c 'print("ok")' >/dev/null 2>&1; then
        PYTHON_BIN=python3
    elif python -c 'print("ok")' >/dev/null 2>&1; then
        PYTHON_BIN=python
    else
        printf 'ERROR: required command not found: python3 or python\n' >&2
        exit 1
    fi
fi
export PYTHONPATH="blacklist/libexec${PYTHONPATH:+:$PYTHONPATH}"

"$PYTHON_BIN" - <<'PY'
import json
import tempfile
from pathlib import Path

from obscura_blacklist.config import LoadedConfig
from obscura_blacklist.desired import build_desired_state, desired_state_to_payload
from obscura_blacklist.inspect import (
    BackendInfo,
    CategoryInfo,
    DockerInfo,
    DockerNetwork,
    Inspection,
    StateInfo,
)
import obscura_blacklist.desired as desired_mod


with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    config = LoadedConfig(
        config_path=root / "blacklist.conf",
        values={
            "BLACKLIST_BACKEND": "nftables",
            "BLACKLIST_RULE_DIRECTION": "dst",
            "BLACKLIST_IPTABLES_CHAIN": "DOCKER-USER",
            "BLACKLIST_NFT_TABLE": "inet obscura_blacklist",
            "BLACKLIST_NFT_CHAIN": "forward",
            "BLACKLIST_REQUIRE_NONEMPTY": "1",
            "BLACKLIST_ALLOW_STALE_RESTORE": "1",
            "BLACKLIST_MAX_STALE_AGE": str(7 * 24 * 60 * 60),
            "BLACKLIST_FAIL_IF_ALL_STALE": "0",
        },
        configured_sources_dir=root / "sources",
        configured_state_dir=root / "state",
        configured_cache_dir=root / "cache",
        effective_sources_dir=root / "sources",
        effective_state_dir=root / "state",
        effective_cache_dir=root / "cache",
        using_repo_fallback=False,
    )
    docker = DockerInfo(
        binary_path="/usr/bin/docker",
        daemon_reachable=True,
        server_version="fixture",
        networks=(DockerNetwork("abcdef123456", "bridge", "bridge", "docker0"),),
    )
    backend = BackendInfo(
        mode="nftables",
        selected="nftables",
        variant="native",
        selection_reason="fixture",
        selection_confidence="fixture",
        docker_firewall_evidence="fixture",
        docker_firewall_reason="fixture",
        available_commands={"nft": "/usr/sbin/nft"},
        iptables_candidate=False,
        iptables_backend_usable=False,
        nft_candidate=True,
        nft_backend_usable=True,
        iptables_variant=None,
        warnings=(),
        problems=(),
    )
    categories = (
        CategoryInfo(
            kind="domains",
            name="blocked",
            path=root / "sources" / "domains-blocked.txt",
            accepted_entries=("blocked.example",),
            ignored_wildcards=("*.ignored.example",),
            invalid_entries=("bad domain",),
        ),
        CategoryInfo(
            kind="asns",
            name="networks",
            path=root / "sources" / "asns-networks.txt",
            accepted_entries=("AS64500",),
            ignored_wildcards=(),
            invalid_entries=("ASnotnum",),
        ),
    )
    state = StateInfo(
        metadata_path=root / "state" / "last_apply.json",
        present=False,
        payload=None,
        targets_path=root / "state" / "last_good_targets.json",
        targets_present=False,
        targets_payload=None,
        health_path=root / "state" / "health.json",
        health_present=False,
        health_payload=None,
    )
    inspection = Inspection(
        config=config,
        docker=docker,
        backend=backend,
        categories=categories,
        source_warnings=(),
        source_errors=(),
        state=state,
    )

    original_domain = desired_mod._resolve_domain
    original_asn = desired_mod._resolve_asn
    desired_mod._resolve_domain = lambda domain, **_: (("203.0.113.10", "10.1.2.3"), ("2001:db8::10", "fc00::1"))
    desired_mod._resolve_asn = lambda asn, cache_dir, warnings: (("198.51.100.0/24", "192.168.1.0/24"), ("2001:db8:1::/48",))
    try:
        desired, warnings = build_desired_state(inspection)
    finally:
        desired_mod._resolve_domain = original_domain
        desired_mod._resolve_asn = original_asn

    payload = desired_state_to_payload(desired)
    assert payload["backend_family"] == "nftables"
    assert payload["total_ipv4_entries"] == 2, payload
    assert payload["total_ipv6_entries"] == 2, payload
    assert payload["docker_bridge_interfaces"] == ("docker0",)

    domains = payload["categories"][0]
    asns = payload["categories"][1]
    assert domains["kind"] == "domains"
    assert domains["ignored_wildcards"] == ("*.ignored.example",)
    assert domains["invalid_entries"] == ("bad domain",)
    assert "10.1.2.3" not in domains["ipv4_entries"]
    assert "fc00::1" not in domains["ipv6_entries"]
    assert asns["kind"] == "asns"
    assert "192.168.1.0/24" not in asns["ipv4_entries"]
    assert any("ignoring local/reserved target" in warning for warning in warnings)

print("PASS: blacklist fixture desired-state rendering")
PY
