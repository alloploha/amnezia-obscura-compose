"""Inspection helpers for check/status commands."""

from __future__ import annotations

import json
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from obscura_blacklist.config import LoadedConfig

COMMAND_TIMEOUT_SECONDS = 5


@dataclass(frozen=True)
class CommandResult:
    argv: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str


@dataclass(frozen=True)
class DockerNetwork:
    network_id: str
    name: str
    driver: str
    bridge_interface: str | None


@dataclass(frozen=True)
class DockerInfo:
    binary_path: str | None
    daemon_reachable: bool
    server_version: str | None
    networks: tuple[DockerNetwork, ...]
    error: str | None = None


@dataclass(frozen=True)
class BackendInfo:
    mode: str
    selected: str | None
    variant: str | None
    selection_reason: str | None
    selection_confidence: str | None
    docker_firewall_evidence: str
    docker_firewall_reason: str | None
    available_commands: dict[str, str]
    iptables_candidate: bool
    iptables_backend_usable: bool
    nft_candidate: bool
    nft_backend_usable: bool
    iptables_variant: str | None
    warnings: tuple[str, ...]
    problems: tuple[str, ...]
    iptables_chain_v4: str | None = None
    iptables_chain_v6: str | None = None


@dataclass(frozen=True)
class CategoryInfo:
    kind: str
    name: str
    path: Path
    accepted_entries: tuple[str, ...]
    ignored_wildcards: tuple[str, ...]
    invalid_entries: tuple[str, ...]


@dataclass(frozen=True)
class StateInfo:
    metadata_path: Path
    present: bool
    payload: dict[str, object] | None
    error: str | None = None


@dataclass(frozen=True)
class Inspection:
    config: LoadedConfig
    docker: DockerInfo
    backend: BackendInfo
    categories: tuple[CategoryInfo, ...]
    source_warnings: tuple[str, ...]
    source_errors: tuple[str, ...]
    state: StateInfo

    def check_errors(self) -> list[str]:
        errors: list[str] = []
        if not self.docker.binary_path:
            errors.append("docker binary not found")
        elif not self.docker.daemon_reachable:
            errors.append(self.docker.error or "docker daemon is not reachable")

        if self.config.backend_mode not in {"auto", "iptables", "nftables"}:
            errors.append(
                f"unsupported BLACKLIST_BACKEND value: {self.config.values['BLACKLIST_BACKEND']!r}"
            )

        errors.extend(self.backend.problems)
        errors.extend(self.source_errors)
        return errors


def _run(argv: list[str]) -> CommandResult:
    try:
        completed = subprocess.run(
            argv,
            check=False,
            capture_output=True,
            text=True,
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return CommandResult(
            argv=tuple(argv),
            returncode=124,
            stdout="",
            stderr=f"command timed out after {COMMAND_TIMEOUT_SECONDS}s",
        )

    return CommandResult(
        argv=tuple(argv),
        returncode=completed.returncode,
        stdout=completed.stdout.strip(),
        stderr=completed.stderr.strip(),
    )


def _detect_bridge_interface(network_id: str, name: str) -> str:
    if name == "bridge":
        return "docker0"
    return f"br-{network_id[:12]}"


def inspect_docker() -> DockerInfo:
    docker_path = shutil.which("docker")
    if not docker_path:
        return DockerInfo(
            binary_path=None,
            daemon_reachable=False,
            server_version=None,
            networks=(),
            error="docker binary not found in PATH",
        )

    version_result = _run([docker_path, "info", "--format", "{{.ServerVersion}}"])
    if version_result.returncode != 0:
        error = version_result.stderr or "docker info failed"
        return DockerInfo(
            binary_path=docker_path,
            daemon_reachable=False,
            server_version=None,
            networks=(),
            error=error,
        )

    networks_result = _run([docker_path, "network", "ls", "--format", "{{.ID}}\t{{.Name}}\t{{.Driver}}"])
    networks: list[DockerNetwork] = []
    if networks_result.returncode == 0:
        for line in networks_result.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) != 3:
                continue
            network_id, name, driver = parts
            bridge_interface: str | None = None
            if driver == "bridge":
                inspect_result = _run(
                    [
                        docker_path,
                        "network",
                        "inspect",
                        "--format",
                        '{{index .Options "com.docker.network.bridge.name"}}',
                        name,
                    ]
                )
                if inspect_result.returncode == 0 and inspect_result.stdout:
                    bridge_interface = inspect_result.stdout
                else:
                    bridge_interface = _detect_bridge_interface(network_id, name)
            networks.append(
                DockerNetwork(
                    network_id=network_id,
                    name=name,
                    driver=driver,
                    bridge_interface=bridge_interface,
                )
            )

    return DockerInfo(
        binary_path=docker_path,
        daemon_reachable=True,
        server_version=version_result.stdout or None,
        networks=tuple(networks),
    )


def _probe_iptables_chain(binary: str, chain: str) -> str | None:
    result = _run([binary, "-S", chain])
    if result.returncode == 0:
        return "present"
    stderr_lower = result.stderr.lower()
    if "permission denied" in stderr_lower or "operation not permitted" in stderr_lower:
        return "permission_denied"
    if "no chain" in stderr_lower or "does a chain exist" in stderr_lower:
        return "missing"
    return "unknown"


def _detect_iptables_variant(binary: str) -> str:
    result = _run([binary, "-V"])
    if result.returncode != 0:
        return "unknown"

    version_text = f"{result.stdout} {result.stderr}".lower()
    if "nf_tables" in version_text:
        return "nf_tables"
    if "legacy" in version_text:
        return "legacy"
    return "unknown"


def _missing_iptables_requirements(command_map: dict[str, str]) -> list[str]:
    return [name for name in ("iptables", "ip6tables", "ipset") if name not in command_map]


def _probe_nft_docker_evidence(binary: str) -> tuple[str, str | None]:
    result = _run([binary, "list", "ruleset"])
    if result.returncode != 0:
        stderr_lower = result.stderr.lower()
        if "permission denied" in stderr_lower or "operation not permitted" in stderr_lower:
            return "unknown", "nft ruleset could not be inspected without elevated privileges"
        return "unknown", result.stderr or "nft list ruleset failed"

    ruleset = result.stdout.lower()
    markers: list[str] = []
    if "docker-bridges" in ruleset:
        markers.append("docker-bridges")
    if "chain docker-user" in ruleset:
        markers.append("chain docker-user")
    if "jump docker-bridges" in ruleset:
        markers.append("jump docker-bridges")

    if markers:
        return "nftables", f"detected Docker nftables markers: {', '.join(markers)}"

    return "none", "no strong Docker-specific nftables markers found"


def inspect_backend(config: LoadedConfig) -> BackendInfo:
    warnings: list[str] = []
    problems: list[str] = []

    command_map = {
        name: path
        for name in ("iptables", "ip6tables", "ipset", "nft")
        if (path := shutil.which(name)) is not None
    }

    iptables_candidate = "iptables" in command_map and "ip6tables" in command_map
    iptables_missing = _missing_iptables_requirements(command_map)
    iptables_ready = not iptables_missing
    nft_candidate = "nft" in command_map
    nft_ready = nft_candidate

    selected: str | None = None
    variant: str | None = None
    selection_reason: str | None = None
    selection_confidence: str | None = None
    docker_firewall_evidence = "unknown"
    docker_firewall_reason: str | None = None
    mode = config.backend_mode
    iptables_variant: str | None = None

    chain_v4: str | None = None
    chain_v6: str | None = None
    if iptables_candidate:
        v4_variant = _detect_iptables_variant(command_map["iptables"])
        v6_variant = _detect_iptables_variant(command_map["ip6tables"])
        if v4_variant == v6_variant:
            iptables_variant = v4_variant
        elif "unknown" in {v4_variant, v6_variant}:
            iptables_variant = "unknown"
            warnings.append(
                "iptables/ip6tables frontend variant could not be determined consistently"
            )
        else:
            iptables_variant = "mixed"
            warnings.append(
                f"iptables frontend variants differ between IPv4 ({v4_variant}) and IPv6 ({v6_variant})"
            )

        chain = config.values["BLACKLIST_IPTABLES_CHAIN"]
        chain_v4 = _probe_iptables_chain(command_map["iptables"], chain)
        chain_v6 = _probe_iptables_chain(command_map["ip6tables"], chain)

        if chain_v4 == "missing":
            warnings.append(f"iptables chain {chain} not found in IPv4 ruleset")
        elif chain_v4 == "permission_denied":
            warnings.append(f"iptables chain {chain} could not be verified without elevated privileges")

        if chain_v6 == "missing":
            warnings.append(f"ip6tables chain {chain} not found in IPv6 ruleset")
        elif chain_v6 == "permission_denied":
            warnings.append(f"ip6tables chain {chain} could not be verified without elevated privileges")

    nft_evidence_reason: str | None = None
    if chain_v4 == "present" or chain_v6 == "present":
        docker_firewall_evidence = "iptables"
        present_families: list[str] = []
        if chain_v4 == "present":
            present_families.append("IPv4")
        if chain_v6 == "present":
            present_families.append("IPv6")
        docker_firewall_reason = (
            f"{config.values['BLACKLIST_IPTABLES_CHAIN']} exists in the "
            f"{', '.join(present_families)} iptables ruleset"
        )
    elif nft_candidate:
        docker_firewall_evidence, nft_evidence_reason = _probe_nft_docker_evidence(command_map["nft"])
        docker_firewall_reason = nft_evidence_reason
    else:
        docker_firewall_evidence = "none"
        docker_firewall_reason = "no Docker firewall frontend evidence could be inspected"

    if docker_firewall_evidence == "unknown" and chain_v4 == "permission_denied" and chain_v6 == "permission_denied":
        docker_firewall_reason = (
            f"{config.values['BLACKLIST_IPTABLES_CHAIN']} could not be inspected in iptables or nftables without elevated privileges"
        )

    if mode == "auto":
        if docker_firewall_evidence == "iptables":
            if iptables_ready:
                selected = "iptables"
                variant = iptables_variant
                selection_reason = docker_firewall_reason
                selection_confidence = "high"
            else:
                selected = None
                problems.append(
                    "Docker appears to use the iptables frontend, but the iptables backend is not fully usable; "
                    f"missing: {', '.join(iptables_missing)}"
                )
        elif docker_firewall_evidence == "nftables":
            if nft_ready:
                selected = "nftables"
                variant = "native"
                selection_reason = docker_firewall_reason
                selection_confidence = "high"
            else:
                selected = None
                problems.append(
                    "Docker appears to use native nftables, but the nftables backend is not usable; missing: nft"
                )
        else:
            if iptables_ready:
                selected = "iptables"
                variant = iptables_variant
                selection_reason = (
                    "no strong Docker frontend evidence found; preferring iptables as the conservative default"
                )
                selection_confidence = "medium"
            elif nft_ready:
                selected = "nftables"
                variant = "native"
                selection_reason = "iptables backend is not fully usable and native nftables is available"
                selection_confidence = "medium"
            else:
                problems.append(
                    "no supported firewall backend detected; need iptables+ip6tables+ipset or nft"
                )
    elif mode == "iptables":
        if iptables_ready:
            selected = "iptables"
            variant = iptables_variant
            selection_reason = "backend explicitly requested by BLACKLIST_BACKEND=iptables"
            selection_confidence = "explicit"
            if docker_firewall_evidence == "nftables":
                warnings.append(
                    "Docker firewall evidence points to native nftables, but BLACKLIST_BACKEND=iptables was requested"
                )
        else:
            problems.append(
                "BLACKLIST_BACKEND=iptables requires iptables, ip6tables, and ipset"
            )
    elif mode == "nftables":
        if nft_ready:
            selected = "nftables"
            variant = "native"
            selection_reason = "backend explicitly requested by BLACKLIST_BACKEND=nftables"
            selection_confidence = "explicit"
            if docker_firewall_evidence == "iptables":
                warnings.append(
                    "Docker firewall evidence points to the iptables frontend, but BLACKLIST_BACKEND=nftables was requested"
                )
        else:
            problems.append("BLACKLIST_BACKEND=nftables requires nft")

    return BackendInfo(
        mode=mode,
        selected=selected,
        variant=variant,
        selection_reason=selection_reason,
        selection_confidence=selection_confidence,
        docker_firewall_evidence=docker_firewall_evidence,
        docker_firewall_reason=docker_firewall_reason,
        available_commands=command_map,
        iptables_candidate=iptables_candidate,
        iptables_backend_usable=iptables_ready,
        nft_candidate=nft_candidate,
        nft_backend_usable=nft_ready,
        iptables_variant=iptables_variant,
        warnings=tuple(warnings),
        problems=tuple(problems),
        iptables_chain_v4=chain_v4,
        iptables_chain_v6=chain_v6,
    )


def _dedupe_preserve_order(entries: list[str]) -> tuple[str, ...]:
    deduped: list[str] = []
    seen: set[str] = set()
    for entry in entries:
        if entry not in seen:
            seen.add(entry)
            deduped.append(entry)
    return tuple(deduped)


def inspect_sources(config: LoadedConfig) -> tuple[tuple[CategoryInfo, ...], tuple[str, ...], tuple[str, ...]]:
    warnings: list[str] = []
    errors: list[str] = []
    categories: list[CategoryInfo] = []

    sources_dir = config.effective_sources_dir
    if not sources_dir.exists():
        errors.append(f"sources directory not found: {sources_dir}")
        return (), tuple(warnings), tuple(errors)
    if not sources_dir.is_dir():
        errors.append(f"sources path is not a directory: {sources_dir}")
        return (), tuple(warnings), tuple(errors)

    for path in sorted(sources_dir.iterdir()):
        if not path.is_file():
            continue

        if path.name.startswith("domains-"):
            kind = "domains"
            category_name = path.stem[len("domains-") :]
        elif path.name.startswith("asns-"):
            kind = "asns"
            category_name = path.stem[len("asns-") :]
        else:
            warnings.append(f"ignoring unrecognized source file name: {path.name}")
            continue

        accepted_entries: list[str] = []
        ignored_wildcards: list[str] = []
        invalid_entries: list[str] = []

        for line_no, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue

            if kind == "domains":
                domain = line.lower()
                if "*" in domain:
                    ignored_wildcards.append(domain)
                    warnings.append(f"{path.name}:{line_no}: ignoring wildcard domain {domain}")
                    continue
                accepted_entries.append(domain)
                continue

            asn = line.upper()
            if asn.startswith("AS"):
                asn = asn[2:]
            if not asn.isdigit():
                invalid_entries.append(line)
                errors.append(f"{path.name}:{line_no}: invalid ASN entry {line!r}")
                continue
            accepted_entries.append(f"AS{asn}")

        categories.append(
            CategoryInfo(
                kind=kind,
                name=category_name,
                path=path,
                accepted_entries=_dedupe_preserve_order(accepted_entries),
                ignored_wildcards=_dedupe_preserve_order(ignored_wildcards),
                invalid_entries=_dedupe_preserve_order(invalid_entries),
            )
        )

    if not categories:
        errors.append(f"no category source files found in {sources_dir}")

    return tuple(categories), tuple(warnings), tuple(errors)


def inspect_state(config: LoadedConfig) -> StateInfo:
    metadata_path = config.effective_state_dir / "last_apply.json"
    if not metadata_path.exists():
        return StateInfo(metadata_path=metadata_path, present=False, payload=None)

    try:
        payload = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return StateInfo(
            metadata_path=metadata_path,
            present=True,
            payload=None,
            error=str(exc),
        )

    return StateInfo(
        metadata_path=metadata_path,
        present=True,
        payload=payload,
    )


def inspect_runtime(config: LoadedConfig) -> Inspection:
    docker = inspect_docker()
    backend = inspect_backend(config)
    categories, source_warnings, source_errors = inspect_sources(config)
    state = inspect_state(config)
    return Inspection(
        config=config,
        docker=docker,
        backend=backend,
        categories=categories,
        source_warnings=source_warnings,
        source_errors=source_errors,
        state=state,
    )
