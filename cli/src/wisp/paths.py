import os
import platform
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path, PurePath, PureWindowsPath


@dataclass(frozen=True)
class WispPaths:
    home: Path
    config: Path
    runtime: Path
    state: Path
    bin: Path
    launch_agents: Path | None

    @staticmethod
    def for_os(system: str, home: Path, env: Mapping[str, str]) -> "WispPaths":
        if system == "Windows":
            roaming = PureWindowsPath(env["APPDATA"])
            local = PureWindowsPath(env["LOCALAPPDATA"]) / "wisp"
            return WispPaths(home, roaming / "wisp", local / "runtime", local / "state", local / "bin", None)
        config = Path(env.get("XDG_CONFIG_HOME") or home / ".config")
        state = Path(env.get("XDG_STATE_HOME") or home / ".local/state")
        data = Path(env.get("XDG_DATA_HOME") or home / ".local/share")
        launch_agents = home / "Library/LaunchAgents" if system == "Darwin" else None
        return WispPaths(home, config / "wisp", data / "wisp/runtime", state / "wisp", home / ".local/bin", launch_agents)

    @staticmethod
    def current() -> "WispPaths":
        return WispPaths.for_os(platform.system(), Path.home(), os.environ)


def resources_root() -> Path:
    env = os.environ.get("WISP_RESOURCES")
    return Path(env) if env else Path(__file__).resolve().parents[3]
