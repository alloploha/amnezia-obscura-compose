"""Stable command contract for the blacklist CLI scaffold."""

from __future__ import annotations


COMMANDS = {
    "help": "Show usage and command summary.",
    "commands": "List supported commands and their contract.",
    "check": "Validate Docker, backend tooling, config, and sources without mutating firewall state.",
    "status": "Report detected backend, Docker scope, categories, and last successful apply metadata.",
    "apply": "Resolve sources, render backend state, and apply the blacklist atomically.",
    "refresh": "Periodic refresh entrypoint; same intent as apply with cache-aware updates.",
    "verify": "Confirm live firewall state matches the last rendered Obscura-managed state.",
    "flush": "Remove only Obscura-managed rules and sets.",
    "print-default-config": "Print the default blacklist.conf contents.",
    "install-systemd": "Install or describe the systemd service and timer integration.",
    "uninstall-systemd": "Remove installed systemd integration owned by the module.",
}


NOT_IMPLEMENTED = {
    "apply",
    "refresh",
    "verify",
    "flush",
    "install-systemd",
    "uninstall-systemd",
}
