"""Backend apply and verify engines for obscura-blacklist."""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess

from obscura_blacklist.desired import DesiredCategory, DesiredState


class BackendCommandError(RuntimeError):
    """Raised when an external backend command fails."""


def require_root(command_name: str) -> None:
    if os.geteuid() != 0:
        raise RuntimeError(f"{command_name} requires root privileges")


def _run(
    argv: list[str],
    *,
    input_text: str | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        argv,
        input=input_text,
        check=False,
        capture_output=True,
        text=True,
    )
    if check and completed.returncode != 0:
        stderr = completed.stderr.strip()
        stdout = completed.stdout.strip()
        message = stderr or stdout or f"command failed with exit code {completed.returncode}"
        raise BackendCommandError(f"{' '.join(argv)}: {message}")
    return completed


def _manifest_categories(payload: dict[str, object]) -> list[dict[str, object]]:
    raw_categories = payload.get("categories", [])
    if not isinstance(raw_categories, list):
        return []
    return [category for category in raw_categories if isinstance(category, dict)]


def _temp_set_name(name: str) -> str:
    return f"{name[:26]}_tmp"


def _ipset_family_name(family: str) -> str:
    if family == "v4":
        return "inet"
    if family == "v6":
        return "inet6"
    raise ValueError(f"Unsupported family for ipset: {family}")


def _iptables_binary(family: str) -> str:
    return "iptables" if family == "v4" else "ip6tables"


def _iptables_rule_argv(
    binary: str,
    action: str,
    chain: str,
    set_name: str,
    direction: str,
    comment: str,
) -> list[str]:
    return [
        binary,
        action,
        chain,
        "-m",
        "comment",
        "--comment",
        comment,
        "-m",
        "set",
        "--match-set",
        set_name,
        direction,
        "-j",
        "DROP",
    ]


def _iptables_base_accept_argv(binary: str, action: str, chain: str) -> list[str]:
    return [
        binary,
        action,
        chain,
        "-m",
        "conntrack",
        "--ctstate",
        "RELATED,ESTABLISHED",
        "-j",
        "ACCEPT",
    ]


def _iptables_base_return_argv(binary: str, action: str, chain: str) -> list[str]:
    return [binary, action, chain, "-j", "RETURN"]


def _ensure_iptables_rule(
    binary: str,
    chain: str,
    set_name: str,
    direction: str,
    comment: str,
    *,
    before_return: bool = False,
) -> None:
    check_result = _run(
        _iptables_rule_argv(binary, "-C", chain, set_name, direction, comment),
        check=False,
    )
    if check_result.returncode == 0:
        return
    if before_return:
        rule_num = _find_iptables_return_rule_num(binary, chain)
        if rule_num is not None:
            argv = _iptables_rule_argv(binary, "-I", chain, set_name, direction, comment)
            argv.insert(3, str(rule_num))
            _run(argv)
            return
    _run(_iptables_rule_argv(binary, "-A", chain, set_name, direction, comment))


def _remove_iptables_rule(
    binary: str,
    chain: str,
    set_name: str,
    direction: str,
    comment: str,
) -> None:
    while True:
        check_result = _run(
            _iptables_rule_argv(binary, "-C", chain, set_name, direction, comment),
            check=False,
        )
        if check_result.returncode != 0:
            return
        _run(_iptables_rule_argv(binary, "-D", chain, set_name, direction, comment))


def _destroy_ipset(name: str) -> None:
    _run(["ipset", "destroy", name], check=False)


def _sync_ipset(live_name: str, family: str, entries: tuple[str, ...]) -> None:
    temp_name = _temp_set_name(live_name)
    _destroy_ipset(temp_name)
    _run(
        [
            "ipset",
            "create",
            temp_name,
            "hash:net",
            "family",
            _ipset_family_name(family),
        ]
    )
    for entry in entries:
        _run(["ipset", "add", temp_name, entry, "-exist"])

    _run(
        [
            "ipset",
            "create",
            live_name,
            "hash:net",
            "family",
            _ipset_family_name(family),
            "-exist",
        ]
    )
    _run(["ipset", "swap", temp_name, live_name])
    _destroy_ipset(temp_name)


def _ipset_entries(set_name: str) -> tuple[str, ...]:
    result = _run(["ipset", "list", set_name, "-o", "save"])
    entries: list[str] = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if line.startswith(f"add {set_name} "):
            entries.append(line.split(maxsplit=2)[2])
    return tuple(sorted(entries))


def _cleanup_previous_iptables(
    payload: dict[str, object],
    *,
    keep_set_names: set[str] | None = None,
    keep_comments: set[str] | None = None,
) -> None:
    chain = str(payload.get("iptables_chain", "DOCKER-USER"))
    direction = str(payload.get("rule_direction", "dst"))
    keep_set_names = keep_set_names or set()
    keep_comments = keep_comments or set()
    for category in _manifest_categories(payload):
        for family, set_key, comment_key in (
            ("v4", "set_name_v4", "rule_comment_v4"),
            ("v6", "set_name_v6", "rule_comment_v6"),
        ):
            set_name = category.get(set_key)
            comment = category.get(comment_key)
            if not isinstance(set_name, str) or not isinstance(comment, str):
                continue
            if set_name in keep_set_names or comment in keep_comments:
                continue
            _remove_iptables_rule(
                _iptables_binary(family),
                chain,
                set_name,
                direction,
                comment,
            )
            _destroy_ipset(set_name)


def _iptables_rules(binary: str, chain: str) -> list[str]:
    result = _run([binary, "-S", chain], check=False)
    if result.returncode != 0:
        stderr = result.stderr.lower()
        if "no chain" in stderr or "does a chain exist" in stderr:
            raise BackendCommandError(f"{binary} chain not found: {chain}")
        raise BackendCommandError(
            f"{binary} -S {chain}: {result.stderr.strip() or result.stdout.strip()}"
        )
    prefix = f"-A {chain} "
    return [
        line.strip()
        for line in result.stdout.splitlines()
        if line.strip().startswith(prefix)
    ]


def _find_iptables_return_rule_num(binary: str, chain: str) -> int | None:
    result = _run([binary, "-L", chain, "--line-numbers", "-n"], check=False)
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0].isdigit() and parts[1] == "RETURN":
            return int(parts[0])
    return None


def _delete_iptables_rule_spec(binary: str, chain: str, rule_spec: str) -> None:
    _run([binary, "-D", chain, *shlex.split(rule_spec)])


def _normalize_iptables_base_rules(binary: str, chain: str) -> None:
    rules = _iptables_rules(binary, chain)
    base_accept_suffix = "-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
    base_return_suffix = "-j RETURN"

    accept_specs = [line.split(maxsplit=2)[2] for line in rules if line == f"-A {chain} {base_accept_suffix}"]
    return_specs = [line.split(maxsplit=2)[2] for line in rules if line == f"-A {chain} {base_return_suffix}"]

    for rule_spec in accept_specs:
        _delete_iptables_rule_spec(binary, chain, rule_spec)
    for rule_spec in return_specs:
        _delete_iptables_rule_spec(binary, chain, rule_spec)

    _run(_iptables_base_accept_argv(binary, "-I", chain))
    _run(_iptables_base_return_argv(binary, "-A", chain))


def _remove_existing_commented_rule(
    binary: str,
    chain: str,
    comment: str,
) -> None:
    while True:
        rules = _iptables_rules(binary, chain)
        matching = [
            line for line in rules if f'--comment "{comment}"' in line or f"--comment {comment}" in line
        ]
        if not matching:
            return
        rule_spec = matching[0].split(maxsplit=2)[2]
        _delete_iptables_rule_spec(binary, chain, rule_spec)


def _nft_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _render_nft_set(
    family: str,
    table: str,
    set_name: str,
    set_type: str,
    entries: tuple[str, ...],
    *,
    interval: bool = False,
) -> list[str]:
    flags = " flags interval;" if interval else ""
    if entries:
        rendered_elements = ", ".join(
            _nft_quote(entry) if set_type == "ifname" else entry for entry in entries
        )
        return [
            f"add set {family} {table} {set_name} {{ type {set_type};{flags} elements = {{ {rendered_elements} }}; }}",
        ]
    return [
        f"add set {family} {table} {set_name} {{ type {set_type};{flags} }}",
    ]


def _nft_rule_lines(desired: DesiredState) -> list[str]:
    lines: list[str] = []
    for category in desired.categories:
        lines.append(
            "add rule "
            f"{desired.nft_table_family} {desired.nft_table_name} {desired.nft_chain_name} "
            f'iifname @docker_ifaces ip {"saddr" if desired.rule_direction == "src" else "daddr"} '
            f"@{category.set_name_v4} counter comment {_nft_quote(category.rule_comment_v4)} drop"
        )
        lines.append(
            "add rule "
            f"{desired.nft_table_family} {desired.nft_table_name} {desired.nft_chain_name} "
            f'iifname @docker_ifaces ip6 {"saddr" if desired.rule_direction == "src" else "daddr"} '
            f"@{category.set_name_v6} counter comment {_nft_quote(category.rule_comment_v6)} drop"
        )
    return lines


def _nft_table_exists(family: str, table: str) -> bool:
    result = _run(["nft", "list", "table", family, table], check=False)
    return result.returncode == 0


def _delete_nft_table(family: str, table: str) -> None:
    _run(["nft", "delete", "table", family, table], check=False)


def _render_nft_batch(desired: DesiredState) -> str:
    lines = [
        f"add table {desired.nft_table_family} {desired.nft_table_name}",
        (
            f"add chain {desired.nft_table_family} {desired.nft_table_name} {desired.nft_chain_name} "
            "{ type filter hook forward priority -1; policy accept; }"
        ),
    ]
    lines.extend(
        _render_nft_set(
            desired.nft_table_family,
            desired.nft_table_name,
            "docker_ifaces",
            "ifname",
            desired.docker_bridge_interfaces,
        )
    )
    for category in desired.categories:
        lines.extend(
            _render_nft_set(
                desired.nft_table_family,
                desired.nft_table_name,
                category.set_name_v4,
                "ipv4_addr",
                category.ipv4_entries,
                interval=True,
            )
        )
        lines.extend(
            _render_nft_set(
                desired.nft_table_family,
                desired.nft_table_name,
                category.set_name_v6,
                "ipv6_addr",
                category.ipv6_entries,
                interval=True,
            )
        )
    lines.extend(_nft_rule_lines(desired))
    return "\n".join(lines) + "\n"


def _cleanup_previous_nft(payload: dict[str, object]) -> None:
    family = payload.get("nft_table_family")
    table = payload.get("nft_table_name")
    if isinstance(family, str) and isinstance(table, str):
        _delete_nft_table(family, table)


def apply_desired_state(
    desired: DesiredState,
    previous_payload: dict[str, object] | None,
    *,
    trace: callable | None = None,
) -> list[str]:
    require_root("apply")

    messages: list[str] = []
    previous_family = (
        str(previous_payload.get("backend_family"))
        if isinstance(previous_payload, dict) and previous_payload.get("backend_family")
        else None
    )

    if desired.backend_family == "iptables":
        if previous_family == "nftables" and isinstance(previous_payload, dict):
            _cleanup_previous_nft(previous_payload)
            messages.append("removed previous nftables-managed Obscura table")

        for binary in ("iptables", "ip6tables"):
            if trace is not None:
                trace(f"Normalizing {binary} chain {desired.iptables_chain}")
            _normalize_iptables_base_rules(binary, desired.iptables_chain)

        for category in desired.categories:
            if trace is not None:
                trace(
                    f"Updating ipset objects for {category.kind}:{category.name} "
                    f"(v4={len(category.ipv4_entries)}, v6={len(category.ipv6_entries)})"
                )
            _sync_ipset(category.set_name_v4, "v4", category.ipv4_entries)
            _sync_ipset(category.set_name_v6, "v6", category.ipv6_entries)
            _remove_existing_commented_rule(
                "iptables",
                desired.iptables_chain,
                category.rule_comment_v4,
            )
            _remove_existing_commented_rule(
                "ip6tables",
                desired.iptables_chain,
                category.rule_comment_v6,
            )
            _ensure_iptables_rule(
                "iptables",
                desired.iptables_chain,
                category.set_name_v4,
                desired.rule_direction,
                category.rule_comment_v4,
                before_return=True,
            )
            _ensure_iptables_rule(
                "ip6tables",
                desired.iptables_chain,
                category.set_name_v6,
                desired.rule_direction,
                category.rule_comment_v6,
                before_return=True,
            )

        if previous_family == "iptables" and isinstance(previous_payload, dict):
            previous_sets = {
                str(category.get("set_name_v4"))
                for category in _manifest_categories(previous_payload)
                if isinstance(category.get("set_name_v4"), str)
            } | {
                str(category.get("set_name_v6"))
                for category in _manifest_categories(previous_payload)
                if isinstance(category.get("set_name_v6"), str)
            }
            current_sets = {
                category.set_name_v4 for category in desired.categories
            } | {category.set_name_v6 for category in desired.categories}
            current_comments = {
                category.rule_comment_v4 for category in desired.categories
            } | {category.rule_comment_v6 for category in desired.categories}
            if previous_sets - current_sets:
                _cleanup_previous_iptables(
                    previous_payload,
                    keep_set_names=current_sets,
                    keep_comments=current_comments,
                )
                messages.append("removed stale Obscura iptables/ipset objects")
    else:
        if previous_family == "iptables" and isinstance(previous_payload, dict):
            _cleanup_previous_iptables(previous_payload)
            messages.append("removed previous iptables/ipset-managed Obscura rules")
        elif previous_family == "nftables" and isinstance(previous_payload, dict):
            _cleanup_previous_nft(previous_payload)

        if _nft_table_exists(desired.nft_table_family, desired.nft_table_name):
            if trace is not None:
                trace(
                    f"Replacing nft table {desired.nft_table_family} {desired.nft_table_name}"
                )
            _delete_nft_table(desired.nft_table_family, desired.nft_table_name)

        if trace is not None:
            trace(
                f"Installing nft table {desired.nft_table_family} {desired.nft_table_name} "
                f"with {len(desired.categories)} categories"
            )
        _run(["nft", "-f", "-"], input_text=_render_nft_batch(desired))
        messages.append("installed nftables-managed Obscura table")

    return messages


def _nft_list_set_output(family: str, table: str, set_name: str) -> str | None:
    result = _run(
        ["nft", "list", "set", family, table, set_name],
        check=False,
    )
    if result.returncode != 0:
        return None
    return result.stdout


def _parse_nft_set_elements(output: str) -> tuple[str, ...]:
    match = re.search(r"elements\s*=\s*\{(.*?)\}", output, re.S)
    if not match:
        return ()
    raw = match.group(1).strip()
    if not raw:
        return ()
    values = []
    for item in raw.split(","):
        value = item.strip().strip('"')
        if value:
            values.append(value)
    return tuple(sorted(values))


def _live_iptables_set_count(set_name: str) -> int:
    try:
        return len(_ipset_entries(set_name))
    except BackendCommandError:
        return 0


def _live_nft_set_count(desired: DesiredState, set_name: str) -> int:
    output = _nft_list_set_output(desired.nft_table_family, desired.nft_table_name, set_name)
    if output is None:
        return 0
    return len(_parse_nft_set_elements(output))


def _previous_category_entries_count(
    previous_payload: dict[str, object] | None,
    *,
    set_name: str,
    entries_key: str,
) -> int:
    if not isinstance(previous_payload, dict):
        return 0
    for category in _manifest_categories(previous_payload):
        if category.get("set_name_v4") == set_name or category.get("set_name_v6") == set_name:
            entries = category.get(entries_key)
            if isinstance(entries, list):
                return len(entries)
    return 0


def _family_target_count(category: DesiredCategory, family: str) -> int:
    return len(category.ipv4_entries if family == "v4" else category.ipv6_entries)


def guard_empty_replacements(
    desired: DesiredState,
    previous_payload: dict[str, object] | None,
) -> list[str]:
    hazards: list[str] = []

    for category in desired.categories:
        if not category.accepted_entries:
            continue
        if category.resolved_entry_count != 0:
            continue

        for family, set_name, entries_key in (
            ("v4", category.set_name_v4, "ipv4_entries"),
            ("v6", category.set_name_v6, "ipv6_entries"),
        ):
            if _family_target_count(category, family) != 0:
                continue

            if desired.backend_family == "iptables":
                live_count = _live_iptables_set_count(set_name)
            else:
                live_count = _live_nft_set_count(desired, set_name)

            previous_count = _previous_category_entries_count(
                previous_payload,
                set_name=set_name,
                entries_key=entries_key,
            )

            if live_count > 0 or previous_count > 0:
                hazards.append(
                    f"{category.kind}:{category.name}:{family} resolved to an empty set while source entries still exist, "
                    f"but the current/previous managed set contains records (live={live_count}, previous={previous_count}); "
                    "refusing to replace it with an empty set"
                )

    return hazards


def _verify_iptables(payload: dict[str, object]) -> list[str]:
    errors: list[str] = []
    chain = str(payload.get("iptables_chain", "DOCKER-USER"))
    direction = str(payload.get("rule_direction", "dst"))
    base_accept_suffix = "-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
    base_return_suffix = "-j RETURN"

    for binary in ("iptables", "ip6tables"):
        try:
            rules = _iptables_rules(binary, chain)
        except BackendCommandError as exc:
            errors.append(str(exc))
            continue

        exact_accept = [line for line in rules if line == f"-A {chain} {base_accept_suffix}"]
        exact_return = [line for line in rules if line == f"-A {chain} {base_return_suffix}"]
        if len(exact_accept) != 1:
            errors.append(
                f"{binary} chain {chain} must contain exactly one RELATED,ESTABLISHED ACCEPT rule"
            )
        if len(exact_return) != 1:
            errors.append(f"{binary} chain {chain} must contain exactly one final RETURN rule")
        if rules and rules[0] != f"-A {chain} {base_accept_suffix}":
            errors.append(f"{binary} chain {chain} first rule is not RELATED,ESTABLISHED ACCEPT")
        if rules and rules[-1] != f"-A {chain} {base_return_suffix}":
            errors.append(f"{binary} chain {chain} last rule is not RETURN")

    for category in _manifest_categories(payload):
        for family, set_key, comment_key, entries_key in (
            ("v4", "set_name_v4", "rule_comment_v4", "ipv4_entries"),
            ("v6", "set_name_v6", "rule_comment_v6", "ipv6_entries"),
        ):
            set_name = category.get(set_key)
            comment = category.get(comment_key)
            expected_entries = category.get(entries_key, [])
            if not isinstance(set_name, str) or not isinstance(comment, str):
                errors.append(f"manifest missing {family} metadata for category {category.get('name')}")
                continue
            try:
                actual_entries = _ipset_entries(set_name)
            except BackendCommandError as exc:
                errors.append(str(exc))
                continue
            if tuple(sorted(expected_entries)) != actual_entries:
                errors.append(
                    f"{set_name}: expected {len(expected_entries)} entries, found {len(actual_entries)}"
                )
            rules = _iptables_rules(_iptables_binary(family), chain)
            matching_rules = [
                line
                for line in rules
                if f'--comment "{comment}"' in line or f"--comment {comment}" in line
            ]
            if len(matching_rules) != 1:
                errors.append(
                    f"{_iptables_binary(family)} chain {chain} expected exactly one rule for comment {comment}"
                )
            rule_check = _run(
                _iptables_rule_argv(
                    _iptables_binary(family),
                    "-C",
                    chain,
                    set_name,
                    direction,
                    comment,
                ),
                check=False,
            )
            if rule_check.returncode != 0:
                errors.append(
                    f"{_iptables_binary(family)} rule missing for set {set_name} ({comment})"
                )
    return errors


def _verify_nft(payload: dict[str, object]) -> list[str]:
    errors: list[str] = []
    family = payload.get("nft_table_family")
    table = payload.get("nft_table_name")
    chain = payload.get("nft_chain_name")
    if not isinstance(family, str) or not isinstance(table, str) or not isinstance(chain, str):
        return ["manifest missing nft table metadata"]

    table_result = _run(["nft", "list", "table", family, table], check=False)
    if table_result.returncode != 0:
        return [f"nft table missing: {family} {table}"]

    docker_ifaces_output = _nft_list_set_output(family, table, "docker_ifaces")
    if docker_ifaces_output is None:
        errors.append("nft set missing: docker_ifaces")
    else:
        expected_ifaces = tuple(sorted(payload.get("docker_bridge_interfaces", [])))
        actual_ifaces = _parse_nft_set_elements(docker_ifaces_output)
        if expected_ifaces != actual_ifaces:
            errors.append(
                f"docker_ifaces set mismatch: expected {len(expected_ifaces)} entries, found {len(actual_ifaces)}"
            )

    chain_result = _run(["nft", "list", "chain", family, table, chain], check=False)
    chain_output = chain_result.stdout if chain_result.returncode == 0 else ""
    if chain_result.returncode != 0:
        errors.append(f"nft chain missing: {family} {table} {chain}")

    for category in _manifest_categories(payload):
        for set_key, comment_key, entries_key in (
            ("set_name_v4", "rule_comment_v4", "ipv4_entries"),
            ("set_name_v6", "rule_comment_v6", "ipv6_entries"),
        ):
            set_name = category.get(set_key)
            comment = category.get(comment_key)
            expected_entries = tuple(sorted(category.get(entries_key, [])))
            if not isinstance(set_name, str) or not isinstance(comment, str):
                errors.append(f"manifest missing nft metadata for category {category.get('name')}")
                continue
            set_output = _nft_list_set_output(family, table, set_name)
            if set_output is None:
                errors.append(f"nft set missing: {set_name}")
                continue
            actual_entries = _parse_nft_set_elements(set_output)
            if expected_entries != actual_entries:
                errors.append(
                    f"{set_name}: expected {len(expected_entries)} entries, found {len(actual_entries)}"
                )
            if chain_output and comment not in chain_output:
                errors.append(f"nft rule missing comment marker: {comment}")

    return errors


def verify_manifest(payload: dict[str, object]) -> list[str]:
    require_root("verify")
    backend_family = payload.get("backend_family")
    if backend_family == "iptables":
        return _verify_iptables(payload)
    if backend_family == "nftables":
        return _verify_nft(payload)
    return [f"Unsupported backend_family in manifest: {backend_family!r}"]


def _flush_iptables_from_manifest(payload: dict[str, object]) -> list[str]:
    _cleanup_previous_iptables(payload)
    return ["removed Obscura-managed iptables rules and ipsets from manifest"]


def _flush_iptables_fallback(chain: str) -> list[str]:
    messages: list[str] = []

    for binary in ("iptables", "ip6tables"):
        while True:
            rules = _iptables_rules(binary, chain)
            matching = [
                line
                for line in rules
                if "--comment obscura-blacklist:" in line
                or '--comment "obscura-blacklist:' in line
            ]
            if not matching:
                break
            rule_spec = matching[0].split(maxsplit=2)[2]
            _delete_iptables_rule_spec(binary, chain, rule_spec)
        messages.append(f"removed Obscura-managed commented rules from {binary} {chain}")

    list_result = _run(["ipset", "list", "-name"], check=False)
    if list_result.returncode == 0:
        for name in list_result.stdout.splitlines():
            name = name.strip()
            if name.startswith("obl_"):
                _destroy_ipset(name)
        messages.append("removed Obscura-managed ipsets matching prefix obl_")
    else:
        messages.append("could not enumerate ipsets for fallback cleanup")

    return messages


def flush_state(
    *,
    manifest_payload: dict[str, object] | None,
    selected_backend: str | None,
    configured_chain: str,
    configured_nft_family: str,
    configured_nft_table: str,
) -> list[str]:
    require_root("flush")

    messages: list[str] = []
    backend_family = None
    if isinstance(manifest_payload, dict):
        payload_family = manifest_payload.get("backend_family")
        if isinstance(payload_family, str):
            backend_family = payload_family

    backend_family = backend_family or selected_backend

    if backend_family == "iptables":
        if isinstance(manifest_payload, dict):
            messages.extend(_flush_iptables_from_manifest(manifest_payload))
        else:
            messages.extend(_flush_iptables_fallback(configured_chain))
        return messages

    if backend_family == "nftables":
        if isinstance(manifest_payload, dict):
            _cleanup_previous_nft(manifest_payload)
            messages.append("removed Obscura-managed nftables table from manifest")
        else:
            _delete_nft_table(configured_nft_family, configured_nft_table)
            messages.append(
                f"removed configured nftables table {configured_nft_family} {configured_nft_table}"
            )
        return messages

    if isinstance(manifest_payload, dict):
        _cleanup_previous_iptables(manifest_payload, keep_set_names=set(), keep_comments=set())
        _cleanup_previous_nft(manifest_payload)
        messages.append("removed Obscura-managed state from manifest without backend hint")
        return messages

    raise RuntimeError("cannot determine what to flush without a manifest or selected backend")
