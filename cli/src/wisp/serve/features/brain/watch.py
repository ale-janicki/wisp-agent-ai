from __future__ import annotations

import os

from .vault import Vault

Snapshot = dict[str, tuple[int, int] | None]


def snapshot(vault: Vault) -> Snapshot:
    found: Snapshot = {}
    for current, dirs, names in os.walk(vault.root):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        base = os.path.relpath(current, vault.root).replace(os.sep, "/")
        prefix = "" if base == "." else base + "/"
        for directory in dirs:
            found[prefix + directory] = None
        for name in names:
            if name.startswith("."):
                continue
            try:
                info = os.stat(os.path.join(current, name))
            except OSError:
                continue
            found[prefix + name] = (info.st_mtime_ns, info.st_size)
    return found


def diff(before: Snapshot, after: Snapshot) -> list[str]:
    changed = {rel for rel in before.keys() | after.keys() if before.get(rel, "-") != after.get(rel, "-")}
    return sorted(changed)
