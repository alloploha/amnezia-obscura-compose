"""Config loading for obscura-blacklist."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


INSTALL_SOURCES_DIR = Path("/etc/obscura-blacklist/sources")
INSTALL_CONFIG_DIR = Path("/etc/obscura-blacklist")
INSTALL_CONFIG_PATH = INSTALL_CONFIG_DIR / "blacklist.conf"
INSTALL_STATE_DIR = Path("/var/lib/obscura-blacklist")
INSTALL_CACHE_DIR = Path("/var/cache/obscura-blacklist")


@dataclass(frozen=True)
class LoadedConfig:
    """Loaded blacklist config with repo-local development fallbacks."""

    config_path: Path
    values: dict[str, str]
    configured_sources_dir: Path
    configured_state_dir: Path
    configured_cache_dir: Path
    effective_sources_dir: Path
    effective_state_dir: Path
    effective_cache_dir: Path
    using_repo_fallback: bool

    @property
    def backend_mode(self) -> str:
        return self.values["BLACKLIST_BACKEND"].strip().lower() or "auto"


def _parse_config_lines(config_path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in config_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"Invalid config line in {config_path}: {raw_line!r}")
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def load_config(config_path: Path, repo_root: Path) -> LoadedConfig:
    values = _parse_config_lines(config_path)

    for key in list(values):
        override = os.environ.get(key)
        if override is not None:
            values[key] = override

    configured_sources_dir = Path(values["BLACKLIST_SOURCES_DIR"])
    configured_state_dir = Path(values["BLACKLIST_STATE_DIR"])
    configured_cache_dir = Path(values["BLACKLIST_CACHE_DIR"])

    using_repo_fallback = False
    effective_sources_dir = configured_sources_dir
    effective_state_dir = configured_state_dir
    effective_cache_dir = configured_cache_dir

    is_repo_config = config_path.resolve() == (repo_root / "config" / "blacklist.conf").resolve()
    repo_sources_dir = repo_root / "config" / "sources"
    repo_state_dir = repo_root / "state"
    repo_cache_dir = repo_root / "cache"

    if is_repo_config:
        if configured_sources_dir == INSTALL_SOURCES_DIR and repo_sources_dir.exists():
            effective_sources_dir = repo_sources_dir
            using_repo_fallback = True
        if configured_state_dir == INSTALL_STATE_DIR:
            effective_state_dir = repo_state_dir
            using_repo_fallback = True
        if configured_cache_dir == INSTALL_CACHE_DIR:
            effective_cache_dir = repo_cache_dir
            using_repo_fallback = True

    return LoadedConfig(
        config_path=config_path,
        values=values,
        configured_sources_dir=configured_sources_dir,
        configured_state_dir=configured_state_dir,
        configured_cache_dir=configured_cache_dir,
        effective_sources_dir=effective_sources_dir,
        effective_state_dir=effective_state_dir,
        effective_cache_dir=effective_cache_dir,
        using_repo_fallback=using_repo_fallback,
    )
