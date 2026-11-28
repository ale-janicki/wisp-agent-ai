import os
import platform
import sys
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path, PureWindowsPath


@dataclass(frozen=True)
class WispPaths:
    home: Path
    config: Path
    runtime: Path
    state: Path
    bin: Path
    launch_agents: Path | None
    system: str = ""

    @staticmethod
    def for_os(system: str, home: Path, env: Mapping[str, str]) -> "WispPaths":
        if system == "Windows":
            windows_path = Path if sys.platform == "win32" else PureWindowsPath
            roaming = windows_path(env.get("APPDATA") or home / "AppData/Roaming")
            local = windows_path(env.get("LOCALAPPDATA") or home / "AppData/Local") / "wisp"
            return WispPaths(home, roaming / "wisp", local / "runtime", local / "state", local / "bin", None, system)
        config = Path(env.get("XDG_CONFIG_HOME") or home / ".config")
        state = Path(env.get("XDG_STATE_HOME") or home / ".local/state")
        data = Path(env.get("XDG_DATA_HOME") or home / ".local/share")
        launch_agents = home / "Library/LaunchAgents" if system == "Darwin" else None
        return WispPaths(home, config / "wisp", data / "wisp/runtime", state / "wisp", home / ".local/bin", launch_agents,
                         system)

    @staticmethod
    def current() -> "WispPaths":
        return WispPaths.for_os(platform.system(), Path.home(), os.environ)


def venv_bin(venv: Path) -> Path:
    return venv / ("Scripts" if sys.platform == "win32" else "bin")


def exe(name: str) -> str:
    return f"{name}.exe" if sys.platform == "win32" else name


def resources_root() -> Path:
    env = os.environ.get("WISP_RESOURCES")
    return Path(env) if env else Path(__file__).resolve().parents[3]
