"""Obscura blacklist package metadata."""

from __future__ import annotations

from pathlib import Path

__all__ = ["__version__"]


def _load_version() -> str:
    here = Path(__file__).resolve()
    candidates = (
        here.parents[3] / "VERSION",  # source tree: <repo>/blacklist/libexec/obscura_blacklist
        here.parents[1] / "VERSION",  # installed tree: /usr/local/libexec/obscura-blacklist/obscura_blacklist
    )
    for path in candidates:
        try:
            value = path.read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if value:
            return value
    return "0.0.0"


__version__ = _load_version()
