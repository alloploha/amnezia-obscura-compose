"""Desired-state builder for obscura-blacklist."""

from __future__ import annotations

import hashlib
import ipaddress
import json
import socket
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterable
from urllib.error import URLError
from urllib.request import Request, urlopen

from obscura_blacklist.config import LoadedConfig
from obscura_blacklist.inspect import CategoryInfo, Inspection

ASN_CACHE_TTL_SECONDS = 24 * 60 * 60
HTTP_TIMEOUT_SECONDS = 15
MANIFEST_VERSION = 1
ASN_PREFIXES_URL = "https://stat.ripe.net/data/announced-prefixes/data.json?resource={asn}"
TraceFn = Callable[[str], None]

LOCAL_NETWORKS_V4 = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("100.64.0.0/10"),
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
)
LOCAL_NETWORKS_V6 = (
    ipaddress.ip_network("::1/128"),
    ipaddress.ip_network("fc00::/7"),
    ipaddress.ip_network("fe80::/10"),
)


@dataclass(frozen=True)
class DesiredCategory:
    kind: str
    name: str
    source_path: str
    accepted_entries: tuple[str, ...]
    ignored_wildcards: tuple[str, ...]
    invalid_entries: tuple[str, ...]
    resolved_entry_count: int
    unresolved_entry_count: int
    ipv4_entries: tuple[str, ...]
    ipv6_entries: tuple[str, ...]
    set_name_v4: str
    set_name_v6: str
    rule_comment_v4: str
    rule_comment_v6: str


@dataclass(frozen=True)
class DesiredState:
    manifest_version: int
    generated_at: str
    config_path: str
    backend_family: str
    backend_variant: str | None
    selection_reason: str | None
    selection_confidence: str | None
    docker_firewall_evidence: str
    docker_firewall_reason: str | None
    docker_bridge_interfaces: tuple[str, ...]
    rule_direction: str
    iptables_chain: str
    nft_table_family: str
    nft_table_name: str
    nft_chain_name: str
    categories: tuple[DesiredCategory, ...]
    total_ipv4_entries: int
    total_ipv6_entries: int


def parse_nft_table_spec(spec: str) -> tuple[str, str]:
    parts = spec.split()
    if len(parts) != 2:
        raise ValueError(
            f"BLACKLIST_NFT_TABLE must be '<family> <name>', got {spec!r}"
        )
    family, name = parts
    if family not in {"ip", "ip6", "inet"}:
        raise ValueError(f"Unsupported nft table family: {family!r}")
    return family, name


def _stable_object_name(kind: str, category_name: str, family: str) -> str:
    kind_short = "dom" if kind == "domains" else "asn"
    slug = "".join(ch if ch.isalnum() else "_" for ch in category_name.lower()).strip("_")
    slug = slug[:8] or "cat"
    digest = hashlib.sha1(f"{kind}:{category_name}:{family}".encode("utf-8")).hexdigest()[:8]
    return f"obl_{kind_short}_{slug}_{family}_{digest}"[:31]


def _rule_comment(kind: str, category_name: str, family: str) -> str:
    return f"obscura-blacklist:{kind}:{category_name}:{family}"


def _sort_networks(entries: Iterable[str]) -> tuple[str, ...]:
    normalized = []
    seen: set[str] = set()
    for entry in entries:
        try:
            network = ipaddress.ip_network(entry, strict=False)
        except ValueError:
            continue
        value = str(network if "/" in entry else network.network_address)
        if value in seen:
            continue
        seen.add(value)
        normalized.append(network if "/" in entry else ipaddress.ip_address(value))

    normalized.sort(
        key=lambda item: (
            item.version,
            item.network_address if isinstance(item, (ipaddress.IPv4Network, ipaddress.IPv6Network)) else item,
            item.prefixlen if isinstance(item, (ipaddress.IPv4Network, ipaddress.IPv6Network)) else item.max_prefixlen,
        )
    )

    rendered: list[str] = []
    for item in normalized:
        if isinstance(item, (ipaddress.IPv4Network, ipaddress.IPv6Network)):
            rendered.append(str(item.network_address if item.prefixlen == item.max_prefixlen else item))
        else:
            rendered.append(str(item))
    return tuple(rendered)


def _filter_local_networks(
    entries: Iterable[str],
    *,
    category: CategoryInfo,
    warnings: list[str],
) -> tuple[str, ...]:
    kept: list[str] = []
    for entry in entries:
        try:
            network = ipaddress.ip_network(entry, strict=False)
        except ValueError:
            continue
        local_ranges = LOCAL_NETWORKS_V4 if network.version == 4 else LOCAL_NETWORKS_V6
        if any(network.subnet_of(local_range) for local_range in local_ranges):
            warnings.append(
                f"{category.path.name}: ignoring local/reserved target {entry}"
            )
            continue
        kept.append(entry)
    return _sort_networks(kept)


def _resolve_domain(domain: str) -> tuple[tuple[str, ...], tuple[str, ...]]:
    query_name = domain.encode("idna").decode("ascii")
    ipv4: set[str] = set()
    ipv6: set[str] = set()

    for family in (socket.AF_INET, socket.AF_INET6):
        try:
            records = socket.getaddrinfo(query_name, None, family=family, type=socket.SOCK_STREAM)
        except socket.gaierror:
            continue
        for record in records:
            addr = record[4][0]
            if family == socket.AF_INET:
                ipv4.add(addr)
            else:
                ipv6.add(addr)

    return _sort_networks(ipv4), _sort_networks(ipv6)


def _asn_cache_path(cache_dir: Path, asn: str) -> Path:
    return cache_dir / f"{asn}.json"


def _load_cached_asn(cache_path: Path) -> dict[str, object] | None:
    if not cache_path.exists():
        return None
    try:
        return json.loads(cache_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def _cache_fresh(payload: dict[str, object], now: float) -> bool:
    fetched_at = payload.get("fetched_at")
    if not isinstance(fetched_at, (int, float)):
        return False
    return now - float(fetched_at) < ASN_CACHE_TTL_SECONDS


def _fetch_asn_prefixes(asn: str) -> tuple[tuple[str, ...], tuple[str, ...]]:
    request = Request(
        ASN_PREFIXES_URL.format(asn=asn),
        headers={"User-Agent": "obscura-blacklist/0.1"},
    )
    with urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
        payload = json.loads(response.read().decode("utf-8"))

    prefixes = payload.get("data", {}).get("prefixes", [])
    ipv4: list[str] = []
    ipv6: list[str] = []
    for item in prefixes:
        prefix = item.get("prefix")
        if not isinstance(prefix, str):
            continue
        try:
            network = ipaddress.ip_network(prefix, strict=False)
        except ValueError:
            continue
        if network.version == 4:
            ipv4.append(str(network))
        else:
            ipv6.append(str(network))

    return _sort_networks(ipv4), _sort_networks(ipv6)


def _resolve_asn(
    asn: str,
    cache_dir: Path,
    warnings: list[str],
) -> tuple[tuple[str, ...], tuple[str, ...]]:
    cache_path = _asn_cache_path(cache_dir, asn)
    now = time.time()
    cached = _load_cached_asn(cache_path)
    if cached and _cache_fresh(cached, now):
        return (
            tuple(cached.get("ipv4", [])),
            tuple(cached.get("ipv6", [])),
        )

    try:
        ipv4, ipv6 = _fetch_asn_prefixes(asn)
    except (OSError, ValueError, URLError) as exc:
        if cached:
            warnings.append(
                f"{asn}: failed to refresh ASN prefixes, using stale cache ({exc})"
            )
            return (
                tuple(cached.get("ipv4", [])),
                tuple(cached.get("ipv6", [])),
            )
        raise RuntimeError(f"{asn}: failed to fetch ASN prefixes: {exc}") from exc

    cache_path.write_text(
        json.dumps(
            {
                "asn": asn,
                "fetched_at": now,
                "ipv4": list(ipv4),
                "ipv6": list(ipv6),
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    return ipv4, ipv6


def _bool_from_config(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _resolve_category(
    category: CategoryInfo,
    config: LoadedConfig,
    cache_dir: Path,
    warnings: list[str],
    trace: TraceFn | None = None,
) -> DesiredCategory:
    ipv4_entries: list[str] = []
    ipv6_entries: list[str] = []
    resolved_entry_count = 0
    unresolved_entry_count = 0

    if trace is not None:
        trace(
            f"Resolving category {category.kind}:{category.name} "
            f"({len(category.accepted_entries)} source entries)"
        )

    if category.kind == "domains":
        for domain in category.accepted_entries:
            resolved_v4, resolved_v6 = _resolve_domain(domain)
            if not resolved_v4 and not resolved_v6:
                warnings.append(f"{category.path.name}: domain did not resolve: {domain}")
                unresolved_entry_count += 1
            else:
                resolved_entry_count += 1
            ipv4_entries.extend(resolved_v4)
            ipv6_entries.extend(resolved_v6)
    else:
        for asn in category.accepted_entries:
            resolved_v4, resolved_v6 = _resolve_asn(asn, cache_dir, warnings)
            if not resolved_v4 and not resolved_v6:
                warnings.append(f"{category.path.name}: ASN returned no prefixes: {asn}")
                unresolved_entry_count += 1
            else:
                resolved_entry_count += 1
            ipv4_entries.extend(resolved_v4)
            ipv6_entries.extend(resolved_v6)

    family_v4 = "v4"
    family_v6 = "v6"
    return DesiredCategory(
        kind=category.kind,
        name=category.name,
        source_path=str(category.path),
        accepted_entries=category.accepted_entries,
        ignored_wildcards=category.ignored_wildcards,
        invalid_entries=category.invalid_entries,
        resolved_entry_count=resolved_entry_count,
        unresolved_entry_count=unresolved_entry_count,
        ipv4_entries=_filter_local_networks(
            ipv4_entries,
            category=category,
            warnings=warnings,
        ),
        ipv6_entries=_filter_local_networks(
            ipv6_entries,
            category=category,
            warnings=warnings,
        ),
        set_name_v4=_stable_object_name(category.kind, category.name, family_v4),
        set_name_v6=_stable_object_name(category.kind, category.name, family_v6),
        rule_comment_v4=_rule_comment(category.kind, category.name, family_v4),
        rule_comment_v6=_rule_comment(category.kind, category.name, family_v6),
    )


def build_desired_state(
    inspection: Inspection,
    *,
    trace: TraceFn | None = None,
) -> tuple[DesiredState, tuple[str, ...]]:
    if inspection.backend.selected is None:
        raise RuntimeError("cannot build desired state without a selected backend")

    rule_direction = inspection.config.values["BLACKLIST_RULE_DIRECTION"].strip().lower()
    if rule_direction not in {"src", "dst"}:
        raise RuntimeError(
            "BLACKLIST_RULE_DIRECTION must be either 'src' or 'dst'"
        )

    state_dir = inspection.config.effective_state_dir
    cache_dir = inspection.config.effective_cache_dir
    state_dir.mkdir(parents=True, exist_ok=True)
    cache_dir.mkdir(parents=True, exist_ok=True)

    warnings: list[str] = []
    if inspection.config.values.get("BLACKLIST_RESOLVER"):
        warnings.append(
            "BLACKLIST_RESOLVER is set, but custom resolver selection is not implemented yet; using system resolver"
        )

    nft_table_family, nft_table_name = parse_nft_table_spec(
        inspection.config.values["BLACKLIST_NFT_TABLE"]
    )

    categories = tuple(
        _resolve_category(
            category,
            inspection.config,
            cache_dir,
            warnings,
            trace=trace,
        )
        for category in inspection.categories
    )

    total_ipv4_entries = sum(len(category.ipv4_entries) for category in categories)
    total_ipv6_entries = sum(len(category.ipv6_entries) for category in categories)
    if _bool_from_config(inspection.config.values["BLACKLIST_REQUIRE_NONEMPTY"]):
        if total_ipv4_entries + total_ipv6_entries == 0:
            raise RuntimeError(
                "BLACKLIST_REQUIRE_NONEMPTY is enabled, but no IPv4 or IPv6 targets were generated"
            )

    bridge_interfaces = tuple(
        network.bridge_interface
        for network in inspection.docker.networks
        if network.driver == "bridge" and network.bridge_interface
    )

    desired = DesiredState(
        manifest_version=MANIFEST_VERSION,
        generated_at=datetime.now(timezone.utc).isoformat(),
        config_path=str(inspection.config.config_path),
        backend_family=inspection.backend.selected,
        backend_variant=inspection.backend.variant,
        selection_reason=inspection.backend.selection_reason,
        selection_confidence=inspection.backend.selection_confidence,
        docker_firewall_evidence=inspection.backend.docker_firewall_evidence,
        docker_firewall_reason=inspection.backend.docker_firewall_reason,
        docker_bridge_interfaces=bridge_interfaces,
        rule_direction=rule_direction,
        iptables_chain=inspection.config.values["BLACKLIST_IPTABLES_CHAIN"],
        nft_table_family=nft_table_family,
        nft_table_name=nft_table_name,
        nft_chain_name=inspection.config.values["BLACKLIST_NFT_CHAIN"],
        categories=categories,
        total_ipv4_entries=total_ipv4_entries,
        total_ipv6_entries=total_ipv6_entries,
    )
    return desired, tuple(warnings)


def desired_state_to_payload(desired: DesiredState) -> dict[str, object]:
    return asdict(desired)


def load_manifest(manifest_path: Path) -> dict[str, object]:
    return json.loads(manifest_path.read_text(encoding="utf-8"))


def save_manifest(manifest_path: Path, desired: DesiredState) -> None:
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(
        json.dumps(desired_state_to_payload(desired), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
