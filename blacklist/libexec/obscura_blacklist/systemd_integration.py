"""Systemd installation helpers for obscura-blacklist."""

from __future__ import annotations

import os
import shutil
from pathlib import Path

from obscura_blacklist.backends import BackendCommandError, _run, require_root
from obscura_blacklist.config import INSTALL_CONFIG_DIR, INSTALL_CONFIG_PATH, INSTALL_SOURCES_DIR


SYSTEMD_UNIT_DIR = Path("/etc/systemd/system")
INSTALLED_LIBEXEC_ROOT = Path("/usr/local/libexec/obscura-blacklist")
INSTALLED_PACKAGE_DIR = INSTALLED_LIBEXEC_ROOT / "obscura_blacklist"
INSTALLED_VERSION_PATH = INSTALLED_LIBEXEC_ROOT / "VERSION"
INSTALLED_BIN_PATH = Path("/usr/local/bin/obscura-blacklist")
SERVICE_UNIT_NAME = "obscura-blacklist.service"
TIMER_UNIT_NAME = "obscura-blacklist.timer"


def _copy_tree(src: Path, dst: Path) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    for path in src.iterdir():
        target = dst / path.name
        if path.is_dir():
            _copy_tree(path, target)
        else:
            shutil.copy2(path, target)


def _write_text(path: Path, content: str, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    os.chmod(path, mode)


def _installed_launcher_content() -> str:
    libexec_root = str(INSTALLED_LIBEXEC_ROOT)
    return f"""#!/usr/bin/env python3
import sys
from pathlib import Path

LIBEXEC = Path({libexec_root!r})
if str(LIBEXEC) not in sys.path:
    sys.path.insert(0, str(LIBEXEC))

from obscura_blacklist.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
"""


def _service_unit_content() -> str:
    return f"""[Unit]
Description=Obscura blacklist refresh
Documentation=https://github.com/alloploha/amnezia-obscura-compose
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart={INSTALLED_BIN_PATH} --config {INSTALL_CONFIG_PATH} refresh

[Install]
WantedBy=multi-user.target
"""


def _timer_unit_content() -> str:
    return """[Unit]
Description=Periodic refresh for Obscura blacklist
Documentation=https://github.com/alloploha/amnezia-obscura-compose

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
Unit=obscura-blacklist.service

[Install]
WantedBy=timers.target
"""


def _install_default_config(repo_blacklist_root: Path, messages: list[str]) -> None:
    INSTALL_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    INSTALL_SOURCES_DIR.mkdir(parents=True, exist_ok=True)

    repo_config = repo_blacklist_root / "config" / "blacklist.conf"
    repo_sources_dir = repo_blacklist_root / "config" / "sources"

    if INSTALL_CONFIG_PATH.exists():
        messages.append(f"preserved existing config: {INSTALL_CONFIG_PATH}")
    else:
        shutil.copy2(repo_config, INSTALL_CONFIG_PATH)
        os.chmod(INSTALL_CONFIG_PATH, 0o644)
        messages.append(f"installed default config: {INSTALL_CONFIG_PATH}")

    for source_file in sorted(repo_sources_dir.iterdir()):
        if not source_file.is_file():
            continue
        target = INSTALL_SOURCES_DIR / source_file.name
        if target.exists():
            messages.append(f"preserved existing source file: {target}")
            continue
        shutil.copy2(source_file, target)
        os.chmod(target, 0o644)
        messages.append(f"installed default source file: {target}")


def install_systemd(blacklist_root: Path) -> list[str]:
    require_root("install-systemd")

    systemctl_path = shutil.which("systemctl")
    if systemctl_path is None:
        raise RuntimeError("systemctl not found in PATH")

    repo_blacklist_root = blacklist_root
    repo_package_dir = repo_blacklist_root / "libexec" / "obscura_blacklist"
    if not repo_package_dir.exists():
        raise RuntimeError(f"blacklist package directory not found: {repo_package_dir}")

    messages: list[str] = []

    _copy_tree(repo_package_dir, INSTALLED_PACKAGE_DIR)
    messages.append(f"installed Python package: {INSTALLED_PACKAGE_DIR}")

    repo_version_path = repo_blacklist_root.parent / "VERSION"
    if repo_version_path.exists():
        shutil.copy2(repo_version_path, INSTALLED_VERSION_PATH)
        os.chmod(INSTALLED_VERSION_PATH, 0o644)
        messages.append(f"installed version file: {INSTALLED_VERSION_PATH}")

    _write_text(INSTALLED_BIN_PATH, _installed_launcher_content(), 0o755)
    messages.append(f"installed launcher: {INSTALLED_BIN_PATH}")

    _install_default_config(repo_blacklist_root, messages)

    service_path = SYSTEMD_UNIT_DIR / SERVICE_UNIT_NAME
    timer_path = SYSTEMD_UNIT_DIR / TIMER_UNIT_NAME
    _write_text(service_path, _service_unit_content(), 0o644)
    _write_text(timer_path, _timer_unit_content(), 0o644)
    messages.append(f"installed unit: {service_path}")
    messages.append(f"installed unit: {timer_path}")

    _run([systemctl_path, "daemon-reload"])
    _run([systemctl_path, "enable", "--now", TIMER_UNIT_NAME])
    messages.append(f"enabled and started timer: {TIMER_UNIT_NAME}")

    return messages


def uninstall_systemd() -> list[str]:
    require_root("uninstall-systemd")

    systemctl_path = shutil.which("systemctl")
    if systemctl_path is None:
        raise RuntimeError("systemctl not found in PATH")

    messages: list[str] = []

    _run([systemctl_path, "disable", "--now", TIMER_UNIT_NAME], check=False)
    messages.append(f"disabled timer: {TIMER_UNIT_NAME}")

    _run([systemctl_path, "stop", SERVICE_UNIT_NAME], check=False)
    messages.append(f"stopped service: {SERVICE_UNIT_NAME}")

    for unit_name in (SERVICE_UNIT_NAME, TIMER_UNIT_NAME):
        unit_path = SYSTEMD_UNIT_DIR / unit_name
        if unit_path.exists():
            unit_path.unlink()
            messages.append(f"removed unit: {unit_path}")

    _run([systemctl_path, "daemon-reload"])
    messages.append("reloaded systemd manager configuration")

    return messages
