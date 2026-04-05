"""CLI scaffold for obscura-blacklist."""

from __future__ import annotations

import sys
from pathlib import Path

from obscura_blacklist import __version__
from obscura_blacklist.backends import (
    BackendCommandError,
    apply_desired_state,
    flush_state,
    verify_manifest,
)
from obscura_blacklist.contract import COMMANDS, NOT_IMPLEMENTED
from obscura_blacklist.config import load_config
from obscura_blacklist.desired import (
    build_desired_state,
    load_manifest,
    parse_nft_table_spec,
    save_manifest,
)
from obscura_blacklist.inspect import Inspection, inspect_runtime


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG = REPO_ROOT / "config" / "blacklist.conf"


def _usage() -> str:
    commands = "\n".join(f"  {name:<18} {desc}" for name, desc in COMMANDS.items())
    return (
        "Usage: obscura-blacklist [--config PATH] <command>\n\n"
        "Host-side Docker egress blacklist CLI.\n\n"
        "Commands:\n"
        f"{commands}\n"
    )


def _print_commands() -> int:
    for name, desc in COMMANDS.items():
        print(f"{name}\t{desc}")
    return 0


def _print_default_config() -> int:
    print(DEFAULT_CONFIG.read_text(encoding="utf-8"), end="")
    return 0


def _load_inspection(config_path: Path) -> Inspection:
    config = load_config(config_path=config_path, repo_root=REPO_ROOT)
    return inspect_runtime(config)


def _print_check(inspection: Inspection) -> int:
    print(f"Config: {inspection.config.config_path}")
    if inspection.config.using_repo_fallback:
        print("Mode: repo-local scaffold paths active")
    print(f"Sources: {inspection.config.effective_sources_dir}")
    print(f"State: {inspection.config.effective_state_dir}")
    print(f"Cache: {inspection.config.effective_cache_dir}")
    print(f"Backend mode: {inspection.backend.mode}")

    if inspection.docker.binary_path:
        print(f"Docker binary: {inspection.docker.binary_path}")
    else:
        print("Docker binary: missing")

    if inspection.docker.daemon_reachable:
        print(f"Docker daemon: reachable ({inspection.docker.server_version or 'unknown version'})")
    else:
        print(f"Docker daemon: unavailable ({inspection.docker.error or 'unknown error'})")

    print(f"Backend detected: {inspection.backend.selected or 'none'}")
    if inspection.backend.variant:
        print(f"Backend variant: {inspection.backend.variant}")
    print(f"Docker firewall evidence: {inspection.backend.docker_firewall_evidence}")
    if inspection.backend.docker_firewall_reason:
        print(f"Docker firewall reason: {inspection.backend.docker_firewall_reason}")
    print(
        "Backend candidates: "
        f"iptables={'yes' if inspection.backend.iptables_candidate else 'no'}, "
        f"nft={'yes' if inspection.backend.nft_candidate else 'no'}"
    )
    print(
        "Backend usable: "
        f"iptables={'yes' if inspection.backend.iptables_backend_usable else 'no'}, "
        f"nft={'yes' if inspection.backend.nft_backend_usable else 'no'}"
    )
    if inspection.backend.iptables_variant:
        print(f"iptables frontend variant: {inspection.backend.iptables_variant}")
    if inspection.backend.selection_reason:
        print(f"Selection reason: {inspection.backend.selection_reason}")
    if inspection.backend.selection_confidence:
        print(f"Selection confidence: {inspection.backend.selection_confidence}")

    if inspection.backend.available_commands:
        print(
            "Available firewall commands: "
            + ", ".join(
                f"{name}={path}" for name, path in sorted(inspection.backend.available_commands.items())
            )
        )
    else:
        print("Available firewall commands: none")

    print(f"Categories: {len(inspection.categories)}")
    for category in inspection.categories:
        print(
            f"  - {category.kind}:{category.name} entries={len(category.accepted_entries)}"
            f" wildcards_ignored={len(category.ignored_wildcards)}"
            f" invalid={len(category.invalid_entries)}"
        )

    for warning in inspection.backend.warnings + inspection.source_warnings:
        print(f"WARNING: {warning}")

    errors = inspection.check_errors()
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)

    return 0 if not errors else 1


def _print_status(inspection: Inspection) -> int:
    print(f"Config file: {inspection.config.config_path}")
    print(f"Configured sources dir: {inspection.config.configured_sources_dir}")
    print(f"Effective sources dir: {inspection.config.effective_sources_dir}")
    print(f"Configured state dir: {inspection.config.configured_state_dir}")
    print(f"Effective state dir: {inspection.config.effective_state_dir}")
    print(f"Configured cache dir: {inspection.config.configured_cache_dir}")
    print(f"Effective cache dir: {inspection.config.effective_cache_dir}")
    print(f"Using repo fallback: {'yes' if inspection.config.using_repo_fallback else 'no'}")
    print()

    print(f"Docker binary: {inspection.docker.binary_path or 'missing'}")
    print(f"Docker daemon reachable: {'yes' if inspection.docker.daemon_reachable else 'no'}")
    if inspection.docker.server_version:
        print(f"Docker server version: {inspection.docker.server_version}")
    if inspection.docker.error:
        print(f"Docker error: {inspection.docker.error}")

    bridge_networks = [network for network in inspection.docker.networks if network.driver == "bridge"]
    if bridge_networks:
        print("Docker bridge networks:")
        for network in bridge_networks:
            print(f"  - {network.name} id={network.network_id} iface={network.bridge_interface or 'unknown'}")
    else:
        print("Docker bridge networks: none discovered")
    print()

    print(f"Backend mode: {inspection.backend.mode}")
    print(f"Backend selected: {inspection.backend.selected or 'none'}")
    print(f"Backend variant: {inspection.backend.variant or 'unknown'}")
    print(f"Docker firewall evidence: {inspection.backend.docker_firewall_evidence}")
    print(f"Docker firewall reason: {inspection.backend.docker_firewall_reason or 'none'}")
    print(
        "Backend candidates: "
        f"iptables={'yes' if inspection.backend.iptables_candidate else 'no'}, "
        f"nft={'yes' if inspection.backend.nft_candidate else 'no'}"
    )
    print(
        "Backend usable: "
        f"iptables={'yes' if inspection.backend.iptables_backend_usable else 'no'}, "
        f"nft={'yes' if inspection.backend.nft_backend_usable else 'no'}"
    )
    print(f"iptables frontend variant: {inspection.backend.iptables_variant or 'unknown'}")
    print(f"Selection reason: {inspection.backend.selection_reason or 'none'}")
    print(f"Selection confidence: {inspection.backend.selection_confidence or 'none'}")
    if inspection.backend.available_commands:
        print(
            "Backend command paths: "
            + ", ".join(
                f"{name}={path}" for name, path in sorted(inspection.backend.available_commands.items())
            )
        )
    else:
        print("Backend command paths: none")
    if inspection.backend.iptables_chain_v4:
        print(f"iptables chain probe (IPv4): {inspection.backend.iptables_chain_v4}")
    if inspection.backend.iptables_chain_v6:
        print(f"iptables chain probe (IPv6): {inspection.backend.iptables_chain_v6}")
    for warning in inspection.backend.warnings:
        print(f"Backend warning: {warning}")
    for problem in inspection.backend.problems:
        print(f"Backend problem: {problem}")
    print()

    print(f"Categories discovered: {len(inspection.categories)}")
    for category in inspection.categories:
        print(
            f"  - {category.kind}:{category.name} path={category.path.name} "
            f"entries={len(category.accepted_entries)} "
            f"wildcards_ignored={len(category.ignored_wildcards)} "
            f"invalid={len(category.invalid_entries)}"
        )
    for warning in inspection.source_warnings:
        print(f"Source warning: {warning}")
    for error in inspection.source_errors:
        print(f"Source error: {error}")
    print()

    print(f"Last apply metadata path: {inspection.state.metadata_path}")
    if inspection.state.present and inspection.state.payload is not None:
        print("Last apply metadata: present")
        for key, value in inspection.state.payload.items():
            print(f"  {key}: {value}")
    elif inspection.state.present and inspection.state.error:
        print(f"Last apply metadata: unreadable ({inspection.state.error})")
    else:
        print("Last apply metadata: absent")

    return 0


def _trace(message: str) -> None:
    print(message, flush=True)


def _print_apply(inspection: Inspection) -> int:
    errors = inspection.check_errors()
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    if inspection.state.present and inspection.state.error:
        print(
            f"ERROR: existing manifest is unreadable: {inspection.state.error}",
            file=sys.stderr,
        )
        return 1

    try:
        _trace("Building desired state from sources")
        desired, warnings = build_desired_state(inspection, trace=_trace)
        _trace(
            f"Desired state ready: backend={desired.backend_family}, "
            f"categories={len(desired.categories)}, ipv4={desired.total_ipv4_entries}, "
            f"ipv6={desired.total_ipv6_entries}"
        )
        _trace("Applying backend state")
        messages = apply_desired_state(desired, inspection.state.payload, trace=_trace)
        _trace("Persisting manifest")
        save_manifest(inspection.state.metadata_path, desired)
    except (BackendCommandError, OSError, RuntimeError, ValueError) as exc:
        print(f"ERROR: apply failed: {exc}", file=sys.stderr)
        return 1

    print(f"Applied backend: {desired.backend_family}")
    print(f"Backend variant: {desired.backend_variant or 'unknown'}")
    print(f"Categories applied: {len(desired.categories)}")
    print(f"IPv4 entries: {desired.total_ipv4_entries}")
    print(f"IPv6 entries: {desired.total_ipv6_entries}")
    print(f"Manifest written: {inspection.state.metadata_path}")
    if desired.docker_bridge_interfaces:
        print("Docker bridge interfaces: " + ", ".join(desired.docker_bridge_interfaces))
    else:
        print("Docker bridge interfaces: none detected")

    for message in messages:
        print(f"INFO: {message}")
    for warning in inspection.backend.warnings + inspection.source_warnings + warnings:
        print(f"WARNING: {warning}")
    return 0


def _print_verify(inspection: Inspection) -> int:
    manifest_path = inspection.state.metadata_path
    if not manifest_path.exists():
        print(f"ERROR: no manifest found at {manifest_path}", file=sys.stderr)
        return 1

    try:
        payload = load_manifest(manifest_path)
    except (OSError, ValueError) as exc:
        print(f"ERROR: failed to read manifest: {exc}", file=sys.stderr)
        return 1

    try:
        errors = verify_manifest(payload)
    except (BackendCommandError, OSError, RuntimeError, ValueError) as exc:
        print(f"ERROR: verify failed: {exc}", file=sys.stderr)
        return 1

    print(f"Manifest: {manifest_path}")
    print(f"Backend family: {payload.get('backend_family')}")
    print(f"Backend variant: {payload.get('backend_variant') or 'unknown'}")
    print(f"Generated at: {payload.get('generated_at')}")

    if inspection.backend.selected and inspection.backend.selected != payload.get("backend_family"):
        print(
            "WARNING: current backend auto-detection does not match the manifest backend "
            f"({inspection.backend.selected} vs {payload.get('backend_family')})"
        )
    for warning in inspection.backend.warnings:
        print(f"WARNING: {warning}")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print("Verification succeeded.")
    return 0


def _print_flush(inspection: Inspection) -> int:
    manifest_path = inspection.state.metadata_path
    manifest_payload = None

    if inspection.state.present and inspection.state.error:
        print(
            f"ERROR: existing manifest is unreadable: {inspection.state.error}",
            file=sys.stderr,
        )
        return 1

    if manifest_path.exists():
        try:
            manifest_payload = load_manifest(manifest_path)
        except (OSError, ValueError) as exc:
            print(f"ERROR: failed to read manifest: {exc}", file=sys.stderr)
            return 1

    try:
        nft_family, nft_table = parse_nft_table_spec(
            inspection.config.values["BLACKLIST_NFT_TABLE"]
        )
        messages = flush_state(
            manifest_payload=manifest_payload,
            selected_backend=inspection.backend.selected,
            configured_chain=inspection.config.values["BLACKLIST_IPTABLES_CHAIN"],
            configured_nft_family=nft_family,
            configured_nft_table=nft_table,
        )
    except (BackendCommandError, OSError, RuntimeError, ValueError) as exc:
        print(f"ERROR: flush failed: {exc}", file=sys.stderr)
        return 1

    print("Flush completed.")
    if manifest_payload is not None and manifest_path.exists():
        try:
            manifest_path.unlink()
            print(f"Removed manifest: {manifest_path}")
        except OSError as exc:
            print(f"WARNING: failed to remove manifest {manifest_path}: {exc}")
    elif manifest_payload is None:
        print("No manifest was present; used backend-specific fallback cleanup.")

    for message in messages:
        print(f"INFO: {message}")
    return 0


def _not_implemented(command: str) -> int:
    print(
        f"Command '{command}' is part of the blacklist module contract but is not implemented yet.",
        file=sys.stderr,
    )
    return 3


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    config_path = DEFAULT_CONFIG

    while args[:1] and args[0] == "--config":
        if len(args) < 2:
            print("Missing value for --config", file=sys.stderr)
            return 64
        config_path = Path(args[1]).expanduser()
        args = args[2:]

    if not args or args[0] in {"help", "-h", "--help"}:
        print(_usage(), end="")
        return 0

    if args[0] in {"version", "--version"}:
        print(__version__)
        return 0

    command = args[0]
    if command not in COMMANDS:
        print(f"Unknown command: {command}", file=sys.stderr)
        print(_usage(), file=sys.stderr, end="")
        return 64

    if command == "commands":
        return _print_commands()

    if command == "print-default-config":
        return _print_default_config()

    try:
        inspection = _load_inspection(config_path)
    except (OSError, ValueError) as exc:
        print(f"Failed to load blacklist configuration: {exc}", file=sys.stderr)
        return 1

    if command == "check":
        return _print_check(inspection)

    if command == "status":
        return _print_status(inspection)

    if command == "apply":
        return _print_apply(inspection)

    if command == "verify":
        return _print_verify(inspection)

    if command == "flush":
        return _print_flush(inspection)

    if command in NOT_IMPLEMENTED:
        return _not_implemented(command)

    print(f"Unhandled command state: {command}", file=sys.stderr)
    return 70
