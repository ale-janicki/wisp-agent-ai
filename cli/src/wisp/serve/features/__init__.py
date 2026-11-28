from __future__ import annotations

import importlib
import logging
import pkgutil

from starlette.routing import BaseRoute, Mount

log = logging.getLogger(__name__)


def discover() -> dict[str, list[BaseRoute]]:
    found: dict[str, list[BaseRoute]] = {}
    for info in sorted(pkgutil.iter_modules(__path__), key=lambda m: m.name):
        if info.name.startswith("_"):
            continue
        try:
            module = importlib.import_module(f"{__name__}.{info.name}")
        except Exception:
            log.exception("feature %s failed to import; not mounted", info.name)
            continue
        routes = getattr(module, "routes", None)
        if routes is None:
            continue
        found[info.name] = list(routes)
    return found


def mounts() -> list[Mount]:
    return [Mount(f"/api/{name}", routes=routes) for name, routes in discover().items()]
