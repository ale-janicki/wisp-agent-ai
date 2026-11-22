import re
import tomllib
from pathlib import Path

ROOT = Path(__file__).parents[2]


def pins() -> dict[str, str]:
    deps = tomllib.loads((ROOT / "cli/pyproject.toml").read_text())["project"]["dependencies"]
    found = {}
    for dep in deps:
        match = re.match(r"^([A-Za-z0-9_.-]+)==([^;\s]+)", dep)
        if match:
            found[match.group(1)] = match.group(2)
    return found


def locked() -> dict[str, str]:
    packages = tomllib.loads((ROOT / "uv.lock").read_text())["package"]
    return {p["name"]: p["version"] for p in packages}


def test_the_runtime_that_runs_the_model_is_pinned_and_the_lock_matches_the_pins():
    wanted, lock = pins(), locked()
    assert {"mlx-lm", "transformers"} <= set(wanted)
    for name, version in wanted.items():
        assert lock[name] == version, name


def test_the_model_runtime_pins_only_apply_where_mlx_can_run():
    deps = tomllib.loads((ROOT / "cli/pyproject.toml").read_text())["project"]["dependencies"]
    for dep in deps:
        if dep.startswith(("mlx-lm", "transformers")):
            assert "sys_platform == 'darwin'" in dep and "platform_machine == 'arm64'" in dep
